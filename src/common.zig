const std = @import("std");

/// Snowflake ID.
///
/// See: https://discord.com/developers/docs/reference#snowflakes
pub const Snowflake = u64;

/// Gets the snowflake's timestamp in Discord epoch (2015).
pub fn snowflake_timestamp_raw_ms(snowflake: Snowflake) u64 {
	return snowflake >> 22;
}

/// Gets the snowflake's timestamp in UNIX epoch (1970).
pub fn snowflake_timestamp_ms(snowflake: Snowflake) u64 {
	return snowflake_timestamp_raw_ms(snowflake) + 1420070400000;
}

test "snowflake timestamp raw" {
	try std.testing.expectEqual(
		41944705796,
		snowflake_timestamp_raw_ms(175928847299117063),
	);
}

test "snowflake timestamp" {
	try std.testing.expectEqual(
		1462015105796,
		snowflake_timestamp_ms(175928847299117063),
	);
}
