module discord

import json2

fn test_snowflakes_read_strings_and_numbers_and_write_strings() ! {
	a := json2.decode[Snowflake]('"175928847299117063"')!
	b := json2.decode[Snowflake]('175928847299117063')!
	assert a == b
	assert a.value == u64(175928847299117063)
	assert json2.encode(a) == '"175928847299117063"'
	assert Snowflake.parse('175928847299117063')! == a
	// The example from Discord's documentation: 2016-04-30 11:18:25.796 UTC.
	assert a.unix_ms() == u64(1462015105796)
}

fn test_intents_match_the_discord_bit_values() {
	assert int(Intents.guilds | .guild_messages | .message_content) == 33281
	assert int(Intents.auto_moderation_configuration) == 1 << 20
	assert int(Intents.guild_message_polls) == 1 << 24
	assert int(Intents.direct_message_polls) == 1 << 25
}
