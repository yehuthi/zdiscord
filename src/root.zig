const std = @import("std");
const websocket = @import("websocket");

pub const gateway = @import("./gateway.zig");

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

pub const Gateway = struct {
	allocator: std.mem.Allocator,
	client: *websocket.Client,
	sequence: Sequence = SEQUENCE_NULL,
	heartbeat_interval: Heartbeat = 0,
	client_mutex: std.Thread.Mutex = .{},

	const Sequence = i32;
	const SEQUENCE_NULL: Sequence = 0;
	const Heartbeat = u16;
	const Self = @This();

	pub fn deinit(self: *Self) void {
		// TODO: kill heartbeat thread
		self.client.deinit();
	}

	pub fn go_spawn(self: *Self) !std.Thread {
		return self.client.readLoopInNewThread(self);
	}

	pub fn identify_unchecked(self: *Self, data: gateway.Identify) !void {
		var buffer: [512]u8 = undefined;
		var allocator = std.heap.FixedBufferAllocator.init(&buffer);
		const message = try std.json.stringifyAlloc(
			allocator.allocator(),
			.{ .op = @intFromEnum(gateway.Opcode.identify), .d = data },
			.{},
		);
		std.log.debug(
			"Sending identify to gateway (message: \"{s}\")",
			.{ message }
		);
		try self.client.writeText(message);
	}

	pub fn identify(self: *Self, data: gateway.Identify) !void {
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
				op: gateway.Opcode,
				s: ?Sequence = null,
				t: ?[]const u8 = null,
			},
			self.allocator,
			message.data,
			.{ .ignore_unknown_fields = true, });
		defer json.deinit();

		if (json.value.s) |sequence_new| {
			self.sequence = sequence_new;
			_ = @atomicRmw(
				Sequence,
				&self.sequence,
				std.builtin.AtomicRmwOp.Max,
				sequence_new,
				// TODO: can probably do better than seq_cst
				std.builtin.AtomicOrder.seq_cst,
			);
			std.log.debug(
				"Gateway received opcode {s} ({d}) message",
				.{ @tagName(json.value.op), @intFromEnum(json.value.op) }
			);
		}

		std.log.debug(
			"Gateway received opcode {?} ({d}) message",
			.{ json.value.op, @intFromEnum(json.value.op) }
		);
		if (json.value.op == gateway.Opcode.hello) {
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
		var heartbeat_buffer = gateway.HeartbeatBuffer.make();
		// client.writeText destroys the message so we'll store a throwaway
		// copy here for it.
		var heartbeat_scratch: [gateway.HeartbeatBuffer.BUFFER_SIZE]u8 =
			undefined;
		while (true) {
			var sequence_actual: ?Sequence = null;
			if (self.sequence != SEQUENCE_NULL) {
				sequence_actual = self.sequence;
			}
			const message = try heartbeat_buffer.fmt(sequence_actual);
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

pub const Snowflake = u64;

pub const API = struct {
	http: *std.http.Client,
	token: []const u8,

	const BASE = "/api/v10";

	const Self = @This();

	pub fn send(
		self: *const Self,
		allocator: std.mem.Allocator,
		method: std.http.Method,
		path: []const u8,
		payload: anytype
	) !void {
		const payload_json =
			try std.json.stringifyAlloc(allocator, payload, .{});
		std.log.debug("Send to {any} {s}: \"{s}\"", .{ method, path, payload_json });
		defer allocator.free(payload_json);
		// TODO: handle response
		const result = try self.http.fetch(.{
			.method = method,
			.headers = .{
				.authorization = .{ .override = self.token },
				.content_type = .{ .override = "application/json" },
			},
			.location = .{ .uri = std.Uri {
				.scheme = "https",
				.host = .{ .raw = "discord.com" },
				.path = .{ .raw = path },
			}},
			.payload = payload_json,
		});
		std.log.debug("API send result: {any}", .{result});
	}

	pub const CreateMessage = struct {
		content: ?[]const u8 = null,
		nonce: ?union(enum) {
			integer: i32,
			string: []const u8,
		} = null,
		tts: ?bool = null,
		// TODO: embeds, allowed_mentions, message_reference, components
		sticker_ids: ?[]const Snowflake = null,
		// TODO: files
		payload_json: ?[]const u8 = null,
		// TODO: attachments
		flags: ?u32 = null, // TODO: <-
		enforce_nonce: ?bool = null,
		// TODO: poll

		pub fn path_buf(buf: []u8, channel: Snowflake) ![]u8 {
			return std.fmt.bufPrint(
				buf,
				BASE ++ "/channels/{d}/messages",
				.{ channel }
			);
		}
	};

	pub fn create_message(
		self: *const Self,
		channel: Snowflake,
		message: CreateMessage
	) !void {
		var buf: [128]u8 = undefined;
		try self.send(
			self.http.allocator,
			.POST,
			try CreateMessage.path_buf(&buf, channel),
			message,
		);
	}
};
