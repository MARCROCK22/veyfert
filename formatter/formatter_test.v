module formatter

import time
import veyfert.discord

fn test_markdown() {
	assert bold('a') == '**a**'
	assert italic('a') == '*a*'
	assert underline('a') == '__a__'
	assert strikethrough('a') == '~~a~~'
	assert spoiler('a') == '||a||'
	assert inline_code('a') == '`a`'
	assert code_block('x := 1', 'v') == '```v\nx := 1\n```'
	assert code_block('plain', '') == '```txt\nplain\n```'
	assert quote('a') == '> a'
	assert block_quote('a') == '>>> a'
	assert subtext('a') == '-# a'
	assert header('Title', 2) == '## Title'
	assert header('Big', 9) == '### Big'
	assert hyperlink('V', 'https://vlang.io') == '[V](https://vlang.io)'
	assert list(['a', 'b'], false) == '- a\n- b'
	assert list(['a', 'b'], true) == '1. a\n2. b'
}

fn test_mentions_timestamps_and_links() {
	id := discord.Snowflake{42}
	assert user_mention(id) == '<@42>'
	assert role_mention(id) == '<@&42>'
	assert channel_mention(id) == '<#42>'
	assert command_mention('config mod warn', id) == '</config mod warn:42>'
	assert emoji_mention(id, 'wave', true) == '<a:wave:42>'
	assert emoji_mention(id, '', false) == '<:_:42>'
	t := time.unix(1700000000)
	assert timestamp(t, .relative) == '<t:1700000000:R>'
	assert timestamp(t, .short_date_medium_time) == '<t:1700000000:S>'
	assert channel_link(discord.Snowflake{40}, discord.Snowflake{30}) == 'https://discord.com/channels/30/40'
	assert message_link(none, discord.Snowflake{40}, discord.Snowflake{5}) == 'https://discord.com/channels/@me/40/5'
	assert guild_navigation('browse') == '<id:browse>'
}

fn test_oauth2_urls() {
	assert oauth2_url(discord.Snowflake{99}) == 'https://discord.com/oauth2/authorize?client_id=99&scope=bot+applications.commands&disable_guild_select=false'
	assert oauth2_url(discord.Snowflake{99},
		scopes:               ['bot']
		permissions:          .administrator
		disable_guild_select: true
	) == 'https://discord.com/oauth2/authorize?client_id=99&scope=bot&disable_guild_select=true&permissions=8'
}
