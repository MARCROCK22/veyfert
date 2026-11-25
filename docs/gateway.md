# The gateway

The gateway is the WebSocket connection where Discord sends events. veyfert keeps one connection
per shard: it heartbeats, notices a connection that stopped answering, resumes the session after
a drop, identifies again when the session is gone, and respects Discord's send limit of 120
payloads a minute.

```v
import os
import veyfert
import veyfert.discord

const sessions_path = '.veyfert/sessions.json'

@[veyfert.Declare(name: 'status', description: 'Changes the status of the bot')]
struct Status {
mut:
	text string @[veyfert.Desc: 'What the bot is doing']
}

fn (s Status) run(mut ctx veyfert.CommandContext) ! {
	ctx.client.set_presence(discord.Presence{
		activities: [discord.Activity{
			name:  'custom'
			kind:  .custom
			state: s.text
		}]
	})!
	ctx.write(content: 'Status changed', ephemeral: true)!
}

fn main() {
	// This process runs shards 0-3 of 8; another one runs 4-7 with SHARD_START=4.
	first := os.getenv('SHARD_START').int()
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		shards:   veyfert.ShardRange{
			start: first
			end:   first + 4
			total: 8
		}
		compress: true
		sessions: veyfert.load_sessions(sessions_path) // resume what the last run left
	)
	bot.commands.add(Status{})
	bot.on[veyfert.GuildsReady](fn (e veyfert.GuildsReady, mut c veyfert.Client) ! {
		c.logger.info('shard ${e.shard}: ${e.guilds} guilds loaded')
	})
	bot.on[veyfert.ShardDisconnect](fn (e veyfert.ShardDisconnect, mut c veyfert.Client) ! {
		c.logger.warn('shard ${e.shard} closed with ${e.code}; resuming: ${e.resumable}')
	})
	bot.run()!
	bot.save_sessions(sessions_path)!
}
```

## Shards

A shard is one connection that carries the events of part of the guilds: guild `id` belongs to
shard `(id >> 22) % total`. `bot.shard_id_for(guild_id)` computes it.

- By default, `run` asks Discord how many shards it recommends and runs all of them, and
  [resharding](resharding.md) follows the recommendation as the bot grows.
- `shards: veyfert.ShardRange{start, end, total}` runs shards `start` to `end - 1` of `total`,
  to split a large bot among processes or machines. Each process then sees only its guilds, so
  its cache and its member requests are about those.
- Shards identify through a queue that follows the `max_concurrency` Discord gives: shards whose
  `id % max_concurrency` matches share a slot, one identify per slot every 5 seconds.

`bot.reconnect(shard)!` drops one connection, which then resumes. `bot.latency()` is the mean
time between a heartbeat and its acknowledgement.

## Compression

- `compress: true` asks Discord to zlib-compress large payloads, such as big `GUILD_CREATE`s.
- `zstd: true` compresses the whole connection with zstd-stream, which saves the most bandwidth.
  It needs libzstd and a build with `-d veyfert_zstd`; without the flag, `zstd` does nothing.
- `max_message_bytes` raises the 8 MiB limit on one message, for the `GUILD_CREATE` of a huge
  server, if you do not compress.

## Saving sessions

A session that Discord still keeps can be resumed: Discord then replays the events that were
missed, instead of sending every guild again. `stop()` closes the shards so that their sessions
stay resumable for a while, as Seyfert does, so a restart can pick them up:

```v
mut bot := veyfert.new_client(
	token:    os.getenv('DISCORD_TOKEN')
	sessions: veyfert.load_sessions('.veyfert/sessions.json') // [] when the file is missing
)
// ...
bot.run()!
bot.save_sessions('.veyfert/sessions.json')!
```

`bot.sessions()` returns them in memory. Resumed shards get no `GUILD_CREATE`s, so the cache
starts empty; use a [cache adapter](cache.md#adapters) to keep it across restarts. Until the
sessions expire, Discord shows the bot online.

## Lifecycle events

| Event | When |
|---|---|
| `veyfert.RawGuildCreate` | A guild arrives while a shard loads the guilds READY announced |
| `discord.GuildCreate` | The bot joins a guild, or one becomes available again |
| `veyfert.GuildsReady` | A shard has every guild READY announced (`shard`, `guilds`) |
| `veyfert.BotReady` | Once, when every shard of this process is ready (`user`, `shards`) |
| `veyfert.ShardDisconnect` | A connection closed (`shard`, `code`, `reason`, `resumable`) |
| `veyfert.ShardReconnect` | A shard is back (`shard`, `resumed`) |

## Close codes

- Discord's 4004 (bad token), 4010, 4011, 4012, 4013 and 4014 (intents) are fatal: the shard
  stops and `run` returns the error.
- 1000, 4001, 4007 and 4009 end the session: the shard identifies again.
- Anything else, and a connection that drops, is resumed. Reconnections back off up to 30 seconds
  when they keep failing.

## Gateway requests

These go to the shard of the guild:

```v
// Join a voice channel, muted; `channel_id: none` leaves it. Audio is out of scope.
bot.update_voice_state(guild_id: guild_id, channel_id: channel_id, self_mute: true)!

// Members by ID, or by username prefix; every member needs the guild_members intent.
members := bot.request_members(guild_id: guild_id, query: 'an', limit: 10)!

// Soundboard sounds: each guild's answer arrives as a discord.SoundboardSounds event.
bot.request_soundboard_sounds([guild_id])!

// The presence of every shard; shards that identify later use it too.
bot.set_presence(discord.Presence{ status: .dnd })!
```

`request_members` waits for every chunk of the answer, up to `timeout` (30 s), and sends the
request again when Discord rate-limits it.

## Changing what goes out

`bot.intercept_send(fn (shard int, payload string) ?string)` sees every payload a shard sends,
heartbeats and identifies included, and returns it changed, or `none` to drop it.
`bot.intercept` does the same for incoming events (see [events.md](events.md#changing-events)).

## TLS

Over `wss://`, V's `net.websocket` reads the connection on one thread while veyfert writes
heartbeats and payloads from others, which the TLS backends do not support. veyfert has no
workaround yet; see [known-issues.md](known-issues.md).
