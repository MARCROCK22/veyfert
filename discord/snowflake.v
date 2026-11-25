module discord

// discord_epoch is the first millisecond of 2015, where Discord snowflakes start counting.
pub const discord_epoch = u64(1420070400000)

// Snowflake is a Discord ID. Discord writes IDs as JSON strings because they overflow a double;
// the hooks below accept strings or numbers and always write strings.
pub struct Snowflake {
pub mut:
	value u64
}

// Snowflake.parse reads a decimal ID, such as one copied with Discord's developer mode.
pub fn Snowflake.parse(s string) !Snowflake {
	return Snowflake{
		value: s.parse_uint(10, 64)!
	}
}

pub fn (s Snowflake) str() string {
	return s.value.str()
}

// is_zero tells whether the ID is unset: Discord never gives 0, so `Snowflake{}` means none.
pub fn (s Snowflake) is_zero() bool {
	return s.value == 0
}

// unix_ms returns the creation time encoded in the ID, in milliseconds since the Unix epoch.
pub fn (s Snowflake) unix_ms() u64 {
	return (s.value >> 22) + discord_epoch
}

pub fn (s Snowflake) to_json() string {
	return '"${s.value}"'
}

pub fn (mut s Snowflake) from_json_string(raw string) ! {
	s.value = raw.parse_uint(10, 64)!
}

pub fn (mut s Snowflake) from_json_number(raw string) ! {
	s.value = raw.parse_uint(10, 64)!
}
