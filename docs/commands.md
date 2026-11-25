# Commands

A command is a struct. Its attributes declare it, its fields with `@[Desc]` are its options, and
its `run` method answers it. veyfert reads all of that at compile time: options arrive typed,
unsupported option types do not compile, and Discord's other rules (name lengths, 25 options,
required options first) are checked when the command is added.

```v
import os
import time
import veyfert
import veyfert.discord

enum Unit {
	minutes @[veyfert.Label: 'Minutes']
	hours   @[veyfert.Label: 'Hours']
}

@[veyfert.BotPerms('moderate_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'timeout', description: 'Times a member out')]
@[veyfert.Perms('moderate_members')]
struct Timeout {
mut:
	member discord.Member @[veyfert.Desc: 'Who']
	amount int            @[veyfert.Desc: 'How long'; veyfert.Max: 60; veyfert.Min: 1]
	unit   ?Unit          @[veyfert.Desc: 'Minutes unless you pick hours']
	reason ?string        @[veyfert.Autocomplete; veyfert.Desc: 'Why'; veyfert.MaxLength: 200]
	// No @[Desc]: not an option. check_options fills it.
	length time.Duration
}

// check_options runs after the options are filled: it may reject them or work out more fields.
fn (mut t Timeout) check_options(mut ctx veyfert.CommandContext) ! {
	user := t.member.user or { return error('that member is gone') }
	if user.bot {
		return error('bots cannot be timed out')
	}
	per := if t.unit or { Unit.minutes } == .hours { time.hour } else { time.minute }
	t.length = time.Duration(t.amount) * per
}

fn (t Timeout) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := t.member.user or { return }
	ctx.client.members.timeout(guild_id, user.id, t.length, t.reason or { '' })!
	ctx.write(content: '${user.username} is timed out for ${t.length}', ephemeral: true)!
}

fn (t Timeout) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	reasons := ['spam', 'insults', 'off topic']
	ctx.respond(reasons.filter(it.starts_with(ctx.value)).map(veyfert.Choice{
		name:  it
		value: it
	}))!
}

// Hook methods replace the client's defaults for this command.
fn (t Timeout) on_options_error(mut ctx veyfert.CommandContext, failure IError) ! {
	ctx.write(content: failure.msg(), ephemeral: true)!
}

fn (t Timeout) on_run_error(mut ctx veyfert.CommandContext, failure IError) ! {
	ctx.write(content: 'Could not do it: ${failure.msg()}', ephemeral: true)!
}

// /tag add and /tag remove: fields marked @[Sub] are subcommands.
@[veyfert.Declare(name: 'add', description: 'Adds a tag')]
struct TagAdd {
mut:
	name string @[veyfert.Desc: 'The tag']
}

fn (t TagAdd) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Added ${t.name} with /${ctx.path}')!
}

@[veyfert.Declare(name: 'remove', description: 'Removes a tag')]
struct TagRemove {
mut:
	name string @[veyfert.Desc: 'The tag']
}

fn (t TagRemove) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Removed ${t.name}')!
}

@[veyfert.Declare(name: 'tag', description: 'Manages tags')]
struct Tag {
mut:
	add    TagAdd    @[veyfert.Sub]
	remove TagRemove @[veyfert.Sub]
}

// A context menu command: right-click a user, then Apps.
@[veyfert.UserMenu('Show avatar')]
struct ShowAvatar {}

fn (s ShowAvatar) run(mut ctx veyfert.CommandContext) ! {
	user := ctx.target_user() or { return }
	ctx.write(content: user.avatar_url(size: 256), ephemeral: true)!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Timeout{})
	bot.commands.add(Tag{})
	bot.commands.add(ShowAvatar{})
	// The default answer when a command's `run` fails, for commands without on_run_error.
	bot.commands.defaults.on_run_error = fn (mut ctx veyfert.CommandContext, failure IError) ! {
		ctx.write(content: 'Something went wrong.', ephemeral: true)!
	}
	bot.commands.observe(fn (e veyfert.CommandEvent) {
		println('/${e.path} by ${e.user_id}: ${e.outcome} in ${e.duration}')
	})
	bot.upload_commands()!
	bot.run()!
}
```

## Declaring

| Attribute | Declares |
|---|---|
| `@[veyfert.Declare(name: 'n', description: 'd')]` | A slash command, or a subcommand when it is a `@[Sub]` field |
| `@[veyfert.UserMenu('Name')]` | A user context menu command; `run` reads `ctx.target_user()` |
| `@[veyfert.MessageMenu('Name')]` | A message context menu command; `run` reads `ctx.target_message()` |
| `@[veyfert.EntryPoint(name: 'n', description: 'd')]` | The entry point of an Activity; see [Entry points](#entry-points) |

More attributes on the struct:

| Attribute | Effect |
|---|---|
| `Perms('manage_guild')` | Members without these permissions do not see the command; for prefix commands, veyfert checks them |
| `BotPerms('ban_members')` | Checked before the command runs; when the bot lacks one, `on_bot_permissions_fail` answers |
| `Nsfw` | Only in age-restricted channels |
| `Guilds('id1,id2')` | Uploaded only to these servers |
| `Contexts('guild,bot_dm,private_channel')` | Where it can be used |
| `Integrations('guild_install,user_install')` | Which installs offer it |
| `Locale('field')` | Its texts come from a `Langs[T]`; see [i18n.md](i18n.md) |
| `Aliases('a,b')` | More names for its prefix form |
| `Ignore('slash')`, `Ignore('prefix')` | Only as a prefix command, or only as a slash command |

Permission names are those of `discord.Permissions`, separated by commas. V attributes take one
value each, so a struct has one attribute per line.

## Options

A field with `@[veyfert.Desc: '...']` in a `mut:` section is an option. Its type is the option's
type, and `?T` makes it optional:

| Field type | Option |
|---|---|
| `string` | text |
| `int`, `i64` | integer |
| `f64` | number |
| `bool` | true or false |
| an enum | text with the enum's values as choices; `@[veyfert.Label: 'Shown']` on a value renames it |
| `discord.User` | a user |
| `discord.Member` | a member of this server |
| `discord.Channel` | a channel; `@[veyfert.Channels: 'guild_text,guild_voice']` limits the types |
| `discord.Role` | a role |
| `discord.Mentionable` | a user or a role |
| `discord.Attachment` | a file |

Numbers take `Min` and `Max`, text takes `MinLength` and `MaxLength`, and `Autocomplete` asks
the command for suggestions while the user types. Fields without `@[Desc]` are not options:
they are dependencies, such as a database handle, that travel with every copy of the command.

Each interaction gets a fresh copy of the struct you added, with the options filled in.

## Subcommands and groups

Fields marked `@[veyfert.Sub]` are subcommands, each a struct with `@[Declare]` and `run`. A
subcommand with `@[Sub]` fields of its own is a group: `/config mod warn`. `ctx.path` is the path
that ran, such as `'config mod warn'`. A guard on a group runs before each of its subcommands.

## Autocomplete

An option with `@[veyfert.Autocomplete]` asks `autocomplete(mut ctx veyfert.AutocompleteContext) !`
for suggestions. The context has `focused` (the option being typed), `value` (what was typed),
`options` (everything typed so far) and `path`. `ctx.respond(choices)` answers with up to 25
`veyfert.Choice{name, value}`.

Plugins can wrap every autocomplete handler with `bot.wrap_autocomplete`, for example to answer
from a cache; see [plugins.md](plugins.md#wrapping-guards-and-autocomplete).

## Checking options

`check_options(mut ctx) !` runs after the options are filled and before the guards. It may
reject them (its error goes to `on_options_error`) or fill other fields, as `Timeout` does with
`length`. It is what Seyfert does with an option's `value` callback.

## The order of a command

1. The bot's permissions (`@[BotPerms]`).
2. For prefix commands, the member's permissions (`@[Perms]`). Discord checks them for slash
   commands, after the server's own command permissions.
3. `on_before_options`, then the options, then `check_options`.
4. `on_before_guards`, then the global guards, the groups' guards and the command's own guards.
   See [guards.md](guards.md).
5. `run`, then `on_after_run(mut ctx, failure ?IError)`, with the error of `run` if there was one.

## Hooks

Hooks are optional methods of the command. Without one, `bot.commands.defaults` answers:

| Method | When | Default |
|---|---|---|
| `on_before_options(mut ctx) !` | Before the options are read | — |
| `on_options_error(mut ctx, failure IError) !` | An option was invalid, or `check_options` failed | An ephemeral error |
| `on_before_guards(mut ctx) !` | Before the guards | — |
| `on_guard_error(mut ctx, reason string) !` | A guard denied with a reason | An ephemeral error with the reason |
| `on_bot_permissions_fail(mut ctx, missing discord.Permissions) !` | The bot lacks `@[BotPerms]` | An ephemeral error listing them |
| `on_permissions_fail(mut ctx, missing discord.Permissions) !` | A prefix command's author lacks `@[Perms]` | An error listing them |
| `on_run_error(mut ctx, failure IError) !` | `run` failed | Logs it and answers that something failed |
| `on_after_run(mut ctx, failure ?IError) !` | After `run` | — |
| `on_internal_error(mut ctx, failure IError) !` | A hook itself failed | Logs it |

Hook methods take the command by value and return `!`, like `run`. The defaults are fields of
`bot.commands.defaults` that you can replace, as in the example.

## Entry points

An Activity's entry point command is declared with `@[veyfert.EntryPoint(name:, description:)]`.
Discord launches the Activity by itself; with `@[veyfert.AppHandler]` the bot answers instead, and
`ctx.launch_activity()!` launches it:

```v
@[veyfert.AppHandler]
@[veyfert.EntryPoint(name: 'play', description: 'Starts the game')]
struct Play {}

fn (p Play) run(mut ctx veyfert.CommandContext) ! {
	ctx.launch_activity()!
}
```

An application has one entry point command.

## Uploading

`bot.upload_commands(opts)!` replaces the commands Discord has with yours:

- Without options, global commands go everywhere and `@[Guilds]` commands to their servers.
- `guild_id: id` uploads every command to that server, where changes apply at once: use it while
  developing.
- `cache_path: '.veyfert/commands.json'` remembers what was uploaded and skips identical
  uploads.

The `before_upload` hooks run first, so plugins can still add commands.

## Observing commands

`bot.commands.observe(fn (e veyfert.CommandEvent))` runs after every command with its `path`,
`user_id`, `guild_id`, whether it came from a message (`prefix`), its `duration`, its `outcome`
(`ok`, `options`, `guard`, `bot_permissions` or `error`) and the `failure`.
