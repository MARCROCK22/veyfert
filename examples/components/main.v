module main

import os
import time
import veyfert
import veyfert.discord

// Components, modals and polls. Build it like examples/basic:
//   v -path "@vlib|@vmodules|<parent of veyfert>" run examples/components
// Uploading to GUILD_ID replaces the commands of the other example in that server.

@[veyfert.Declare(name: 'buttons', description: 'Buttons and a select menu')]
struct Buttons {}

fn (c Buttons) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    'What do you pick?'
		components: [
			discord.action_row(discord.button(style: .success, label: 'One', custom_id: 'vote:one'),
				discord.button(style: .primary, label: 'Two', custom_id: 'vote:two')),
			discord.action_row(discord.string_select(
				custom_id:   'vote:menu'
				placeholder: 'Or pick here'
				options:     [discord.SelectOption{
					label: 'Three'
					value: 'three'
				}, discord.SelectOption{
					label: 'Four'
					value: 'four'
				}]
			)),
		]
	)!
}

// Vote handles every custom_id that starts with 'vote:'.
@[veyfert.CustomIdPrefix('vote:')]
struct Vote {}

fn (h Vote) run(mut ctx veyfert.ComponentContext) ! {
	choice := if ctx.values.len > 0 { ctx.values[0] } else { ctx.custom_id.all_after(':') }
	ctx.update(content: '${ctx.author().username} picked ${choice}', components: [])!
}

@[veyfert.Declare(name: 'confirm', description: 'Waits for your click inside the command')]
struct Confirm {}

fn (c Confirm) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    'Are you sure?'
		components: [
			discord.action_row(discord.button(
				style:     .danger
				label:     'Yes'
				custom_id: 'confirm:yes'
			),
				discord.button(label: 'No', custom_id: 'confirm:no')),
		]
	)!
	mut click := ctx.wait_for_component(timeout: 30 * time.second) or {
		ctx.edit_response(content: 'Time is up.', components: [])!
		return
	}
	click.update(
		content:    if click.custom_id == 'confirm:yes' { 'Done.' } else { 'Cancelled.' }
		components: []
	)!
}

@[veyfert.Declare(name: 'card', description: 'A message made of components v2')]
struct Card {}

fn (c Card) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		components: [
			discord.container([
				discord.section(['## veyfert', 'Components v2 from V structs'], discord.thumbnail('https://vlang.io/img/v-logo.png')),
				discord.separator(),
				discord.text_display('The IS_COMPONENTS_V2 flag is set for you.'),
				discord.action_row(discord.button(label: 'V', url: 'https://vlang.io')),
			], accent_color: 0x5865F2),
		]
	)!
}

enum Mood {
	happy  @[veyfert.Label: 'Happy']
	tired  @[veyfert.Label: 'Tired']
}

// Feedback is a modal: its fields with a Label are its inputs, and they arrive filled in `submit`.
@[veyfert.Modal(custom_id: 'feedback', title: 'Your feedback')]
struct Feedback {
mut:
	text  string  @[veyfert.Label: 'Tell us'; veyfert.MaxLength: 500; veyfert.Paragraph]
	email ?string @[veyfert.Desc: 'In case you want an answer'; veyfert.Label: 'Email']
	mood  ?Mood   @[veyfert.Label: 'How are you?']
}

fn (f Feedback) submit(mut ctx veyfert.ModalContext) ! {
	ctx.write(
		content:   'Thanks: "${f.text}" (${f.mood or { Mood.happy }}, ${f.email or { 'no email' }})'
		ephemeral: true
	)!
}

@[veyfert.Declare(name: 'feedback', description: 'Opens a modal')]
struct AskFeedback {}

fn (c AskFeedback) run(mut ctx veyfert.CommandContext) ! {
	ctx.modal(Feedback{})!
}

@[veyfert.Declare(name: 'poll', description: 'Creates a one-hour poll')]
struct CreatePoll {
mut:
	question string @[veyfert.Desc: 'The question'; veyfert.MaxLength: 300]
	answers  string @[veyfert.Desc: 'The answers, separated by commas']
}

fn (c CreatePoll) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		poll: discord.poll(c.question, c.answers.split(',').map(it.trim_space()), 1, false)
	)!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Buttons{})
	bot.commands.add(Confirm{})
	bot.commands.add(Card{})
	bot.commands.add(AskFeedback{})
	bot.commands.add(CreatePoll{})
	bot.components.add(Vote{})
	bot.modals.add(Feedback{})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/components.json'
	)!
	bot.run()!
}
