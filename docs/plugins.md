# Plugins

A plugin packages a feature for any bot: a struct with `name()`, `setup(mut c) !` and
`teardown(mut c) !`. In `setup` it uses the client's public API, as a bot does, and veyfert keeps
track of what it registered, so tearing it down takes all of it back.

```v
import os
import sync
import time
import veyfert
import veyfert.plugins

// Counter is what Stats shares with other plugins and with the bot.
@[heap]
struct Counter {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	total int
}

fn (mut k Counter) add() {
	k.mu.lock()
	k.total++
	k.mu.unlock()
}

fn (mut k Counter) value() int {
	k.mu.lock()
	defer {
		k.mu.unlock()
	}
	return k.total
}

pub const counter = veyfert.SharedKey[&Counter]{'stats.counter'}

// Stats counts commands. It imports the scheduler, so installing Stats installs it first.
struct Stats {
mut:
	jobs &plugins.Scheduler = unsafe { nil }
}

fn (s &Stats) name() string {
	return 'stats'
}

fn (s &Stats) info() veyfert.PluginInfo {
	return veyfert.PluginInfo{
		version:  '1.0.0'
		imports:  [veyfert.Plugin(s.jobs)]
		// A version range, such as '^1.2.0', also checks the version the plugin declares; the
		// scheduler declares none.
		requires: [veyfert.Requirement{
			plugin: 'scheduler'
		}]
	}
}

fn (mut s Stats) setup(mut c veyfert.Client) ! {
	mut count := &Counter{}
	counter.set(mut c, count, fn (k &Counter) ! {
		mut kc := k
		println('stats: ${kc.value()} commands in this run')
	})!
	c.commands.observe(fn [mut count] (e veyfert.CommandEvent) {
		count.add()
	})
	c.hook(.client_close, fn (mut c veyfert.Client) ! {
		c.logger.info('stats: the bot is closing')
	})
}

fn (mut s Stats) teardown(mut _ veyfert.Client) ! {}

fn main() {
	mut jobs := &plugins.Scheduler{}
	jobs.every(time.hour, fn (mut c veyfert.Client) ! {
		mut k := counter.get(c) or { return }
		c.logger.info('${k.value()} commands so far')
	})
	mut stats := &Stats{
		jobs: jobs
	}
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.install(mut stats)! // installs the scheduler, then stats
	bot.run()!
}
```

## Installing

`bot.install(mut p)!` sets a plugin up at once; install plugins before `run`. They are set up in
the order they are installed, and torn down in reverse when `run` returns.

Names are unique: installing a second plugin with a name that is taken fails. Plugins are
installed by the bot or through imports, never from another plugin's `setup`.

## Declaring a plugin

A plugin may have an `info() veyfert.PluginInfo` method:

| Field | Meaning |
|---|---|
| `version` | Its semver version, which other plugins' requirements check |
| `imports` | Plugins it needs, installed before it unless one with that name already is; an import cycle fails |
| `requires` | `veyfert.Requirement{plugin, version, optional}`: a plugin that must be installed before it, with a semver range such as `^1.2.0`, `~1.2.0` or `>=2.0.0` |
| `intents` | Gateway intents it needs, added to the client's |

A requirement that is missing, or whose version is out of range, fails the install; an
`optional` one logs a warning instead.

## What a plugin registers

What a plugin registers in `setup` is its own: listeners (`on`, `on_raw`), interceptors, REST and
command observers, commands, components, modals, guards, hooks, wrappers and shared values. The
client takes all of it back when the plugin is torn down, and at once when its setup fails, so a
failed plugin leaves nothing behind. When one `install` set up imports for a plugin whose setup
then failed, those imports are torn down too. What a plugin assigns directly, such as
`c.commands.defaults` or `c.commands.prefix`, stays.

## Hooks

`c.hook(moment, fn (mut c veyfert.Client) !)` runs code at a moment of the client's life:

| `veyfert.Hook` | When |
|---|---|
| `.plugins_ready` | `run` starts, with every plugin installed, before the shards connect |
| `.before_upload` | `upload_commands` is about to send the commands; a hook may still add some |
| `.client_close` | `run` is returning: the shards are closed and the queued events handled |

Hooks run in the order they were registered. One that fails is logged with its plugin's name,
and the others still run. The bot can register hooks too.

## Shared values

`veyfert.SharedKey[T]{name}` names a value that plugins share, typed:

```v
pub const db = veyfert.SharedKey[&Database]{'db'}

// In the plugin that owns it:
db.set(mut c, &Database{...}, fn (d &Database) ! {
	d.close()!
})!

// Anywhere, with the client:
mut database := db.get(c) or { return error('the db plugin is not installed') }
```

- `set(mut c, value, dispose)!` shares the value until the plugin whose setup set it is torn down;
  then `dispose`, when given, gets it. Setting a key that is taken fails.
- `get(c)` returns it, or `none`. Reading a key as another type than it was set with panics: it is
  a bug.
- Share a reference (`&T`) for a value with state; a plain struct is copied on every `get`.

## Wrapping guards and autocomplete

- `c.wrap_guards(fn (mut ctx veyfert.InteractionContext, guard string, next fn () !) !)` runs
  around every guard of commands, components and modals, with the guard's type name. It calls
  `next()!` to run the guard, or returns without it to let the interaction pass, and may change the
  error. The first added is the outermost.
- `c.wrap_autocomplete(fn (mut ctx veyfert.AutocompleteContext, next fn () !) !)` runs around
  every autocomplete handler. It may answer by itself, for example from a cache, instead of calling
  `next`.

```v
c.wrap_guards(fn (mut ctx veyfert.InteractionContext, guard string, next fn () !) ! {
	started := time.now()
	next() or {
		println('${guard} stopped ${ctx.author().username} after ${time.since(started)}')
		return err
	}
})
```

## Interceptors and observers

| Method | Sees |
|---|---|
| `c.intercept(fn (name, raw) ?string)` | Every incoming dispatch: change it or drop it |
| `c.intercept_send(fn (shard, payload) ?string)` | Every payload a shard sends: change it or drop it |
| `c.commands.observe(fn (veyfert.CommandEvent))` | Every command, after it ran |
| `c.rest.observe(fn (rest.RestEvent))` | Every REST attempt |

## Errors

- `veyfert.PluginError` is one plugin's failure, with `plugin`, `phase` (install, imports,
  requires, setup, teardown, or the disposal of a shared value) and `cause`:
  `veyfert: plugin `stats` failed during setup: no database`.
- `veyfert.PluginErrors` gathers several: the teardowns when `run` returns, or a failed setup
  together with the teardown of its imports.

`run` returns the teardown failures, after the shards have closed.

## Official plugins

`veyfert.plugins` has the official ones. `plugins.Scheduler` runs functions on an interval while
the client runs:

```v
mut jobs := &plugins.Scheduler{}
jobs.every(10 * time.minute, fn (mut c veyfert.Client) ! {
	c.set_presence(discord.Presence{
		activities: [discord.Activity{
			name: '${c.cache.guilds().len} servers'
			kind: .watching
		}]
	})!
})
bot.install(mut jobs)!
```

Register its jobs before installing it: its `setup` starts the jobs it has. The cooldown, which
Seyfert has as a plugin, is a guard in veyfert: `veyfert.cooldown`.
