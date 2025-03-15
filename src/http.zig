const std = @import("std");

pub const Api = struct {
	http: std.http.Client,
	buffer: std.ArrayList(u8),

	pub fn init(allocator: std.mem.Allocator) @This() {
		return @This() {
			.http = .{ .allocator = allocator },
			.buffer = std.ArrayList(u8).init(allocator),
		};
	}

	pub fn request(
		self: *@This(),
		endpoint: anytype,
		opts: struct {
			token: ?[]const u8,
		},
		payload: anytype,
		response: anytype,
	) !Response(response) {
		return try request_raw(
			endpoint,
			&self.http,
			.{
				.allocator = self.http.allocator,
				.token = opts.token,
				.response_storage = .{ .dynamic = &self.buffer },
			},
			payload,
			response,
		);
	}
};

pub fn ResponseValue(value: anytype) type {
	const T = @TypeOf(value);
	const t = @typeInfo(T);
	if (t == .type) {
		return if (@sizeOf(value) > 0) value else void;
	} else if (t == .null) { return void; }
	else { @compileError("expected type or void"); }
}

pub fn Response(comptime T: type) type {
	return struct {
		status: std.http.Status,
		value: ResponseValue(std.json.Parsed(T)),

		pub fn deinit(self: *@This()) void { self.value.deinit(); }
	};
}

const request_raw = request;
pub inline fn request(
	endpoint: anytype,
	client: *std.http.Client,
	opts: struct {
		allocator: std.mem.Allocator,
		token: ?[]const u8,
		response_storage: std.http.Client.FetchOptions.ResponseStorage,
		comptime leaky: bool = false,
	},
	payload: anytype,
	response: anytype,
) !Response(response) {
	const response_needs_parse =
		@typeInfo(@TypeOf(response)) == .type and @sizeOf(response) > 0;
	std.debug.assert(
		if (response_needs_parse) opts.response_storage != .ignore
	else true);

	var path_buffer: [512]u8 = undefined;
	const method, const path = blk: {
		const method = endpoint[0];
		const path_fmt = "/api/v10" ++ endpoint[1];
		const path_args = util.tupleSplit(endpoint, 2)[1];
		const path =
			try std.fmt.bufPrint(&path_buffer, path_fmt, path_args);
		break :blk .{ method, path };
	};

	// payload
	var payload_actual: ?[]const u8 = null;
	var payload_allocated = false;
	const Payload = @TypeOf(payload);
	if (util.isNull(payload)) {
		// do nothing
	} else if (comptime util.isString(Payload)) {
		payload_actual = payload;
	} else {
		payload_actual = try std.json.stringifyAlloc(
			opts.allocator,
			payload,
			.{}
		);
		payload_allocated = true;
	}
	defer if (payload_allocated) {
		opts.allocator.free(payload_actual.?);
	};

	// response
	const fetch_result = try client.fetch(.{
		.method = method,
		.location = .{ .uri = .{
			.scheme = "https",
			.port = 443,
			.host = .{ .raw = "discord.com" },
			.path = .{ .raw = path },
		} },
		.headers = .{
			.host = .{ .override = "discord.com" },
			.content_type = .{ .override =  "application/json" },
			.user_agent = .{
				.override =  "DiscordBot (https://example.com, 1)"
			},
			.authorization =
				if (opts.token) |value| .{ .override = value } else .omit,
		},
		.payload = payload_actual,
		.response_storage = opts.response_storage,
	});
	
	if (fetch_result.status.class() != .success) {
		std.log.err("request error code {any}", .{ fetch_result.status });
	}

	const ResponseActual = comptime Response(response);
	var result: ResponseActual = undefined;
	result.status = fetch_result.status;
	if (response_needs_parse) {
		const input = switch (opts.response_storage) {
			.ignore => unreachable,
			.dynamic => |a| a.items,
			.static => |a| a.items,
		};
		const parse = if (opts.leaky) std.json.parseFromSliceLeaky
			else std.json.parseFromSlice;
		result.value = try parse(
			response,
			opts.allocator,
			input,
			.{ .ignore_unknown_fields = true },
		);
	} else {
		result.value = {};
	}
	return result;
}

const util = struct {
	/// Checks that the given value is null and of an optional type.
	pub fn isNull(value: anytype) bool {
		return switch (@typeInfo(@TypeOf(value))) {
			.null => true,
			.optional => value == null,
			else => false,
		};
	}

	/// Checks if the given type is a string slice or pointer to a bytes
	/// array such as the case for string literals.
	pub fn isString(T: type) bool {
		return switch (@typeInfo(T)) {
			// .array => |p| return p.child == u8,
			.pointer => |p| {
				if (p.child == u8) { return true; }
				switch (@typeInfo(p.child)) {
					.array => |a| { return a.child == u8; },
					else => return false,
				}
			},
			else => false
		};
	}
	
	/// Tuple -> Types
	///
	/// Inverse of [std.meta.Tuple](https://ziglang.org/documentation/0.14.0/std/#std.meta.Tuple)
	pub fn untuple(Tuple: type) [std.meta.fields(Tuple).len]type {
		const fields = std.meta.fields(Tuple);
		var types: [fields.len]type = undefined;
		for (fields, 0..) |*field, i| {
			types[i] = field.*.@"type";
		}
		return types;
	}

	pub fn TupleSplit(Tuple: type, comptime pivot: comptime_int) type {
		const types = untuple(Tuple);
		return struct {
			std.meta.Tuple(types[0..pivot]),
			std.meta.Tuple(types[pivot..]),
		};
	}

	pub fn tupleSplit(
		tuple: anytype,
		comptime pivot: comptime_int,
	) TupleSplit(@TypeOf(tuple), pivot) {
		var split: TupleSplit(@TypeOf(tuple), pivot) = undefined;
		for (0..pivot) |i| { split[0][i] = tuple[i]; }
		for (pivot..std.meta.fields(@TypeOf(tuple)).len) |i| {
			split[1][i - pivot] = tuple[i];
		}
		return split;
	}
};
