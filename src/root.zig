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

pub const Gateway = struct {
	allocator: std.mem.Allocator,
	client: *websocket.Client,
	sequence: ?Sequence = null,
	heartbeat_interval: Heartbeat = 0,

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
