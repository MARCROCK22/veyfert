// Package formatter writes Discord's markdown, mentions, timestamps and links, as Seyfert's
// Formatter does: `formatter.bold('hi')`, `formatter.timestamp(t, .relative)`.
module formatter

import net.urllib
import time
import veyfert.discord

pub fn bold(text string) string {
	return '**${text}**'
}

pub fn italic(text string) string {
	return '*${text}*'
}

pub fn underline(text string) string {
	return '__${text}__'
}

pub fn strikethrough(text string) string {
	return '~~${text}~~'
}

pub fn spoiler(text string) string {
	return '||${text}||'
}

pub fn inline_code(text string) string {
	return '`${text}`'
}

// code_block fences `text` as code in `language`; Seyfert's default language is txt.
pub fn code_block(text string, language string) string {
	return '```${if language == '' { 'txt' } else { language }}\n${text}\n```'
}

pub fn quote(text string) string {
	return '> ${text}'
}

// block_quote quotes everything after it, across lines.
pub fn block_quote(text string) string {
	return '>>> ${text}'
}

// subtext is the small grey text under a message.
pub fn subtext(text string) string {
	return '-# ${text}'
}

// header is a heading of `level` 1, 2 or 3.
pub fn header(text string, level int) string {
	return '${'#'.repeat(if level < 1 {
		1
	} else if level > 3 {
		3
	} else {
		level
	})} ${text}'
}

pub fn hyperlink(text string, url string) string {
	return '[${text}](${url})'
}

// list writes items as a bulleted list, or a numbered one.
pub fn list(items []string, ordered bool) string {
	mut lines := []string{cap: items.len}
	for i, item in items {
		lines << if ordered { '${i + 1}. ${item}' } else { '- ${item}' }
	}
	return lines.join('\n')
}

// TimestampStyle is how Discord shows a timestamp, in the reader's time zone and language.
pub enum TimestampStyle {
	short_time             // t: 16:20
	medium_time            // T: 16:20:30
	short_date             // d: 20/04/2021
	long_date              // D: 20 April 2021
	long_date_short_time   // f: 20 April 2021 16:20
	full_date_short_time   // F: Tuesday, 20 April 2021 16:20
	short_date_short_time  // s: 20/04/2021, 16:20
	short_date_medium_time // S: 20/04/2021, 16:20:30
	relative               // R: 2 months ago
}

fn (s TimestampStyle) letter() string {
	return match s {
		.short_time { 't' }
		.medium_time { 'T' }
		.short_date { 'd' }
		.long_date { 'D' }
		.long_date_short_time { 'f' }
		.full_date_short_time { 'F' }
		.short_date_short_time { 's' }
		.short_date_medium_time { 'S' }
		.relative { 'R' }
	}
}

pub fn timestamp(t time.Time, style TimestampStyle) string {
	return '<t:${t.unix()}:${style.letter()}>'
}

pub fn user_mention(id discord.Snowflake) string {
	return '<@${id}>'
}

pub fn role_mention(id discord.Snowflake) string {
	return '<@&${id}>'
}

pub fn channel_mention(id discord.Snowflake) string {
	return '<#${id}>'
}

// command_mention is a clickable slash command; `name` may include subcommands.
pub fn command_mention(name string, id discord.Snowflake) string {
	return '</${name}:${id}>'
}

pub fn emoji_mention(id discord.Snowflake, name string, animated bool) string {
	return '<${if animated { 'a' } else { '' }}:${if name == '' { '_' } else { name }}:${id}>'
}

// channel_link opens a channel; `guild_id` none is a direct message.
pub fn channel_link(channel_id discord.Snowflake, guild_id ?discord.Snowflake) string {
	return 'https://discord.com/channels/${if id := guild_id { id.str() } else { '@me' }}/${channel_id}'
}

pub fn message_link(guild_id ?discord.Snowflake, channel_id discord.Snowflake, message_id discord.Snowflake) string {
	return '${channel_link(channel_id, guild_id)}/${message_id}'
}

// guild_navigation links a part of the guild: customize, browse, guide or linked-roles.
pub fn guild_navigation(kind string) string {
	return '<id:${kind}>'
}

@[params]
pub struct OAuth2Url {
pub:
	scopes               []string = ['bot', 'applications.commands']
	permissions          discord.Permissions
	disable_guild_select bool
}

// oauth2_url is the link that adds an application to a guild.
pub fn oauth2_url(application_id discord.Snowflake, opts OAuth2Url) string {
	mut query := 'client_id=${application_id}&scope=${urllib.query_escape(opts.scopes.join(' '))}&disable_guild_select=${opts.disable_guild_select}'
	if u64(opts.permissions) != 0 {
		query += '&permissions=${opts.permissions.wire()}'
	}
	return 'https://discord.com/oauth2/authorize?${query}'
}
