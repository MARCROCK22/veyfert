# Prefix commands

The same command structs run from messages, such as `!ban @ana spamming`, when the client has
prefixes. Nothing changes in the command: options, guards, hooks and answers work as for slash
commands.

```v
import os
import veyfert
import veyfert.discord

@[veyfert.Aliases('b')]
@[veyfert.Declare(name: 'ban', description: 'Bans a member')]
@[veyfert.Perms('ban_members')]
struct Ban {
mut:
	who    discord.User @[veyfert.Desc: 'Who']
	reason ?string      @[veyfert.Desc: 'Why']
}

fn (b Ban) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Banned ${b.who.username}: ${b.reason or { 'no reason' }}')!
}

// Only as a prefix command: it is not uploaded.
@[veyfert.Declare(name: 'say', description: 'Repeats what you write')]
@[veyfert.Ignore('slash')]
struct Say {
mut:
	text string @[veyfert.Desc: 'What to say']
}

fn (s Say) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: s.text)!
}

fn main() {
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		intents:  .guilds | .guild_messages | .message_content
		prefixes: ['!', '?']
	)
	bot.commands.add(Ban{})
	bot.commands.add(Say{})
	bot.run()!
}
```

```
!ban @ana spamming links
?b 80351110224678912 -reason "too many links"
!say hello there, everyone
```

## Prefixes

- `prefixes: ['!']` in `ClientOptions` sets fixed prefixes.
- `bot.commands.prefix = fn (msg discord.Message) []string` decides per message, for example per
  server from your database.
- Mentioning the bot always works as a prefix: `@bot ban @ana`. Those messages carry their
  content without the `message_content` intent; other guild messages need it, and it is
  privileged.

Messages from bots and webhooks are ignored. Names and aliases are not case sensitive, and the
longest matching prefix wins.

## Arguments

- Options come in the command's order: `!ban @ana spamming`.
- Or by name, with `-name value`: `!ban @ana -reason spamming`.
- `"quoted text"` is one argument.
- The last text option takes the rest of the line, so `!say hello there` needs no quotes.
- Users, members, roles and channels can be mentions or IDs; attachment options take the
  message's attachments in order.
- Subcommands are words: `!config mod warn @ana`.

A missing or invalid option goes to `on_options_error`, as for slash commands.

## Answers

`ctx.write` sends a message in the channel that replies to the command's message.
`edit_response` edits it, `delete_response` deletes it, and `followup` sends another message.
`defer_reply` shows "typing…", and the first `edit_response` then sends the answer. Ephemeral
answers are normal messages, since a message cannot be ephemeral. `ctx.message` is the message
that ran the command; it is `none` for slash commands.

## Permissions

For slash commands, Discord checks `@[Perms]`. For prefix commands nobody else does, so veyfert
checks the author's permissions, and the command's `on_permissions_fail(mut ctx, missing) !` (or
`bot.commands.defaults.on_permissions_fail`) answers when some are missing. `@[Guilds]` and
`@[Contexts]` apply too.

## Slash only, prefix only

`@[veyfert.Ignore('prefix')]` keeps a command out of messages, and `@[veyfert.Ignore('slash')]`
keeps it from being uploaded. `@[veyfert.Aliases('b,bn')]` adds names for the prefix form.

## Your own argument parser

`bot.commands.args_parser` replaces how arguments become options. It gets the arguments after
the command's name and subcommands, split as a shell would, the options to fill (`name`, `kind`,
`required`) and the message, and returns values by option name, as a user would type them:

```v
// `!remind time=10m text=stretch` instead of positions.
bot.commands.args_parser = fn (args []string, options []veyfert.PrefixOption, msg discord.Message) map[string]string {
	mut out := map[string]string{}
	for arg in args {
		if arg.contains('=') {
			out[arg.all_before('=')] = arg.all_after('=')
		}
	}
	return out
}
```

veyfert then converts and checks the values: mentions and IDs, numbers, enums and limits.
