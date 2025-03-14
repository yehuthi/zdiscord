const std = @import("std");

pub fn request(
	endpoint: anytype,
	client: *std.http.Client,
	opts: struct {
		token: ?[]const u8,
	},
	payload: ?[]const u8,
) !void {
	var path_buffer: [512]u8 = undefined;
	const method, const path = blk: {
		const method = endpoint[0];
		const path_fmt = "/api/v10" ++ endpoint[1];
		const path_args = util.tupleSplit(endpoint, 2)[1];
		const path =
			try std.fmt.bufPrint(&path_buffer, path_fmt, path_args);
		break :blk .{ method, path };
	};

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
		.payload = payload,
	});
	
	if (fetch_result.status.class() != .success) {
		std.log.err("request error code {any}", .{ fetch_result.status });
		return error.BadStatus;
	}
}

const util = struct {
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
