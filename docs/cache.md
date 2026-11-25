# The cache

`bot.cache` keeps what the gateway sends, as typed structs, so a bot can read guilds, channels,
members and more without asking Discord. The shorters write what they fetch into it too.

```v
import os
import veyfert
import veyfert.cache

@[veyfert.Declare(name: 'server', description: 'About this server')]
struct Server {}

fn (s Server) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	guild := ctx.client.cache.guild(guild_id) or { return error('the server is not cached yet') }
	channels := ctx.client.cache.channels(guild_id)
	roles := ctx.client.cache.roles(guild_id)
	members := ctx.client.cache.members(guild_id)
	ctx.write(content: '${guild.name}: ${channels.len} channels, ${roles.len} roles, ${members.len} members cached')!
}

fn main() {
	mut bot := veyfert.new_client(
		token:   os.getenv('DISCORD_TOKEN')
		intents: .guilds | .guild_members | .guild_messages
		cache:   cache.Options{
			presences: false // this bot never reads them
			messages:  50    // the last 50 messages of each channel
			// A second level that keeps at most 100 000 members; see Adapters.
			adapter: cache.Adapter(cache.new_limited_adapter({
				'member': cache.Limit{
					max: 100_000
				}
			}))
		}
	)
	bot.commands.add(Server{})
	bot.upload_commands()!
	bot.run()!
}
```

## What it keeps

| Resource | Getters | Needs |
|---|---|---|
| Guilds | `guild(id)`, `guilds()` | `guilds` |
| Channels and threads, with their overwrites | `channel(id)`, `channels(guild_id)` | `guilds` |
| Roles | `role(guild_id, role_id)`, `roles(guild_id)` | `guilds` |
| Users | `user(id)` | any event that carries users |
| Members | `member(guild_id, user_id)`, `members(guild_id)` | `guild_members` to be complete |
| Emojis and stickers | `emojis(guild_id)`, `stickers(guild_id)`, `sticker(guild_id, id)` | `guild_expressions` |
| Presences | `presence(guild_id, user_id)` | `guild_presences` |
| Voice states | `voice_state(guild_id, user_id)`, `voice_states(guild_id)` | `guild_voice_states` |
| Stage instances | `stage_instance(channel_id)`, `stage_instances(guild_id)` | `guilds` |
| Bans seen since startup | `banned(guild_id, user_id)` | `guild_moderation` |
| Messages (off by default) | `message(channel_id, id)`, `messages(channel_id)` | `guild_messages` |

Getters return copies: change them freely. The cache follows the gateway: created, updated and
deleted resources, members from interactions, reactions and typing events, and channel statuses.
A guild that is deleted, or that the bot leaves, takes its channels, roles, members and the rest
with it.

## Options

`cache.Options` turns each resource on or off (`guilds`, `channels`, `roles`, `users`,
`members`, `emojis`, `stickers`, `presences`, `voice_states`, `stage_instances`, `bans`, all on
by default) and sets `messages`, how many messages to keep per channel (0, none, by default).
Turning off what a bot never reads saves memory; presences are the largest on big servers.

## Permissions

`bot.cache.permissions(guild_id, user_id, roles, channel_id)` works out what a member with those
roles may do in a channel, as Discord does: the guild's roles, then the channel's overwrites (a
thread's come from its parent). It is `none` until the guild and its roles are cached.

```v
member := ctx.member() or { return }
perms := ctx.client.cache.permissions(guild_id, ctx.author().id, member.roles, channel_id) or {
	return
}
if perms.has(.manage_messages) {
	// ...
}
```

## Writing to it

The shorters keep what Discord answers, so `bot.members.fetch(guild_id, user_id)!` reads the cache
first and asks Discord only when it is missing (`force: true` always asks). Bots can write too,
with `store_guild`, `store_channel`, `store_user`, `store_member`, `store_role`, `store_message`,
`store_emoji`, `store_sticker`, `store_stage_instance` and `store_ban`, and remove with the
matching `forget_*`.

## Adapters

The typed in-memory cache is the first level: reads cost no decoding. An adapter adds a second
level that gets every write, as JSON under keys such as `guild:30`, `member:30:7` or
`role:30:50`, and answers what memory lacks: what another process wrote to a shared store, or what
a restarted bot kept. Messages stay in memory only.

```v
pub interface Adapter {
mut:
	get(key string) ?string
	set(key string, value string)
	remove(key string)
	scan(prefix string) []string // the keys that start with `prefix`
	flush()
}
```

- `cache.MemoryAdapter` keeps everything in this process: the reference adapter.
- `cache.new_limited_adapter(limits)` keeps at most `max` keys of a resource, dropping the oldest
  written, and forgets keys after `expire`, as Seyfert's LimitedMemoryAdapter. A resource is the
  start of a key: `guild`, `channel`, `user`, `member`, `role`, `presence`, `voice`, `stage`,
  `ban`, `emojis` and `stickers`.

```v
store := cache.new_limited_adapter({
	'member':   cache.Limit{
		max: 50_000
	}
	'presence': cache.Limit{
		expire: 10 * time.minute
	}
})
```

In a `cache.Options{}` literal, give the adapter as the interface:
`adapter: cache.Adapter(store)`. V does not turn a pointer into an optional interface field there.

An adapter for a shared store, such as Redis, implements the five methods. They are called from
several threads, so they must be safe for that. `cache.check_adapter(mut a)!` is a conformance
suite for a test: it flushes `a`, then checks that it keeps, replaces, removes, scans and flushes
keys as the cache needs.

```v
fn test_my_adapter_works_for_the_cache() ! {
	mut a := &MyRedisAdapter{} // yours
	cache.check_adapter(mut a)!
}
```

Several processes that share one adapter, such as the processes of a bot split with
`ShardRange`, read each other's resources through it.
