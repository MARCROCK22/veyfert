# Components and modals

Components are the buttons, selects and layout blocks of a message; modals are forms that pop
up. `veyfert.discord` builds them, handlers are structs routed by `custom_id`, and a modal is a
struct whose fields are its inputs.

```v
import os
import time
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'vote', description: 'Starts a vote')]
struct StartVote {}

fn (c StartVote) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    'Pizza or tacos?'
		components: [
			discord.action_row(discord.button(style: .primary, label: 'Pizza', custom_id: 'vote:pizza'),
				discord.button(style: .success, label: 'Tacos', custom_id: 'vote:tacos')),
			discord.action_row(discord.string_select(
				custom_id:   'vote:menu'
				placeholder: 'Or something else'
				options:     [discord.SelectOption{
					label: 'Sushi'
					value: 'sushi'
				}, discord.SelectOption{
					label: 'Salad'
					value: 'salad'
				}]
			)),
		]
	)!
}

// Vote gets every custom_id that starts with 'vote:'.
@[veyfert.CustomIdPrefix('vote:')]
struct Vote {}

fn (h Vote) run(mut ctx veyfert.ComponentContext) ! {
	choice := if ctx.values.len > 0 { ctx.values[0] } else { ctx.custom_id.all_after(':') }
	ctx.update(content: '${ctx.author().username} voted ${choice}', components: [])!
}

enum Mood {
	happy @[veyfert.Label: 'Happy']
	tired @[veyfert.Label: 'Tired']
}

// Feedback is a modal: fields with a Label are its inputs.
@[veyfert.Modal(custom_id: 'feedback', title: 'Your feedback')]
struct Feedback {
mut:
	text  string  @[veyfert.Label: 'Tell us'; veyfert.MaxLength: 500; veyfert.Paragraph]
	email ?string @[veyfert.Desc: 'In case you want an answer'; veyfert.Label: 'Email']
	mood  ?Mood   @[veyfert.Label: 'How are you?']
}

fn (f Feedback) submit(mut ctx veyfert.ModalContext) ! {
	ctx.write(content: 'Thanks: "${f.text}" (${f.mood or { Mood.happy }})', ephemeral: true)!
}

@[veyfert.Declare(name: 'feedback', description: 'Opens a form')]
struct AskFeedback {}

fn (c AskFeedback) run(mut ctx veyfert.CommandContext) ! {
	ctx.modal(Feedback{})!
}

@[veyfert.Declare(name: 'confirm', description: 'Asks before doing it')]
struct Confirm {}

fn (c Confirm) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    'Are you sure?'
		components: [
			discord.action_row(discord.button(style: .danger, label: 'Yes', custom_id: 'confirm:yes'),
				discord.button(label: 'No', custom_id: 'confirm:no')),
		]
	)!
	// The click goes to this command, not to the handlers.
	mut click := ctx.wait_for_component(timeout: 30 * time.second) or {
		ctx.edit_response(content: 'Time is up.', components: [])!
		return
	}
	click.update(content: if click.custom_id == 'confirm:yes' { 'Done.' } else { 'Cancelled.' }, components: [])!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(StartVote{})
	bot.commands.add(AskFeedback{})
	bot.commands.add(Confirm{})
	bot.components.add(Vote{})
	bot.modals.add(Feedback{})
	bot.upload_commands()!
	bot.run()!
}
```

## Building components

`veyfert.discord` has a constructor per component:

| Constructor | Component |
|---|---|
| `action_row(components...)` | A row of up to 5 buttons, or one select |
| `button(style:, label:, custom_id:, url:, emoji:, disabled:)` | A button; with `url` it is a link button |
| `string_select(custom_id:, options:, placeholder:, min_values:, max_values:)` | A select of your options |
| `user_select`, `role_select`, `mentionable_select`, `channel_select` | Selects that Discord fills; `default_values` preselects, `channel_types` filters |
| `text_input(custom_id:, style:, placeholder:, value:, min_length:, max_length:)` | A text field, inside a modal `label` |

Components v2 lay out a whole message. veyfert sets the IS_COMPONENTS_V2 flag when it sees one:

```v
ctx.write(
	components: [
		discord.container([
			discord.section(['## veyfert', 'Components v2 from V structs'], discord.thumbnail('https://vlang.io/img/v-logo.png')),
			discord.separator(),
			discord.text_display('A message made of blocks.'),
			discord.media_gallery(discord.MediaItem{
				media: discord.Media{
					url: 'attachment://chart.png'
				}
			}),
			discord.action_row(discord.button(label: 'V', url: 'https://vlang.io')),
		], accent_color: 0x5865F2),
	]
)!
```

`text_display`, `section`, `thumbnail`, `media_gallery`, `file_component`, `separator` and
`container` are the v2 blocks. Modals add `label`, `file_upload`, `radio_group`,
`checkbox_group` and `checkbox`.

## Handlers

A handler is a struct with a route and `run(mut ctx veyfert.ComponentContext) !`, added with
`bot.components.add(Handler{})`:

| Route | Matches |
|---|---|
| `@[veyfert.CustomId('id')]` | That custom_id |
| `@[veyfert.CustomIdPrefix('vote:')]` | Every custom_id that starts with it |
| `@[veyfert.CustomIdRegex('^page:[0-9]+$')]` | Every custom_id the expression finds (V's `regex` syntax) |

Exact IDs win, then prefixes (the longest first), then expressions in the order they were added.
A handler's `filter(mut ctx veyfert.ComponentContext) bool` method may pass on an interaction,
and the next match is tried:

```v
@[veyfert.CustomIdPrefix('admin:')]
struct AdminButtons {}

fn (h AdminButtons) filter(mut ctx veyfert.ComponentContext) bool {
	return ctx.author().id == discord.Snowflake{80351110224678912}
}

fn (h AdminButtons) run(mut ctx veyfert.ComponentContext) ! {
	ctx.update(content: 'Admin pressed ${ctx.custom_id}')!
}
```

`ctx.custom_id` is the whole ID, so data can travel in it: `'vote:42'`. `ctx.values` has what a
select picked: option values, or user, role or channel IDs. `ctx.update(opts)!` edits the
message as the answer, and `ctx.defer_update()!` acknowledges the click; the other answers of
[responses.md](responses.md) work too.

Like a command's, a handler's fields travel with every copy, and fields whose type is a
`HandlerGuard` are guards (see [guards.md](guards.md#guards-for-components-and-modals)).
Handlers have `on_before_guards`, `on_guard_error`, `on_run_error`, `on_after_run` and
`on_internal_error` hooks.

## Modals

A modal is a struct with `@[veyfert.Modal(custom_id: 'id', title: 'Title')]`. Its fields with
`@[veyfert.Label: '...']` are inputs: `string` (required) or `?string`, or an enum (a select),
with `Paragraph`, `Placeholder: 'hint'`, `MinLength`, `MaxLength` and `Desc`.

- `ctx.modal(Feedback{})!` opens it as the answer to a command or a component, prefilled with the
  fields' values.
- `bot.modals.add(Feedback{})` routes its submissions to `submit(mut ctx veyfert.ModalContext) !`,
  with the fields filled.
- `ctx.modal(Feedback{}, custom_id: 'feedback:42')!` opens it with another ID, carrying data.
  Add `@[veyfert.CustomIdRegex('^feedback:')]` to the modal type to route those, and read
  `ctx.custom_id` in `submit`.

## Waiting inside a command

- `ctx.wait_for_component(timeout:, message_id:, custom_id:, anyone:)` waits for the next click
  on the answer's components, by the author unless `anyone`, and returns its context, or `none`.
- `ctx.wait_for_modal(Form{}, timeout)` opens the form's modal as the answer, waits for the
  author to send it, and returns the filled form and the context to answer the submission, or
  `none`.

```v
form, mut submitted := ctx.wait_for_modal(Feedback{}, 2 * time.minute) or { return }
submitted.write(content: 'Got: ${form.text}', ephemeral: true)!
```

Interactions taken this way skip the handlers.

## Collecting clicks

`ctx.collect_components(each, opts)` runs `each` for every click on the answer's components until
the collection ends, and returns why (`.timeout`, `.idle`, `.max` or `.stopped`):

```v
mut page := 0
why := ctx.collect_components(fn [mut page] (mut c veyfert.ComponentContext) ! {
	if c.custom_id == 'page:stop' {
		c.update(components: [])!
		return veyfert.stop()
	}
	page++
	c.update(content: 'Page ${page}')!
}, idle: time.minute, max: 20)
```

`veyfert.CollectComponents` has `timeout` (1 minute), `idle`, `max`, `message_id`, `custom_id`
and `anyone`.

## Polls

```v
ctx.write(poll: discord.poll('Pizza or tacos?', ['Pizza', 'Tacos'], 24, false))!
```

The arguments are the question, the answers, how many hours it lasts, and whether people may
pick more than one. Votes arrive as `discord.MessagePollVoteAdd` and `MessagePollVoteRemove`
events, with the `guild_message_polls` intent.
