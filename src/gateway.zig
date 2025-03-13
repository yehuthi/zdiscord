//! Gateway API.

const std = @import("std");

const ws = @import("websocket");

pub const Gateway = struct {
	client: ws.Client = undefined,
	client_mutex: std.Thread.Mutex = .{},
	sequence: ?Sequence = null,

	const Self = @This();

	/// Connects to the websocket endpoint and performs a handshake.
	pub fn connect(self: *Self, allocator: std.mem.Allocator) !void {
		const host = "gateway.discord.gg";

		var client = try ws.Client.init(allocator, .{
			.tls = true,
			.port = 443,
			.host = host,
		});
		errdefer client.deinit();
		try client.handshake("/?v=10&encoding=json", .{
			.headers = "Host: " ++ host,
		});

		self.client = client;
	}

	/// Reads the heartbeat interval from Hello.
	///
	/// Assumes Hello is the next thing to be read.
	pub fn receiveHelloLeaky(
		self: *Self, arena_allocator: std.mem.Allocator
	) !usize {
		const hello = try self.nextMessageLeakyUnhandled(
			arena_allocator,
			struct {
				d: struct { heartbeat_interval: usize },
			},
		);
		return hello.data.d.heartbeat_interval;
	}

	/// Sends a heartbeat as soon as possible.
	pub fn heartbeat(self: *Self) !void {
		const sequence_now = self.sequence;

		var buffer: [64]u8 = undefined;
		const message = std.fmt.bufPrint(
			&buffer,
			"{{\"op\":1,\"d\":{?}}}",
			.{ sequence_now },
		) catch unreachable;
		// TODO: deal with sequence being invalidated in the interim.

		self.client_mutex.lock();
		std.log.info(
			"sending heartbeat ({?})",
			.{ sequence_now },
		);
		self.client.write(message) catch |e|
			std.debug.panic(
				"heartbeat write failed {any}", .{ e }
			);
		self.client_mutex.unlock();
	}

	/// Sends heartbeats at every `interval` milliseconds.
	///
	/// This is an infinite loop which only breaks on errors.
	pub fn heartbeatLoop(self: *Self, interval: usize) !void {
		const sleep_interval = interval * std.time.ns_per_ms;
		var buffer = HeartbeatBuffer.make();
		while (true) {
			self.client_mutex.lock();
			std.log.debug("beating from loop (sequence {?})", .{self.sequence});
			try self.client.write(
				try buffer.fmt(self.sequence)
			);
			self.client_mutex.unlock();
			std.time.sleep(sleep_interval);
		}
	}

	pub fn go(self: *Self, arena: *std.heap.ArenaAllocator) !void {
		const arena_allocator = arena.allocator();
		while (true) {
			defer _ = arena.reset(.{ .retain_with_limit = 5120 });

			const message = try nextMessageLeakyUnhandled(
				&self.client, arena_allocator, struct {
					op: Opcode,
					s: ?Sequence = null,
					t: ?[]const u8 = null,
				}
			);
			defer self.client.done(message.raw);

			std.log.info("received {s}", .{ message.raw.data });

			if (message.data.op == opcode.heartbeat) {
				try self.heartbeat();
			}

			if (message.data.s) |sequence_new| {
				std.log.debug("updating sequence to {d}", .{ sequence_new });
				self.sequence = sequence_new;
			}
		}
	}

	/// Common bot setup.
	///
	/// This is a convenience function that:
	/// 1. `connect`s the bot
	/// 2. `Identify`s
	/// 3. Starts a heartbeat thread.
	pub fn setup(
		self: *Self,
		opts: struct {
			allocator: std.mem.Allocator,
			identify: Identify,
		},
	) !void {
		var arena = std.heap.ArenaAllocator.init(opts.allocator);
		const arena_allocator = arena.allocator();

		try self.connect(opts.allocator);

		{ // identify
			defer _ = arena.reset(.retain_capacity);
			try self.client.write(try opts.identify.json(arena_allocator));
		}

		const heartbeat_interval = blk: {
			defer _ = arena.reset(.retain_capacity);
			const heartbeat_interval =
				self.receiveHelloLeaky(arena_allocator) catch |e|
					switch (e) {
						error.MessageNotText =>
							return error.HelloNotText,
						else => return e,
					};
			std.log.info("heartbeat interval: {d:.2}s", .{
				@as(f64, @floatFromInt(heartbeat_interval))
					/ std.time.ms_per_s
			});
			break :blk heartbeat_interval;
		};

		const thread_heartbeat = try std.Thread.spawn(
			.{},
			Self.heartbeatLoop,
			.{ self, heartbeat_interval }
		);
		thread_heartbeat.detach();
	}

	/// Gets the next message from the gateway, JSON-parsed into T.
	///
	/// Unlike `getMessageLeaky`, this function does not maintain the
	/// client state or connection.
	fn nextMessageLeakyUnhandled(
		self: *Self,
		allocator: std.mem.Allocator,
		T: type,
	) !struct { data: T, proto: ws.proto.Message } {
		const proto = blk: {
			self.client_mutex.lock();
			defer self.client_mutex.unlock();
			const proto = try self.client.read() orelse
				unreachable; // there should never be a ws client timeout
			break :blk proto;
		};
		errdefer self.client.done(proto);

		if (proto.type != .text) {
			@branchHint(.cold);
			return error.MessageNotText;
		}

		const payload = try std.json.parseFromSliceLeaky(
			T,
			allocator,
			proto.data,
			.{ .ignore_unknown_fields = true }
		);

		return .{
			.data = payload,
			.proto = proto,
		};
	}

	/// Gets the next message from the gateway, using an arena to allocate.
	///
	/// Warning: this function may reset the arena! (retains capacity)
	pub fn nextMessageLeaky(
		self: *Self,
		arena: *std.heap.ArenaAllocator,
	) !Message {
		const message = try self.nextMessageLeakyUnhandled(
			arena.allocator(),
			struct {
				op: Opcode,
				s: ?Sequence = null,
				t: ?[]const u8 = null,
			},
		);

		if (message.data.op == opcode.heartbeat) {
			try self.heartbeat();
			_ = arena.reset(.retain_capacity);
			return self.nextMessageLeaky(arena);
		}
		if (message.data.s) |new_sequence| {
			self.sequence = new_sequence;
		}

		return Message {
			.client = &self.client,
			.client_mutex = &self.client_mutex,
			.opcode = message.data.op,
			.sequence = message.data.s,
			.@"type" = message.data.t,
			.proto = message.proto,
		};
	}
};

pub const Message = struct {
	client: *ws.Client,
	client_mutex: *std.Thread.Mutex,
	opcode: Opcode,
	sequence: ?Sequence,
	@"type": ?[]const u8,
	proto: ws.proto.Message,

	pub fn deinit(self: @This()) void {
		self.client_mutex.lock();
		self.client.done(self.proto);
		self.client_mutex.unlock();
	}
};

/// [Identify](https://discord.com/developers/docs/events/gateway-events#identify) structure.
pub const Identify = struct {
	/// Authentication token.
	token: []const u8,
	/// [Gateway Intents](https://discord.com/developers/docs/events/gateway#gateway-intents) you wish to receive.
	intents: Intent,
	/// [Connection property](https://discord.com/developers/docs/events/gateway-events#identify-identify-connection-properties) `os` (your operating system)
	os: []const u8 = "TempleOS",
	/// [Connection properties](https://discord.com/developers/docs/events/gateway-events#identify-identify-connection-properties) `browser` and `device` (your library name).
	lib: []const u8 = "zdiscord",

	/// Stringify into a gateway JSON message (object of `op` and `d`).
	///
	/// Caller owns returned memory.
	pub fn json(self: @This(), allocator: std.mem.Allocator) ![]u8 {
		return std.json.stringifyAlloc(
			allocator,
			.{
				.op = opcode.identify,
				.d = .{
					.token = self.token,
					.intents = self.intents,
					.properties = .{
						.os = self.os,
						.browser = self.lib,
						.device = self.lib,
					},
				}
			},
			.{},
		);
	}
};


pub const Sequence = usize;

/// Gateway opcodes.
///
/// See [Opcodes and Status Codes](https://discord.com/developers/docs/topics/opcodes-and-status-codes).
pub const Opcode = u8;
/// `Opcode` constants.
pub const opcode = struct {
	/// An event was dispatched.
	/// Receive
	pub const dispatch: Opcode = 0;
	///Fired periodically by the client to keep the connection alive.
	/// Send/Receive
	pub const heartbeat: Opcode = 1;
	/// Starts a new session during the initial handshake.
	/// Send
	pub const identify: Opcode = 2;
	/// Update the client's presence.
	/// Send
	pub const presence_update: Opcode = 3;
	/// Used to join/leave or move between voice channels.
	/// Send
	pub const voice_status_update: Opcode = 4;
	/// Resume a previous session that was disconnected.
	/// Send
	pub const @"resume": Opcode = 6;
	/// You should attempt to reconnect and resume immediately.
	/// Receive
	pub const reconnect: Opcode = 7;
	/// Request information about offline guild members in a large guild.
	pub const request_guild_members: Opcode = 8;
	/// The session has been invalidated. You should reconnect and
	/// identify/resume accordingly.
	/// Receive
	pub const invalid_session: Opcode = 9;
	/// Sent immediately after connecting, contains the
	/// `heartbeat_interval` to use.
	/// Receive
	pub const hello: Opcode = 10;
	/// Sent in response to receiving a heartbeat to acknowledge that it
	/// has been received.
	/// Receive
	pub const heartbeat_ack: Opcode = 11;
	/// Request information about soundboard sounds in a set of guilds.
	/// Send
	pub const request_soundboard_sounds: Opcode = 31;
};

/// [Gateway Close Event Codes](https://discord.com/developers/docs/topics/opcodes-and-status-codes#gateway-gateway-close-event-codes).
pub const CloseCode = u16;
/// `CloseCode` constants.
pub const close_code = struct {
	/// We're not sure what went wrong. Try reconnecting?
	/// Reconnect
	pub const unknown_error: CloseCode = 4000;
	/// You sent an invalid Gateway opcode or an invalid payload for an
	/// opcode. Don't do that!
	/// Reconnect
	pub const unknown_opcode: CloseCode = 4001;
	/// You sent an invalid payload to Discord. Don't do that!
	/// Reconnect
	pub const decode_error: CloseCode = 4002;
	/// You sent us a payload prior to identifying, or this session has
	/// been invalidated.
	/// Reconnect
	pub const not_authenticated: CloseCode = 4003;
	/// The account token sent with your identify payload is incorrect.
	/// Don't reconnect
	pub const authentication_failed: CloseCode = 4004;
	/// You sent more than one identify payload. Don't do that!
	/// Reconnect
	pub const already_authenticated: CloseCode = 4005;
	/// The sequence sent when resuming the session was invalid. Reconnect
	/// and start a new session.
	/// Reconnect
	pub const invalid_seq: CloseCode = 4007;
	/// Woah nelly! You're sending payloads to us too quickly. Slow it
	/// down! You will be disconnected on receiving this.
	/// Reconnect
	pub const rate_limited: CloseCode = 4008;
	/// Your session timed out. Reconnect and start a new one.
	/// Reconnect
	pub const session_timed_out: CloseCode = 4009;
	/// You sent us an invalid shard when identifying.
	/// Don't reconnect
	pub const invalid_shard: CloseCode = 4010;
	/// The session would have handled too many guilds - you are required
	/// to shard your connection in order to connect.
	/// Don't reconnect
	pub const sharding_required: CloseCode = 4011;
	/// You sent an invalid version for the gateway.
	/// Don't reconnect
	pub const invalid_api_version: CloseCode = 4012;
	/// You sent an invalid intent for a Gateway Intent. You may have
	/// incorrectly calculated the bitwise value.
	/// Don't reconnect
	pub const invalid_intent: CloseCode = 4013;
	/// You sent a disallowed intent for a Gateway Intent. You may have
	/// tried to specify an intent that you have not enabled or are not
	/// approved for.
	/// Don't reconnect
	pub const disallowed_intent: CloseCode = 4014;
};

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

/// A buffer for heartbeat messages.
/// 
/// `SIZE` is the number of bytes / "characters" that the payload may
/// contain (see `HeartbeatBuffer`).
fn HeartbeatBufferSized(SIZE: comptime_int) type {
	if (SIZE <= 0) {
		@compileError(
			"Gateway heartbeat buffer size must be " ++
			"greater than zero"
		);
	}
	return struct {
		data: [BUFFER_SIZE]u8,

		// prefix + last sequence + '}'
		pub const BUFFER_SIZE = PREFIX.len + SIZE + 1;

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
				if (@typeInfo(@TypeOf(value)) == .optional) {
					if (SIZE < 4) { // not enough room for "null" literal
						@compileError(
							"Buffer size is too small for " ++
							"nullable (must be at least 4)"
						);
					}
				}
			}
			const wrote = try std.fmt.bufPrint(
				self.data[PREFIX.len..],
				"{?}}}",
				.{ value }
			);
			std.log.debug("DEBUG WROTE {d}: \"{s}\"", .{ wrote.len, wrote });
			return self.data[0..PREFIX.len + wrote.len];
		}
	};
}

/// `HeartbeatBufferSized` with a default size.
pub const HeartbeatBuffer = HeartbeatBufferSized(20);

test "gateway heartbeat buffer set" {
	var buffer = HeartbeatBufferSized(2).make();
	const slice = try buffer.fmt(1);
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":1}",
		slice,
	);
}

test "gateway heartbeat buffer set shorter" {
	var buffer = HeartbeatBufferSized(2).make();
	_ = try buffer.fmt(22);
	const slice = try buffer.fmt(1);
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":1}",
		slice
	);
}

test "gateway heartbeat buffer set nullable" {
	var buffer = HeartbeatBufferSized(4).make();
	const slice = try buffer.fmt(@as(?u8, null));
	try std.testing.expectEqualStrings(
		"{\"op\":1,\"d\":null}",
		slice
	);
}

test "gateway heartbeat buffer default size can hold u64" {
	var buffer = HeartbeatBuffer.make();
	_ = try buffer.fmt(std.math.maxInt(u64));
}
