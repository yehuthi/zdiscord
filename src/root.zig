const std = @import("std");
const websocket = @import("websocket");

/// Extracts a substring from the input string that starts after the first
/// occurrence of `start` and ends before the next occurrence of `end`.
/// Returns null if not found.
fn extract_substring(
	string: []const u8,
	start: []const u8,
	end: []const u8
) ?[]const u8 {
	const start_index = std.mem.indexOf(u8, string, start)
		orelse return null;
	const end_index =
		std.mem.indexOfPosLinear(u8, string, start_index + start.len, end)
		orelse return null;
	return string[start_index..end_index];
}

test "extract_substring /gateway payload" {
	try std.testing.expectEqualStrings(
		"wss://gateway.discord.gg",
		extract_substring(
			"{\"url\":\"wss://gateway.discord.gg\"}",
			"wss://",
			"\"",
		).?,
	);
}

pub fn ws_gateway_connect(
	allocator: std.mem.Allocator,
	opts: struct { timeout_ms: u32 = 5_000 },
) !websocket.Client {
	const host = "gateway.discord.gg";
	var client = try websocket.connect(
		allocator,
		host,
		443,
		.{ .tls = true },
	);
	try client.handshake("/?v=10&encoding=json", .{
		.timeout_ms = opts.timeout_ms,
		.headers = "host: " ++ host,
	});
	return client;
}

/// The internal value type for intents.
pub const Intent = u32;

pub const intent = struct {
	pub const guilds                        : Intent = 1 <<  0;
	pub const guild_members                 : Intent = 1 <<  1;
	pub const guild_moderation              : Intent = 1 <<  2;
	pub const guild_expressions             : Intent = 1 <<  3;
	pub const guild_integrations            : Intent = 1 <<  4;
	pub const guild_webhooks                : Intent = 1 <<  5;
	pub const guild_invites                 : Intent = 1 <<  6;
	pub const guild_voice_states            : Intent = 1 <<  7;
	pub const guild_presence                : Intent = 1 <<  8;
	pub const guild_messages                : Intent = 1 <<  9;
	pub const guild_message_reactions       : Intent = 1 << 10;
	pub const guild_message_typing          : Intent = 1 << 11;
	pub const direct_messages               : Intent = 1 << 12;
	pub const direct_message_reactions      : Intent = 1 << 13;
	pub const direct_message_typing         : Intent = 1 << 14;
	pub const message_content               : Intent = 1 << 15;
	pub const guild_scheduled_events        : Intent = 1 << 16;
	pub const auto_moderation_configuration : Intent = 1 << 20;
	pub const auto_moderation_execution     : Intent = 1 << 21;
	pub const guild_message_polls           : Intent = 1 << 24;
	pub const direct_message_polls          : Intent = 1 << 25;
};


const Identify = struct {
	/// Authentication token.
	token: []const u8,
	/// Gateway Intents you wish to receive.
	intents: Intent,
	properties: struct {
		os: []const u8 = "TempleOS",
		browser: []const u8 = library_name,
		device: []const u8 = library_name,
	} = .{},

	// TODO: get it from .zon
	const library_name = "zdiscord";
};

pub const Gateway = struct {
	allocator: std.mem.Allocator,
	client: *websocket.Client,
	sequence: ?Sequence = null,
	heartbeat_interval: Heartbeat = 0,
	client_mutex: std.Thread.Mutex = .{},
	// TODO: move out of here
	identify: Identify,

	const Sequence = i32;
	const Heartbeat = u16;
	const Self = @This();

	pub fn deinit(self: *Self) void {
		// TODO: kill heartbeat thread
		self.client.deinit();
	}

	pub fn go_spawn(self: *Self) !std.Thread {
		return self.client.readLoopInNewThread(self);
	}

	pub fn identify_unchecked(self: *Self, data: Identify) !void {
		var buffer: [1024]u8 = undefined;
		var allocator = std.heap.FixedBufferAllocator.init(&buffer);
		const message = try std.json.stringifyAlloc(
			allocator.allocator(),
			.{ .op = @intFromEnum(GatewayOpcode.identify), .d = data },
			.{},
		);
		std.log.debug(
			"Sending identify to gateway (message: \"{s}\")",
			.{ message }
		);
		try self.client.writeText(message);
	}

	pub fn identify_send(self: *Self, data: Identify) !void {
		self.client_mutex.lock();
		defer self.client_mutex.unlock();
		try self.identify_unchecked(data);
	}

	pub fn handle(self: *Self, message: websocket.Message) !void {
		// TODO: deal with every `try` so we don't close the connection.

		if (message.type != .text) {
			return error.bad_message_type; // expected text
		}
		const json = try std.json.parseFromSlice(
			struct {
				op: GatewayOpcode,
				s: ?Sequence = null,
				t: ?[]const u8 = null,
			},
			self.allocator,
			message.data,
			.{ .ignore_unknown_fields = true, });
		defer json.deinit();

		if (json.value.s) |sequence| {
			// TODO: should be atomic and only assign when >, given that we'd
			// probably want to process events in concurrent tasks.
			self.sequence = sequence;
			std.log.debug(
				"Gateway received opcode {s} ({d}) message",
				.{ @tagName(json.value.op), @intFromEnum(json.value.op) }
			);
		}

		std.log.debug(
			"Gateway received opcode {?} ({d}) message",
			.{ json.value.op, @intFromEnum(json.value.op) }
		);
		if (json.value.op == GatewayOpcode.hello) {
			const data = try std.json.parseFromSlice(
				struct { d: struct { heartbeat_interval: Heartbeat } },
				self.allocator,
				message.data,
				.{ .ignore_unknown_fields = true },
			);
			defer data.deinit();
			self.heartbeat_interval = data.value.d.heartbeat_interval;
			std.log.debug(
				"Gateway heartbeat interval: {d}",
				.{ self.heartbeat_interval }
			);

			const thread = try std.Thread.spawn(.{}, heartbeat_loop, .{ self });
			thread.detach();

			try self.identify_send(self.identify);
		}

		std.log.debug("Gateway received message: {s}", .{ message.data });
	}

	pub fn close(_: Self) void {
		std.log.info("Gateway connection closed", .{});
	}

	fn heartbeat_loop(self: *Self) !void {
		// TODO: check we got ACK for previous heartbeat (if made)
		var heartbeat_buffer = GatewayHeartbeatBuffer.make();
		// client.writeText destroys the message so we'll store a throwaway
		// copy here for it.
		var heartbeat_scratch: [GatewayHeartbeatBuffer.BUFFER_SIZE]u8 =
			undefined;
		while (true) {
			const message = try heartbeat_buffer.fmt(self.sequence);
			std.log.debug(
				"Sending heartbeat to gateway (sequence {any}), payload: \"{s}\"",
				.{ self.sequence, message }
			);
			@memcpy(heartbeat_scratch[0..message.len], message);
			try self.client.writeText(heartbeat_scratch[0..message.len]);
			std.time.sleep(@as(u64, self.heartbeat_interval) * std.time.ns_per_ms);
		}
		std.log.info("Heartbeat loop stopped", .{});
	}
};

const GatewayOpcode = enum(u8) {
	/// An event was dispatched.
	dispatch = 0,
	/// Fired periodically by the client to keep the connection alive.
	heartbeat = 1,
	/// Starts a new session during the initial handshake.
	identify = 2,
	/// Update the client's presence.
	presence_update = 3,
	/// Used to join/leave or move between voice channels.
	voice_state_update = 4,
	/// Resume a previous session that was disconnected.
	@"resume" = 6,
	/// You should attempt to reconnect and resume immediately.
	reconnect = 7,
	/// Request information about offline guild members in a large guild.
	request_guild_members = 8,
	/// The session has been invalidated. You should reconnect and identify/resume accordingly.
	invalid_session = 9,
	/// Sent immediately after connecting, contains the `heartbeat_interval` to use.
	hello = 10,
	/// Sent in response to receiving a heartbeat to acknowledge that it has been received.
	heartbeat_ack = 11,
	/// Request information about soundboard sounds in a set of guilds.
	request_soundboard_sounds = 31,
};

fn GatewayHeartbeatBufferSized(SIZE: comptime_int) type {
	if (SIZE <= 0) {
		@compileError("Gateway heartbeat buffer size must be greater than zero");
	}
	return struct {
		data: [BUFFER_SIZE]u8,

		pub const BUFFER_SIZE = PREFIX.len + SIZE + 1; // prefix + last sequence + '}'

		const PREFIX = "{\"op\":1,\"d\":";
		const Self = @This();

		pub fn init(self: *Self) void {
			@memcpy(self.data[0..PREFIX.len], PREFIX);
		}

		pub fn make() Self {
			var self = Self { .data = undefined };
			self.init();
			return self;
		}

		pub fn fmt(self: *Self, value: anytype) ![]u8 {
			comptime {
				if (@typeInfo(@TypeOf(value)) == .Optional) {
					if (SIZE < 4) { // not enough room for "null" literal
						@compileError("Buffer size is too small for nullable (must be at least 4)");
					}
				}
			}
			const wrote = try std.fmt.bufPrint(
				self.data[PREFIX.len..],
				"{?}}}",
				.{ value }
			);
			return self.data[0..PREFIX.len + wrote.len];
		}
	};
}

const GatewayHeartbeatBuffer = GatewayHeartbeatBufferSized(19);

test "gateway heartbeat buffer set" {
	var buffer = GatewayHeartbeatBufferSized(2).make();
	const slice = try buffer.fmt(1);
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":1}",
		slice,
	);
}

test "gateway heartbeat buffer set shorter" {
	var buffer = GatewayHeartbeatBufferSized(2).make();
	_ = try buffer.fmt(22);
	const slice = try buffer.fmt(1);
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":1}",
		slice
	);
}

test "gateway heartbeat buffer set nullable" {
	var buffer = GatewayHeartbeatBufferSized(4).make();
	const slice = try buffer.fmt(@as(?u8, null));
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":null}",
		slice
	);
}
