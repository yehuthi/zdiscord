//! Gateway API.

const std = @import("std");

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

