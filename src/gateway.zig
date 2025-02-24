const std = @import("std");
const websocket = @import("websocket");

pub const MessageRaw = websocket.Message;

/// A gateway (websocket) client with a mutex.
pub const Client = struct {
	/// The websocket client.
	client: websocket.Client,
	/// The mutex.
	mutex: std.Thread.Mutex,

	const Self = @This();

	/// Connects to the gateway.
	pub fn connect(allocator: std.mem.Allocator, opts: ConnectOpts) !Self {
		return Self {
			.client = try connect_ws(allocator, opts),
			.mutex = std.Thread.Mutex {},
		};
	}

	/// Writes text to the websocket (destroys the given data due to
	/// websocket masking).
	pub fn write_text(self: *Self, data: []u8) !void {
		self.mutex.lock();
		try self.client.writeText(data);
		self.mutex.unlock();
	}

	/// Closes the connection.
	///
	/// Use code `1000` or `1001` to disconnect the bot (making it appear
	/// offline). Use any other code to disconnect the bot but be able to
	/// Resume.
	pub fn close(self: *Self, opts: struct { code: u16 = 1000 }) void {
		self.mutex.lock();
		self.client.closeWithCode(opts.code);
		self.mutex.unlock();
	}

	/// Registers a SIGINT (Ctrl+C) handler that disconnects the bot so it
	/// will appear offline, before terminating the program.
	///
	/// Consider it (at least currently) a hacky a convenience function for
	/// suitable for small programs. It cannot be used for multiple
	/// connections, and and currently only works for POSIX (doesn't work
	/// on Windows).
	pub fn sigint_register(self: *Self) !void {
		const Handler = struct {
			var client_global: ?*Client = null;
			pub fn handler(_: c_int) callconv(.C) void {
				client_global.?.close(.{});
			}
		};
		Handler.client_global = self;
		try std.posix.sigaction(
			std.posix.SIG.INT,
			&.{
				.flags = 0,
				.mask = std.posix.empty_sigset,
				.handler = .{ .handler = Handler.handler },
			},
			null
		);
	}
};

const ConnectOpts = struct {
	timeout_ms: u32 = 5_000,
	comptime host: []const u8 = "gateway.discord.gg",
	port: u16 = 443,
	tls: bool = true,
	comptime encoding: []const u8 = "json",
	comptime version: []const u8 = "10",
};

const connect_ws = connect;
/// Creates a websocket client, connects it to the gateway and handshakes.
pub fn connect(
	allocator: std.mem.Allocator,
	opts: ConnectOpts,
) !websocket.Client {
	var client = try websocket.connect(
		allocator,
		opts.host,
		opts.port,
		.{ .tls = opts.tls },
	);
	try client.handshake(
		"/?v=" ++ opts.version ++ "&encoding=" ++ opts.encoding,
		.{
			.timeout_ms = opts.timeout_ms,
			.headers = "host: " ++ opts.host,
		}
	);
	return client;
}


pub const Sequence = u32;
pub const SEQUENCE_NULL: Sequence = 0;

pub fn Gateway(Handler: type) type {
	return struct {
		client: *Client,
		handler: Handler,

		const Self = @This();

		pub fn go_spawn(self: *Self) !std.Thread {
			return self.client.client.readLoopInNewThread(self);
		}

		pub fn handle(self: *Self, message: MessageRaw) !void {
			self.handler.handle(message) catch |e| {
				std.log.err(
					"Gateway handler error: {any}; blissfully ignoring",
					.{ e }
				);
			};
		}

		pub fn close(_: *Self) void {
			std.log.info("gateway connection closed", .{});
		}

		pub fn identify(
			self: *Self,
			data: Identify,
		) !void {
			var buffer: [512]u8 = undefined;
			var allocator = std.heap.FixedBufferAllocator.init(&buffer);
			const message = try std.json.stringifyAlloc(
				allocator.allocator(),
				.{ .op = opcode.identify, .d = data },
				.{},
			);
			std.log.debug(
				"Sending identify to gateway (message: \"{s}\")",
				.{ message }
			);
			try self.client.write_text(message);
		}

		pub fn disconnect(self: *Self) !void {
			self.client.close(.{});
		}
	};
}

pub const middleware = struct {
	pub fn MessageText(Inner: type) type {
		return struct {
			inner: Inner,

			pub fn handle(self: *@This(), message: MessageRaw) !void {
				if (message.type != .text) {
					std.log.warn(
						"Gateway received a non-message ({s}); ignoring",
						.{ @tagName(message.type) }
					);
				}
				try self.inner.handle(message.data);
			}
		};
	}

	pub fn Destruct(Inner: type) type {
		return struct {
			inner: Inner,
			allocator: std.mem.Allocator,

			pub const Value = struct {
				op: u8,
				s: ?u32,
				message: []const u8,
			};

			pub fn handle(self: *@This(), message: []const u8) !void {
				const data = try std.json.parseFromSlice(
					struct { op: u8, s: ?u32 = null },
					self.allocator,
					message,
					.{ .ignore_unknown_fields = true },
				);
				defer data.deinit();

				try self.inner.handle(.{
					.message = message,
					.op = data.value.op,
					.s = data.value.s,
				});
			}
		};
	}

	pub fn SequenceUpdate(Inner: type) type {
		return struct {
			inner: Inner,
			sequence: *Sequence,

			fn handle(self: *@This(), message: anytype) !void {
				if (message.s) |sequence_new| {
					_ = @atomicRmw(
						Sequence, self.sequence,
						.Max, sequence_new,
						// TODO: can probably do better than seq_cst
						std.builtin.AtomicOrder.seq_cst,
					);
				}
				try self.inner.handle(message);
			}
		};
	}

	pub fn Heartbeat(Inner: type) type {
		// TODO: check we got ACK for previous heartbeat (if made)
		return struct {
			inner: Inner,
			client: *Client,
			allocator: std.mem.Allocator,
			thread: ?std.Thread = null,
			interval_ms: u64 = 0,
			sequence: *Sequence,
			heartbeat_buffer: HeartbeatBuffer = HeartbeatBuffer.make(),

			fn handle(self: *@This(), message: anytype) !void {
				if (message.op == opcode.hello) {
					{
						const data = try std.json.parseFromSlice(
							struct {
								d: struct { heartbeat_interval: u32 }
							},
							self.allocator,
							message.message,
							.{ .ignore_unknown_fields = true },
						);
						defer data.deinit();
						self.interval_ms = data.value.d.heartbeat_interval;
					}
					// TODO: bad assumption:
					std.debug.assert(self.thread == null);
					self.thread = try std.Thread.spawn(
						.{},
						loop,
						.{self},
					);
				}
				else if (message.op == opcode.heartbeat) {
					try self.beat();
				}
				try self.inner.handle(message);
			}

			fn loop(self: *@This()) !void {
				while (true) {
					try self.beat();
					std.time.sleep(
						@as(u64, self.interval_ms) * std.time.ns_per_ms
					);
				}
				std.log.info("Heartbeat loop stopped", .{});
			}

			fn beat(self: *@This()) !void {
				// client.writeText destroys the message so we'll store a
				// throwaway copy here for it.
				var heartbeat_scratch: [HeartbeatBuffer.BUFFER_SIZE]u8 =
					undefined;
				var sequence_actual: ?Sequence = null;
				if (self.sequence.* != SEQUENCE_NULL) {
					sequence_actual = self.sequence.*;
				}
				const message =
					try self.heartbeat_buffer.fmt(sequence_actual);
				std.log.debug(
					"Sending heartbeat to gateway (sequence {any}), " ++
					"payload: \"{s}\"",
					.{ self.sequence, message }
				);
				@memcpy(heartbeat_scratch[0..message.len], message);
				try self.client.write_text(
					heartbeat_scratch[0..message.len]
				);
			}
		};
	}
};

/// The actual representation for intents.
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

/// All gateway events in Discord are tagged with an opcode that denotes
/// the payload type.
///
/// See:
/// https://discord.com/developers/docs/topics/opcodes-and-status-codes
pub const Opcode = u8;
pub const opcode = struct {
	/// An event was dispatched.
	const dispatch: Opcode = 0;
	/// Fired periodically by the client to keep the connection alive.
	const heartbeat: Opcode = 1;
	/// Starts a new session during the initial handshake.
	const identify: Opcode = 2;
	/// Update the client's presence.
	const presence_update: Opcode = 3;
	/// Used to join/leave or move between voice channels.
	const voice_state_update: Opcode = 4;
	/// Resume a previous session that was disconnected.
	const @"resume": Opcode = 6;
	/// You should attempt to reconnect and resume immediately.
	const reconnect: Opcode = 7;
	/// Request information about offline guild members in a large guild.
	const request_guild_members: Opcode = 8;
	/// The session has been invalidated. You should reconnect and
	/// identify/resume accordingly.
	const invalid_session: Opcode = 9;
	/// Sent immediately after connecting, contains the
	/// `heartbeat_interval` to use.
	const hello: Opcode = 10;
	/// Sent in response to receiving a heartbeat to acknowledge that it
	/// has been received.
	const heartbeat_ack: Opcode = 11;
	/// Request information about soundboard sounds in a set of guilds.
	const request_soundboard_sounds: Opcode = 31;
};

/// A buffer for heartbeat messages.
/// 
/// `SIZE` is the number of bytes / "characters" that the payload may
/// contain (see `HeartbeatBuffer`).
pub fn HeartbeatBufferSized(SIZE: comptime_int) type {
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
				if (@typeInfo(@TypeOf(value)) == .Optional) {
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
			return self.data[0..PREFIX.len + wrote.len];
		}
	};
}

/// `HeartbeatBufferSized` with a default size.
pub const HeartbeatBuffer = HeartbeatBufferSized(19);

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

/// Gateway Identify structure.
///
/// See: https://discord.com/developers/docs/events/gateway-events#identify-identify-structure
pub const Identify = struct {
	/// Authentication token.
	token: []const u8,
	/// Gateway Intents you wish to receive.
	intents: Intent,
	/// Connection properties.
	properties: struct {
		/// Your operating system.
		os: []const u8 = "TempleOS",
		/// Your library name.
		browser: []const u8 = library_name,
		/// Your library name.
		device: []const u8 = library_name,
	} = .{},

	// TODO: get it from .zon (wait for zig 0.14.0?)
	// https://github.com/ziglang/zig/pull/20271
	const library_name = "zdiscord";
};

