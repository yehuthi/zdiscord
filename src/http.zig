const std = @import("std");
// const com = @import("./common.zig");

pub const Api = struct {
	client: *std.http.Client,
	headers: std.http.Client.Request.Headers,
	allocator: std.mem.Allocator,

	const Self = @This();

	pub fn send(
		self: *Self,
		comptime path_fmt: []const u8,
		path_args: anytype,
		in: anytype,
		comptime Out: type,
	) !SendOut(Out) {
		return _send(
			self.client,
			path_fmt,
			path_args,
			.{
				.allocator = self.allocator,
				.headers = self.headers,
			},
			in,
			Out,
		);
	}
};

pub fn SendOut(Data: type) type {
	return struct {
		status: std.http.Status,
		data: ?std.json.Parsed(Data),
	};
}

pub const SendInSpecial = union(enum) { nil, raw: []const u8 };

pub const BotHeaders = struct {
	token: ?[]const u8,
	host: []const u8 = "discord.com",
	user_agent: []const u8 = "DiscordBot (http://corndog.io, 1)",

	pub fn headers(self: @This()) std.http.Client.Request.Headers {
		return .{
			.host         = .{ .override = self.host          },
			.user_agent   = .{ .override = self.user_agent    },
			.content_type = .{ .override = "application/json" },
			.authorization = if (self.token) |value| .{ .override = value }
				else .omit,
		};
	}
};

fn _send(
	client: *std.http.Client,
	comptime path_fmt: []const u8,
	path_args: anytype,
	opts: struct {
		headers: std.http.Client.Request.Headers = .{},
		allocator: std.mem.Allocator,
		stringify_options: std.json.StringifyOptions = .{},
		parse_options: std.json.ParseOptions = .{
			.ignore_unknown_fields = true
		},
	},
	in: anytype,
	comptime Out: type,
) !SendOut(Out) {
	// path
	comptime var path_err: PathParseError = undefined;
	const path_parse = comptime send_path_parse(path_fmt, &path_err) catch {
		switch (path_err) {
			.expected_method => |e| {
				@compileLog("expected method, found \"{s}\"", .{ e.found });
			},
			.expected_path => @compileLog("expected path", .{}),
		}
	};
	comptime var path_buffer: [1024]u8 = undefined;
	const path = comptime try std.fmt.bufPrint(
		&path_buffer,
		path_parse.path,
		path_args
	);
	const method = path_parse.method;

	// in
	var payload: ?[]const u8 = null;
	var payload_alloc = false;
	if (@TypeOf(in) == SendInSpecial) {
		switch (in) {
			.nil => {},
			.raw => |raw| payload = raw,
		}
	} else {
		payload_alloc = true;
		payload = try std.json.stringifyAlloc(
			opts.allocator,
			in,
			opts.stringify_options,
		);
	}
	defer if (payload_alloc) opts.allocator.free(payload.?);

	// out
	var storage_data = std.ArrayList(u8).init(opts.allocator);
	errdefer storage_data.deinit();

	// fetch
	const host = "discord.com";
	const uri = std.Uri {
		.scheme = "https",
		.host = .{ .raw = host },
		.path = .{ .raw = "/api/v10" ++ path },
	};
	const fetch_result = try client.fetch(.{
		.method = method,
		.location = .{
			.uri = uri,
		},
		.headers = opts.headers,
		.payload = payload,
		.response_storage = .{ .dynamic = &storage_data },
	});
	const status = fetch_result.status;

	// parse out
	if (storage_data.items.len > 0) {
		const json = try std.json.parseFromSlice(
			Out,
			opts.allocator,
			storage_data.items,
			opts.parse_options,
		);
		return .{ .status = status, .data = json };
	}

	return .{ .status = status, .data = null };
}


const PathParseError = union(enum) {
	expected_method: struct { found: []const u8 },
	expected_path,
};

fn send_path_parse(
	comptime in: []const u8,
	err: *PathParseError,
) error{fail}!struct { method: std.http.Method, path: []const u8 } {
	const separator = std.mem.indexOfScalar(u8, in, ' ') orelse in.len;
	const method_str = in[0..separator];
	const method = std.meta.stringToEnum(std.http.Method, method_str)
		orelse {
			err.* = .{ .expected_method = .{ .found = method_str } };
			return error.fail;
		};

	const path_start = separator + 1; // skip the space
	if (path_start >= in.len) {
		err.* = .expected_path;
		return error.fail;
	}
	const path = in[path_start..];

	return .{
		.method = method,
		.path = path,
	};
}

test "path parse expects method" {
	var err: PathParseError = undefined;
	// empty
	try std.testing.expectEqual(error.fail, send_path_parse("", &err));
	try std.testing.expectEqualStrings("expected_method", @tagName(err));
	try std.testing.expectEqualStrings("", err.expected_method.found);
	// unrecognized
	try std.testing.expectEqual(error.fail, send_path_parse("blah", &err));
	try std.testing.expectEqualStrings("expected_method", @tagName(err));
	try std.testing.expectEqualStrings("blah", err.expected_method.found);
	// unrecognized with path
	try std.testing.expectEqual(
		error.fail,
		send_path_parse("blah /path", &err),
	);
	try std.testing.expectEqualStrings("expected_method", @tagName(err));
	try std.testing.expectEqualStrings("blah", err.expected_method.found);
}

test "path parse expects path" {
	var err: PathParseError = undefined;
	// empty
	try std.testing.expectEqual(error.fail, send_path_parse("GET", &err));
	try std.testing.expectEqual(.expected_path, err);
	// whitespace
	try std.testing.expectEqual(error.fail, send_path_parse("GET ", &err));
	try std.testing.expectEqual(.expected_path, err);
}

test "path parse" {
	var err: PathParseError = undefined;
	const result = try send_path_parse("POST /a/b/c", &err);
	try std.testing.expectEqual(.POST, result.method);
	try std.testing.expectEqualStrings("/a/b/c", result.path);
}
