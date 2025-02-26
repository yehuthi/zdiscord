const std = @import("std");
const com = @import("./common.zig");

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

pub fn get_gateway_buf(
	client: *std.http.Client,
	buf: []u8
) ![]const u8 {
	var response = std.ArrayListUnmanaged(u8).initBuffer(buf);
	const host = "discord.com";
	const uri = comptime try std.Uri.parse(
		"https://" ++ host ++ "/api/v10/gateway"
	);
	const result = try client.fetch(.{
		.method           = .GET,
		.location         = .{ .uri    = uri                  },
		.response_storage = .{ .static = &response            },
		.headers          = .{ .host   = .{ .override = host }},
	});
	if (result.status != .ok) return error.status;
	const wss = extract_substring(response.items, "wss:", "\"")
		orelse return error.parse;
	return wss[6..];
}

pub const API = struct {
	http: *std.http.Client,
	token: []const u8,

	const BASE = "/api/v10";

	const Self = @This();


	pub const SendOpts = struct {
		// have to do this:
		// "Client requests that do not have a valid User Agent
		// specified may be blocked and return a Cloudflare error."
		user_agent: []const u8 = "DiscordBot (http://corndog.io, 1)",
		response_storage: std.http.Client.FetchOptions.ResponseStorage
			= .ignore,
		host: []const u8 = "discord.com",
	};

	pub fn send_raw(
		self: *const Self,
		allocator: std.mem.Allocator,
		method: std.http.Method,
		path: []const u8,
		payload: anytype,
		opts: SendOpts,
	) !void {
		const payload_json =
			try std.json.stringifyAlloc(allocator, payload, .{});
		std.log.debug(
			"Send to {any} {s}: \"{s}\"",
			.{ method, path, payload_json }
		);
		defer allocator.free(payload_json);
		const result = try self.http.fetch(.{
			.method = method,
			.headers = .{
				.authorization = .{ .override = self.token         },
				.content_type  = .{ .override = "application/json" },
				.user_agent    = .{ .override = opts.user_agent    },
			},
			.location = .{ .uri = std.Uri {
				.scheme = "https",
				.host = .{ .raw = opts.host },
				.path = .{ .raw = path },
			}},
			.payload = payload_json,
			.response_storage = opts.response_storage,
		});
		std.log.debug("API send result: {any}", .{result});
	}


	pub fn send(
		self: *const Self,
		allocator: std.mem.Allocator,
		comptime path: []const u8,
		path_args: anytype,
		payload: anytype,
		opts: SendOpts,
	) !void {
		const endpoint = comptime send_path_parse(path) catch |e| {
			@compileLog("send path format error: {any}", .{e});
			@compileError("send path format error");
		};
		var path_buffer: [256]u8 = undefined;
		const path_actual = try std.fmt.bufPrint(
			&path_buffer,
			"/api/v10" ++ endpoint.path,
			path_args,
		);
		return self.send_raw(
			allocator,
			endpoint.method,
			path_actual,
			payload,
			opts,
		);
	}

	fn send_path_parse(
		path: []const u8
	) !struct { method: std.http.Method, path: []const u8 } {
		var splitter = std.mem.splitScalar(u8, path, ' ');
		const method_str = splitter.next() orelse unreachable;
		const method = std.meta.stringToEnum(std.http.Method, method_str)
			orelse return error.method_bad;
		const path_str = splitter.next() orelse return error.path_missing;
		if (splitter.next() != null) return error.excess;
		return .{
			.method = method,
			.path = path_str,
		};
	}

	pub const CreateMessage = struct {
		content: ?[]const u8 = null,
		nonce: ?union(enum) {
			integer: i32,
			string: []const u8,
		} = null,
		tts: ?bool = null,
		// TODO: embeds, allowed_mentions, message_reference, components
		sticker_ids: ?[]const com.Snowflake = null,
		// TODO: files
		payload_json: ?[]const u8 = null,
		// TODO: attachments
		flags: ?u32 = null, // TODO: <-
		enforce_nonce: ?bool = null,
		// TODO: poll

		pub fn path_buf(buf: []u8, channel: com.Snowflake) ![]u8 {
			return std.fmt.bufPrint(
				buf,
				BASE ++ "/channels/{d}/messages",
				.{ channel }
			);
		}
	};

	pub fn create_message(
		self: *const Self,
		channel: com.Snowflake,
		message: CreateMessage
	) !void {
		var buf: [128]u8 = undefined;
		try self.send_raw(
			self.http.allocator,
			.POST,
			try CreateMessage.path_buf(&buf, channel),
			message,
		);
	}
};

test "send path parse" {
	const result = try API.send_path_parse("GET /");
	try std.testing.expectEqual(std.http.Method.GET, result.method);
	try std.testing.expectEqualStrings("/", result.path);
}

test "send path parse (create message)" {
	const result = try API.send_path_parse("POST /channels/{d}/messages");
	try std.testing.expectEqual(std.http.Method.POST, result.method);
	try std.testing.expectEqualStrings(
		"/channels/{d}/messages",
		result.path,
	);
}

test "send path parse bad method" {
	try std.testing.expectEqual(
		error.method_bad,
		API.send_path_parse("MEOW /"),
	);
}

test "send path parse path missing" {
	try std.testing.expectEqual(
		error.path_missing,
		API.send_path_parse("GET"),
	);
}
