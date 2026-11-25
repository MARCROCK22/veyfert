# The client

`veyfert.Client` owns everything a bot runs: the gateway connections, the REST client, the cache,
the commands, the handlers and the listeners. `veyfert.new_client(opts)` makes one, and
`run()` connects it.

```v
import os
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'shutdown', description: 'Stops the bot')]
@[veyfert.Perms('administrator')]
struct Shutdown {}

fn (s Shutdown) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Bye!', ephemeral: true)!
	ctx.client.stop() // `run` returns once every shard has closed
}

fn main() {
	mut bot := veyfert.new_client(
		token:               os.getenv('DISCORD_TOKEN')
		intents:             .guilds | .guild_messages | .guild_members
		workers:             2
		interaction_workers: 4
		presence:            discord.Presence{
			status:     .idle
			activities: [discord.Activity{
				name: 'the logs'
				kind: .watching
			}]
		}
	)
	bot.logger.set_level(.debug)
	bot.commands.add(Shutdown{})
	bot.upload_commands()!
	bot.run()!
	println('the bot stopped')
}
```

## Options

`ClientOptions` is a `@[params]` struct, so its fields go straight into `new_client`:

| Option | Default | What it does |
|---|---|---|
| `token` | required | The bot token. Spaces around it are trimmed |
| `intents` | `.guilds` | The gateway events Discord sends; see [Intents](#intents) |
| `shards` | Discord's recommendation | A `ShardRange` to run part of a sharded bot; see [gateway.md](gateway.md#shards) |
| `workers` | 4 | Threads that run listeners; 1 runs them in order |
| `interaction_workers` | 4 | Threads that run commands and handlers, apart from listeners so Discord's 3 seconds hold |
| `presence` | none | The presence every shard sends when it identifies |
| `compress` | false | Discord compresses large payloads with zlib |
| `zstd` | false | Compresses the whole connection with zstd-stream; build with `-d veyfert_zstd` |
| `gateway_url` | Discord's | Another gateway URL, for a proxy or tests |
| `cache` | everything | `cache.Options`: what the cache keeps, and an adapter; see [cache.md](cache.md) |
| `prefixes` | none | Run commands from messages that start with these; see [prefix-commands.md](prefix-commands.md) |
| `max_message_bytes` | 8 MiB | The largest gateway message accepted |
| `sessions` | none | Sessions saved by a previous run, to resume; see [gateway.md](gateway.md#saving-sessions) |
| `resharding` | every 8 h, at 80% | Follows Discord's recommended shard count; see [resharding.md](resharding.md) |

## Intents

`discord.Intents` is a flag enum: combine values with `|`. Without an intent, Discord does not
send its events, and the cache cannot keep what they carry.

```v
intents: .guilds | .guild_members | .guild_messages | .message_content
```

| Intent | Events |
|---|---|
| `guilds` | Guilds, channels, threads, roles, stage instances |
| `guild_members` (privileged) | Members joining, leaving and changing; member lists |
| `guild_moderation` | Bans and audit log entries |
| `guild_expressions` | Emojis, stickers and soundboard sounds |
| `guild_integrations`, `guild_webhooks`, `guild_invites` | Their events |
| `guild_voice_states` | Voice states |
| `guild_presences` (privileged) | Presences |
| `guild_messages`, `direct_messages` | Messages in servers and in DMs |
| `guild_message_reactions`, `direct_message_reactions` | Reactions |
| `guild_message_typing`, `direct_message_typing` | Typing |
| `message_content` (privileged) | The content of messages that do not mention the bot |
| `guild_scheduled_events` | Scheduled events |
| `auto_moderation_configuration`, `auto_moderation_execution` | Auto moderation |
| `guild_message_polls`, `direct_message_polls` | Poll votes |

Privileged intents must also be enabled in the Developer Portal; otherwise Discord closes the
connection with 4014 and `run` returns the error. Plugins can add the intents they need (see
[plugins.md](plugins.md#declaring-a-plugin)).

## Threads

Listeners run on a pool of `workers` threads, and commands, components, modals and prefix
commands on a pool of `interaction_workers`. A slow listener cannot make a command miss its
3-second deadline. Listeners may block, and state that several of them share needs `shared` or
`sync`:

```v
import sync

struct Counter {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	count int
}
```

`workers: 1` runs listeners one at a time, in the order events arrive.

## Running and stopping

`run()` blocks until the bot stops:

1. It asks Discord for the gateway URL and the recommended shard count, unless `gateway_url` and
   `shards` say them.
2. It runs the `plugins_ready` hooks, starts the thread pools and connects every shard.
3. When `stop()` is called, or every shard stops, it waits for the events already queued, runs
   the `client_close` hooks and tears the plugins down.

It returns an error when Discord rejects a shard for good: a bad token (4004), an invalid shard
(4010), sharding required (4011), an invalid API version (4012), invalid intents (4013) or
disallowed intents (4014). Other closes are resumed or identified again. It also returns the
failures of plugin teardowns.

`stop()` is safe from any thread, a command included. `run()` may be called again afterwards.

## Logs

`bot.logger` is a `log.ThreadSafeLog` that writes every line as it happens. Change its level with
`bot.logger.set_level(.debug)`, or silence it in tests with `.disabled`. veyfert logs connections,
resumes, plugin installs and the errors that listeners and handlers return.

## Who the bot is

- `bot.bot_id()!` is the bot's user ID: the one READY gave, or asked to Discord once.
- `bot.application_id()!` is its application ID, the same way.
- `bot.latency()` is the mean heartbeat round trip over the shards.

## What else is on the client

| Field | See |
|---|---|
| `bot.commands` | [commands.md](commands.md) |
| `bot.components`, `bot.modals` | [components.md](components.md) |
| `bot.cache` | [cache.md](cache.md) |
| `bot.rest` | [rest.md](rest.md) |
| `bot.messages`, `bot.guilds`, `bot.members`… (shorters) | [rest.md](rest.md#shorters) |
| `bot.on`, `bot.wait_for`, `bot.collect`… | [events.md](events.md) |
| `bot.install`, `bot.hook`, `bot.intercept`… | [plugins.md](plugins.md) |
