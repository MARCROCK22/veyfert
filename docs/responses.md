# Answering interactions

Commands, components and modals get a context whose methods answer the interaction. Discord
wants an answer within 3 seconds; after that it shows "The application did not respond".

```v
import os
import time
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'report', description: 'Builds a report')]
struct Report {}

fn (r Report) run(mut ctx veyfert.CommandContext) ! {
	// More than 3 seconds of work: defer first. The answer then has 15 minutes.
	ctx.defer_reply(false)!
	time.sleep(2 * time.second)
	ctx.edit_response(
		embeds: [
			discord.Embed{
				title:       'Weekly report'
				description: 'Everything is fine.'
				color:       discord.colors.green
				timestamp:   time.now().format_rfc3339()
				fields:      [
					discord.EmbedField{
						name:   'Messages'
						value:  '1234'
						inline: true
					},
				]
			},
		]
		files:  [
			discord.File{
				name:         'report.csv'
				data:         'day,messages\nmon,200\n'.bytes()
				content_type: 'text/csv'
			},
		]
	)!
	ctx.followup(content: 'Only you can see this.', ephemeral: true)!
}

@[veyfert.Declare(name: 'hello', description: 'Greets someone')]
struct Hello {
mut:
	who discord.User @[veyfert.Desc: 'Who']
}

fn (h Hello) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:          'Hello <@${h.who.id}>! @everyone, say hi.'
		allowed_mentions: discord.AllowedMentions{
			parse: ['users'] // ping the user, not everyone
		}
	)!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Report{})
	bot.commands.add(Hello{})
	bot.upload_commands()!
	bot.run()!
}
```

## The methods

| Method | What it does |
|---|---|
| `ctx.write(opts)!` | The answer. Once per interaction |
| `ctx.defer_reply(ephemeral)!` | "Thinking…": buys 15 minutes for `edit_response` |
| `ctx.edit_response(opts)!` | Edits the answer, or fills in a deferred one; returns the message |
| `ctx.followup(opts)!` | Another message after the answer; returns it |
| `ctx.fetch_response()!` | The answer as a message |
| `ctx.delete_response()!` | Deletes the answer |
| `ctx.edit_or_reply(opts)!` | Writes the answer, or edits it when there is one already |
| `ctx.modal(form)!` | Opens a modal as the answer; see [components.md](components.md#modals) |
| `ctx.launch_activity()!` | Launches the app's Activity as the answer |

Component handlers also have `ctx.update(opts)!`, which edits the message with the component,
and `ctx.defer_update()!`, which acknowledges the click without changing anything yet.

`write` fails with "already answered" when the interaction has an answer; use `edit_response`
or `followup` then.

## Message options

`veyfert.MessageOptions` is a `@[params]` struct, so its fields go straight into the call:

| Field | Meaning |
|---|---|
| `content` | The text, up to 2000 characters |
| `embeds` | Up to 10 `discord.Embed`; each is validated against Discord's limits before it is sent |
| `components` | Buttons, selects, or components v2; see [components.md](components.md) |
| `files` | Attachments: `discord.File{name, data, content_type}` |
| `poll` | A poll: `discord.poll('Question?', ['Yes', 'No'], 24, false)` |
| `allowed_mentions` | Who the message may ping: `parse`, `users`, `roles`, `replied_user` |
| `ephemeral` | Only the author sees it; answers and followups only |
| `tts` | Read aloud |
| `flags` | More flags, such as `discord.message_flag_suppress_embeds` |
| `reply_to` | The message this one replies to, in the same channel |

In an edit, `none` leaves a part as it is, and an empty list removes it: `components: []` takes
the buttons away.

## Files

```v
chart := discord.file_from_path('chart.png')! // the type comes from the extension
logo := discord.file_from_url('https://vlang.io/img/v-logo.png', 'logo.png')!
avatar := discord.file_from_base64('a.png', base64_text, 'image/png')! // or a data: URI
ctx.write(content: 'Files', files: [chart, logo, avatar])!
```

An embed shows an attached image with `attachment://name`:

```v
ctx.write(
	files:  [chart]
	embeds: [discord.Embed{
		image: discord.Media{
			url: 'attachment://chart.png'
		}
	}]
)!
```

## Embeds

`discord.Embed` has `title`, `description`, `url`, `timestamp` (ISO 8601, such as
`time.now().format_rfc3339()`), `color`, `footer`, `image`, `thumbnail`, `author` and `fields`.
`discord.colors` has Seyfert's color names (`discord.colors.blurple`), and `discord.parse_color`
reads `'#5865F2'` or a name. `embed.validate()!` checks Discord's limits; messages are checked
before they are sent, so a long title fails with a clear error instead of Discord's form error.

## Who and where

`ctx.author()` is the user, `ctx.member()` the member in a server, `ctx.guild_id()` and
`ctx.channel_id()` the place, and `ctx.interaction` the whole interaction. In a context menu,
`ctx.target_user()` and `ctx.target_message()` are what was clicked.

## Prefix commands and HTTP

The same methods work for [prefix commands](prefix-commands.md): the answer is a message in the
channel, `edit_response` edits it, and ephemeral answers become normal messages. For
[interactions over HTTP](http-interactions.md), the first answer goes in the HTTP response.
