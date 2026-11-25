# Guards

A guard decides whether a command runs: Seyfert's middlewares. It is a field of the command
whose type has `check(mut ctx veyfert.CommandContext) !`. It runs before `run`, and `run` sees
the state it leaves.

```v
import os
import time
import veyfert
import veyfert.discord

// OwnerOnly lets one user through.
struct OwnerOnly {
	owner discord.Snowflake
}

fn (mut g OwnerOnly) check(mut ctx veyfert.CommandContext) ! {
	if ctx.author().id != g.owner {
		return veyfert.deny('Only the owner can do that.')
	}
}

// Quota leaves what it found for `run`.
struct Quota {
mut:
	left int
}

fn (mut q Quota) check(mut ctx veyfert.CommandContext) ! {
	q.left = 2 // look it up in a database
	if q.left == 0 {
		return veyfert.stop() // ends the command without a word
	}
}

@[veyfert.Declare(name: 'deploy', description: 'Deploys the site')]
struct Deploy {
mut:
	cd    veyfert.Cooldown           = veyfert.cooldown(2, time.minute)
	perms veyfert.RequirePermissions = veyfert.require_permissions(.manage_guild)
	quota Quota
}

fn (d Deploy) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Deploying. ${d.quota.left} deploys left today, ${d.cd.remaining} this minute.')!
}

fn (d Deploy) on_guard_error(mut ctx veyfert.CommandContext, reason string) ! {
	ctx.write(content: 'No: ${reason}', ephemeral: true)!
}

// StaffOnly guards components and modals.
struct StaffOnly {
	role discord.Snowflake
}

fn (mut g StaffOnly) check_handler(mut ctx veyfert.InteractionContext) ! {
	member := ctx.member() or { return veyfert.deny('Only in servers.') }
	if g.role !in member.roles {
		return veyfert.deny('Staff only.')
	}
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	owner := discord.Snowflake.parse(os.getenv('OWNER_ID')) or { discord.Snowflake{} }
	// A global guard runs before every command.
	bot.commands.use(OwnerOnly{owner})
	bot.components.use(StaffOnly{discord.Snowflake{1234}})
	bot.commands.add(Deploy{})
	bot.upload_commands()!
	bot.run()!
}
```

## Writing a guard

A guard is any type with `check(mut ctx veyfert.CommandContext) !`:

- Return nothing to let the command go on.
- `return veyfert.deny('reason')` stops it and tells the user: the command's
  `on_guard_error(mut ctx, reason string) !` answers, or the client's default, an ephemeral
  message with the reason.
- `return veyfert.stop()` stops it silently.
- Any other error stops it as a failure of the command: `on_run_error` gets it.

A guard may keep state for `run` in its fields, as `Quota` does: each interaction gets a fresh
copy of the command, so its guards' state is its own. State that must outlive one interaction
lives behind a reference, as `Cooldown` keeps its uses.

## Where guards go

- A field of the command: it runs before `run`.
- A field of a group: it runs before each subcommand of the group.
- `bot.commands.use(guard)`: before every command, ahead of the others.

The order is: the bot's permissions, the options, the global guards, the groups' guards from the
outermost in, then the command's own, in field order. The first one that stops wins.

## Built-in guards

| Guard | What it checks |
|---|---|
| `veyfert.cooldown(uses, per)` | Each user runs the command `uses` times per `per`; `remaining` says how many are left |
| `veyfert.require_permissions(perms)` | The member has these permissions in the channel (administrators pass); in DMs it denies |

`discord.Permissions` is a flag enum: `.manage_guild | .kick_members`.

## Guards for components and modals

Component and modal handlers have guards too: a field whose type has
`check_handler(mut ctx veyfert.InteractionContext) !`, as `StaffOnly`. `bot.components.use(g)`
and `bot.modals.use(g)` add one to every handler. Handlers have `on_before_guards`,
`on_guard_error`, `on_after_run` and `on_internal_error` hooks, as commands do.

## Wrapping guards

`bot.wrap_guards(fn (mut ctx veyfert.InteractionContext, guard string, next fn () !) !)` runs
around every guard, of commands, components and modals, with the guard's type name. It calls
`next` to run the guard, or returns without calling it to let the interaction pass, and may time
the guard or change its error. Plugins use it for tracing; see
[plugins.md](plugins.md#wrapping-guards-and-autocomplete).

```v
bot.wrap_guards(fn (mut ctx veyfert.InteractionContext, guard string, next fn () !) ! {
	started := time.now()
	defer {
		println('${guard} took ${time.since(started)}')
	}
	next()!
})
```
