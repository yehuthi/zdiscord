//! Gateway API.

const std = @import("std");

const ws = @import("websocket");

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

pub const Gateway = struct {
	client: ws.Client = undefined,
	client_mutex: std.Thread.Mutex = .{},
	sequence: Sequence = 0,

	const Self = @This();

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

	pub fn receive_hello_leaky(
		self: *Self, arena_allocator: std.mem.Allocator
	) !usize {
		const hello = try next_message_leaky(
			&self.client,
			arena_allocator,
			struct {
				d: struct { heartbeat_interval: usize },
			},
		);
		return hello.data.d.heartbeat_interval;
	}

	pub fn heartbeat_locking(self: *Self) !void {
		const sequence_now = self.sequence;

		var buffer: [64]u8 = undefined;
		const message = std.fmt.bufPrint(
			&buffer,
			"{{\"op\":1,\"d\":{d}}}",
			.{ sequence_now },
		) catch unreachable;
		// TODO: deal with sequence being invalidated in the interim.

		self.client_mutex.lock();
		std.log.info(
			"sending heartbeat ({d})",
			.{ sequence_now },
		);
		self.client.write(message) catch |e|
			std.debug.panic(
				"heartbeat write failed {any}", .{ e }
			);
		self.client_mutex.unlock();
	}

	pub fn heartbeat_loop(self: *Self, interval: usize) !void {
		const sleep_interval = interval * std.time.ns_per_ms;
		while (true) {
			try self.heartbeat_locking();
			std.time.sleep(sleep_interval);
		}
	}

	pub fn go(self: *Self, arena: *std.heap.ArenaAllocator) !void {
		const arena_allocator = arena.allocator();
		while (true) {
			defer _ = arena.reset(.{ .retain_with_limit = 5120 });

			const message = try next_message_leaky(
				&self.client, arena_allocator, struct {
					op: Opcode,
					s: ?Sequence = null,
					t: ?[]const u8 = null,
				}
			);
			defer self.client.done(message.raw);

			std.log.info("received {s}", .{ message.raw.data });

			if (message.data.op == opcode.heartbeat) {
				try self.heartbeat_locking();
			}

			if (message.data.s) |sequence_new| {
				self.sequence = sequence_new;
			}
		}
	}

	pub fn start(
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
				self.receive_hello_leaky(arena_allocator) catch |e|
					switch (e) {
						error.message_non_text =>
							return error.hello_non_text,
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
			Self.heartbeat_loop,
			.{ self, heartbeat_interval }
		);
		thread_heartbeat.detach();

		try self.go(&arena);
	}

	/// Gets the next message from the gateway, JSON-parsed into T.
	fn next_message_leaky(
		client: *ws.Client,
		allocator: std.mem.Allocator,
		T: type,
	) !struct { data: T, raw: ws.proto.Message } {
		const message = try client.read() orelse
			unreachable; // there should never be a timeout on the client
		errdefer client.done(message);

		if (message.type != .text) { return error.message_non_text; }

		const parsed = try std.json.parseFromSliceLeaky(
			T,
			allocator,
			message.data,
			.{ .ignore_unknown_fields = true },
		);

		return .{
			.data = parsed,
			.raw = message,
		};
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
