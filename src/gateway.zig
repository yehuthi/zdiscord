//! Gateway API.

const std = @import("std");

const ws = @import("websocket");

pub const Identify = struct {
	token: []const u8,
	intents: Intent,
	os: []const u8 = "TempleOS",
	lib: []const u8 = "zdiscord",
};

pub const Gateway = struct {
	const Self = @This();

	pub fn connect(
		self: *Self,
		opts: struct {
			allocator: std.mem.Allocator,
			identify: Identify,
		},
	) !void {
		_ = self;
		const host = "gateway.discord.gg";

		var sequence: Sequence = 0;
		var client_mutex = std.Thread.Mutex {};
		var client = try ws.Client.init(opts.allocator, .{
			.tls = true,
			.port = 443,
			.host = host,
		});
		errdefer client.deinit();
		try client.handshake("/?v=10&encoding=json", .{
			.headers = "Host: " ++ host,
		});

		var arena = std.heap.ArenaAllocator.init(opts.allocator);
		const arena_allocator = arena.allocator();

		{ // Hello
			defer _ = arena.reset(.retain_capacity);
			const hello = try next_message_leaky(
				&client,
				arena_allocator,
				struct {
					d: struct { heartbeat_interval: usize },
				},
			);
			std.log.info("heartbeat interval: {d:.2}s", .{
				@as(f64, @floatFromInt(hello.data.d.heartbeat_interval)) / std.time.ms_per_s
			});

			{ // identify
				defer _ = arena.reset(.retain_capacity);
				const message = try std.json.stringifyAlloc(
					arena_allocator,
					.{
						.op = opcode.identify,
						.d = .{
							.token = opts.identify.token,
							.intents = opts.identify.intents,
							.properties = .{
								.os = opts.identify.os,
								.browser = opts.identify.lib,
								.device = opts.identify.lib,
							},
						}
					},
					.{},
				);
				try client.write(message);
			}

			const thread_heartbeat = try std.Thread.spawn(.{}, struct {
				pub fn f(
					client_t: *ws.Client,
					client_mutex_t: *std.Thread.Mutex,
					sequence_t: *Sequence,
					heartbeat_interval: usize,
				) void {
					const sleep_interval = heartbeat_interval * std.time.ns_per_ms;
					var buffer: [128]u8 = undefined;
					while (true) {
						{
							const sequence_now = sequence_t.*;
							const message = std.fmt.bufPrint(
								&buffer,
								"{{\"op\":1,\"d\":{d}}}",
								.{ sequence_now },
							) catch unreachable;
							// TODO: deal with sequence being invalidated
							// in the interim.
							client_mutex_t.lock();
							std.log.info("sending heartbeat ({})", .{ sequence_now });
							client_t.write(message) catch unreachable;
							defer client_mutex_t.unlock();
						}
						std.time.sleep(sleep_interval);
					}
				}
			}.f, .{ &client, &client_mutex, &sequence, hello.data.d.heartbeat_interval });
			thread_heartbeat.detach();
		}

		while (true) {
			defer _ = arena.reset(.{ .retain_with_limit = 5120 });

			const message = try next_message_leaky(
				&client, arena_allocator, struct {
					op: Opcode,
					s: ?Sequence = null,
					t: ?[]const u8 = null,
				}
			);
			defer client.done(message.raw);

			if (message.data.s) |sequence_new| { sequence = sequence_new; }

			std.log.info("received {s}", .{ message.raw.data });
		}
	}

	fn next_message_leaky(
		client: *ws.Client,
		allocator: std.mem.Allocator,
		@"type": type,
	) !struct { data: @"type", raw: ws.proto.Message } {
		const message = try client.read() orelse {
			return error.read_failure;
		};
		defer client.done(message);

		if (message.type != .text) {
			std.log.warn(
				"gateway received non-text message: \"{s}\"",
				.{ std.fmt.fmtSliceHexLower(message.data) },
			);
			return error.message_non_text;
		}

		const parsed = try std.json.parseFromSliceLeaky(
			@"type",
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
