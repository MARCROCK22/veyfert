# Formatting text: veyfert.formatter

`veyfert.formatter` writes Discord's markdown, mentions, timestamps and links, as Seyfert's
`Formatter` does, so message text does not need hand-written escapes.

```v
import os
import time
import veyfert
import veyfert.discord
import veyfert.formatter

@[veyfert.Declare(name: 'event', description: 'Announces an event')]
struct Event {
mut:
	name  string @[veyfert.Desc: 'What']
	hours int    @[veyfert.Desc: 'In how many hours'; veyfert.Max: 72; veyfert.Min: 1]
}

fn (e Event) run(mut ctx veyfert.CommandContext) ! {
	at := time.now().add(time.Duration(e.hours) * time.hour)
	text := [
		formatter.header(e.name, 2),
		'${formatter.bold('When:')} ${formatter.timestamp(at, .full_date_short_time)} (${formatter.timestamp(at, .relative)})',
		'${formatter.bold('Host:')} ${formatter.user_mention(ctx.author().id)}',
		formatter.list(['Bring snacks', 'Be on time'], false),
		formatter.subtext('Type ${formatter.inline_code('/event')} to make your own'),
	].join('\n')
	ctx.write(content: text)!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Event{})
	app_id := discord.Snowflake.parse(os.getenv('APPLICATION_ID')) or { discord.Snowflake{} }
	println('Invite: ${formatter.oauth2_url(app_id, permissions: .send_messages | .embed_links)}')
	bot.upload_commands()!
	bot.run()!
}
```

## Markdown

| Function | Writes |
|---|---|
| `bold(t)`, `italic(t)`, `underline(t)`, `strikethrough(t)`, `spoiler(t)` | `**t**`, `*t*`, `__t__`, `~~t~~`, `\|\|t\|\|` |
| `inline_code(t)` | `` `t` `` |
| `code_block(code, language)` | A fenced block; `''` is plain text |
| `quote(t)`, `block_quote(t)` | `> t`, and `>>> t` for the rest of the message |
| `subtext(t)` | `-# t`, small grey text |
| `header(t, level)` | `#`, `##` or `###`; levels past 3 are 3 |
| `hyperlink(text, url)` | `[text](url)` |
| `list(items, ordered)` | `- a` lines, or `1. a` lines |

## Mentions

| Function | Writes |
|---|---|
| `user_mention(id)`, `role_mention(id)`, `channel_mention(id)` | `<@id>`, `<@&id>`, `<#id>` |
| `command_mention('config mod warn', command_id)` | `</config mod warn:id>`, a clickable command |
| `emoji_mention(id, name, animated)` | `<:name:id>` or `<a:name:id>` |
| `guild_navigation('browse')` | `<id:browse>`: `customize`, `browse`, `guide`, `linked-roles` |

The models have the same as methods: `user.mention()`; see [models.md](models.md#helpers).

## Timestamps

`timestamp(t, style)` shows a time in each reader's own time zone and language:

| `formatter.TimestampStyle` | Looks like |
|---|---|
| `.short_time` | 16:20 |
| `.medium_time` | 16:20:30 |
| `.short_date` | 20/04/2021 |
| `.long_date` | 20 April 2021 |
| `.long_date_short_time` | 20 April 2021 16:20 |
| `.full_date_short_time` | Tuesday, 20 April 2021 16:20 |
| `.short_date_short_time` | 20/04/2021, 16:20 |
| `.short_date_medium_time` | 20/04/2021, 16:20:30 |
| `.relative` | 2 months ago |

## Links

- `channel_link(channel_id, guild_id)`: `https://discord.com/channels/guild/channel`; `none` for a
  DM.
- `message_link(guild_id, channel_id, message_id)`: the same for a message.

## OAuth2 URLs

`oauth2_url(application_id, opts)` is the link that adds the bot to a server. `formatter.OAuth2Url`
has `scopes` (`['bot', 'applications.commands']` by default), `permissions`, and
`disable_guild_select`:

```v
url := formatter.oauth2_url(app_id,
	scopes:      ['bot']
	permissions: .administrator
)
```
