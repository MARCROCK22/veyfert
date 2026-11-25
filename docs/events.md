# Events

Discord sends what happens as gateway events. A listener names its event by its payload type, so
it gets a typed struct, never raw JSON.

```v
import os
import time
import veyfert
import veyfert.discord

// A custom event: any struct with an @[discord.Event] attribute, sent with `emit`.
@[discord.Event('LEVEL_UP')]
struct LevelUp {
	user_id discord.Snowflake
	level   int
}

fn main() {
	mut bot := veyfert.new_client(
		token:   os.getenv('DISCORD_TOKEN')
		intents: .guilds | .guild_messages | .message_content | .guild_members
	)
	bot.on[discord.MessageCreate](fn (m discord.MessageCreate, mut c veyfert.Client) ! {
		if m.author.bot {
			return
		}
		match m.content {
			'!ping' {
				c.messages.reply(m.Message, content: 'pong')!
			}
			'!level' {
				c.emit(LevelUp{
					user_id: m.author.id
					level:   2
				})
			}
			else {}
		}
	})
	bot.on[LevelUp](fn (e LevelUp, mut c veyfert.Client) ! {
		c.logger.info('${e.user_id} reached level ${e.level}')
	})
	bot.on[discord.GuildMemberAdd](fn (e discord.GuildMemberAdd, mut c veyfert.Client) ! {
		user := e.user or { return }
		c.logger.info('${user.username} joined ${e.guild_id or { discord.Snowflake{} }}')
	})
	// once: only the next event.
	started := time.now()
	bot.once[veyfert.BotReady](fn [started] (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('ready after ${time.since(started)}')
	})
	bot.run()!
}
```

## Listening

- `bot.on[T](fn (T, mut Client) !)` runs for every event whose payload is `T`. The event name
  comes from `T`'s `@[discord.Event('NAME')]` attribute. Register listeners before `run`.
- `bot.once[T](f)` runs `f` for the next one only. It is safe to call while the bot runs.
- `bot.on_raw(fn (veyfert.RawEvent, mut Client) !)` sees every dispatch before decoding, with
  `shard`, `name` and `data` (the JSON). Raw listeners also get the repeated
  `GUILD_MEMBER_UPDATE`s and `PRESENCE_UPDATE`s that typed listeners do not (see below).

A listener that returns an error is logged; the others still run.

## Waiting for an event

`wait_for` blocks until an event passes a filter, or returns `none` after the timeout. It is
safe inside a command or a listener: events are matched on the shard's reader thread, so a
waiting listener does not starve the pool.

```v
// Inside a command: wait 30 seconds for the author's next message in this channel.
author := ctx.author().id
channel := ctx.channel_id() or { return }
reply := ctx.client.wait_for[discord.MessageCreate](fn [author, channel] (m discord.MessageCreate) bool {
	return m.author.id == author && m.channel_id == channel
}, 30 * time.second) or {
	ctx.followup(content: 'You did not answer.')!
	return
}
ctx.followup(content: 'You said: ${reply.content}')!
```

The filter runs under the client's lock: keep it to comparisons.

## Collecting events

`collect` runs a function for every event that passes a filter, one at a time, until it ends,
and returns why: `.timeout`, `.idle`, `.max` or `.stopped`. The function returns
`veyfert.stop()` to end it.

```v
why := bot.collect[discord.MessageReactionAdd](fn [message_id] (r discord.MessageReactionAdd) bool {
	return r.message_id == message_id
}, fn (r discord.MessageReactionAdd, mut c veyfert.Client) ! {
	c.logger.info('${r.user_id} reacted')
}, timeout: 5 * time.minute, idle: time.minute, max: 10)
```

`veyfert.Collect` has `timeout` (1 minute; 0 never), `idle` (0 never) and `max` (0 has no
limit). Like `wait_for`, it blocks. [components.md](components.md#collecting-clicks) has the
same for clicks on a message.

## Custom events

`bot.emit(value)` sends a value of a type with `@[discord.Event('NAME')]` to its listeners, as if
the gateway had sent it. Plugins and bots use it for their own events, such as `LevelUp` above.

## Changing events

`bot.intercept(fn (name string, raw string) ?string)` runs on every dispatch before anything
else sees it, the cache included: it returns the payload, changed or not, or `none` to drop the
event.

```v
bot.intercept(fn (name string, raw string) ?string {
	if name == 'TYPING_START' {
		return none // nobody here cares about typing
	}
	return raw
})
```

## Threads

Listeners run on the client's pool of `workers` threads (4 by default), apart from commands. They
may block. State that several listeners share needs `shared` or `sync`, and `workers: 1` runs
them one at a time in the order events arrive.

## Startup and duplicates

- At startup, every guild arrives as a `veyfert.RawGuildCreate`; `discord.GuildCreate` then means
  the bot joined a guild, or one came back from an outage. `veyfert.GuildsReady` (per shard) and
  `veyfert.BotReady` (once) follow. See [gateway.md](gateway.md#lifecycle-events).
- Discord repeats some `GUILD_MEMBER_UPDATE` and `PRESENCE_UPDATE` events. A copy that equals the
  last one of the same member within 1.5 seconds reaches only raw listeners, as in Seyfert.

## Event types

Every gateway event has a type in `veyfert.discord`; a few of them, with their names:

| Type | Event |
|---|---|
| `discord.Ready`, `discord.Resumed` | READY, RESUMED |
| `discord.GuildCreate`, `GuildUpdate`, `GuildDelete` | GUILD_CREATE, GUILD_UPDATE, GUILD_DELETE |
| `discord.ChannelCreate`, `ChannelUpdate`, `ChannelDelete`, `ChannelPinsUpdate` | CHANNEL_* |
| `discord.ThreadCreate`, `ThreadUpdate`, `ThreadDelete`, `ThreadListSync`, `ThreadMemberUpdate`, `ThreadMembersUpdate` | THREAD_* |
| `discord.GuildMemberAdd`, `GuildMemberUpdate`, `GuildMemberRemove`, `MembersChunk` | GUILD_MEMBER_*, GUILD_MEMBERS_CHUNK |
| `discord.GuildRoleCreate`, `GuildRoleUpdate`, `GuildRoleDelete` | GUILD_ROLE_* |
| `discord.GuildBanAdd`, `GuildBanRemove`, `GuildAuditLogEntryCreate` | GUILD_BAN_*, GUILD_AUDIT_LOG_ENTRY_CREATE |
| `discord.GuildEmojisUpdate`, `GuildStickersUpdate` | GUILD_EMOJIS_UPDATE, GUILD_STICKERS_UPDATE |
| `discord.MessageCreate`, `MessageUpdate`, `MessageDelete`, `MessageDeleteBulk` | MESSAGE_* |
| `discord.MessageReactionAdd`, `MessageReactionRemove`, `MessageReactionRemoveAll`, `MessageReactionRemoveEmoji` | MESSAGE_REACTION_* |
| `discord.MessagePollVoteAdd`, `MessagePollVoteRemove` | MESSAGE_POLL_VOTE_* |
| `discord.TypingStart`, `discord.PresenceUpdate`, `discord.UserUpdate` | TYPING_START, PRESENCE_UPDATE, USER_UPDATE |
| `discord.VoiceState`, `VoiceServerUpdate`, `VoiceChannelStatusUpdate`, `VoiceChannelStartTimeUpdate`, `VoiceChannelEffectSend` | VOICE_* |
| `discord.Interaction` | INTERACTION_CREATE (commands and handlers usually answer these) |
| `discord.InviteCreate`, `InviteDelete`, `WebhooksUpdate` | INVITE_*, WEBHOOKS_UPDATE |
| `discord.StageInstanceCreate`, `StageInstanceUpdate`, `StageInstanceDelete` | STAGE_INSTANCE_* |
| `discord.ScheduledEventCreate`, `Update`, `Delete`, `UserAdd`, `UserRemove` | GUILD_SCHEDULED_EVENT_* |
| `discord.AutoModerationRuleCreate`, `Update`, `Delete`, `AutoModerationActionExecution` | AUTO_MODERATION_* |
| `discord.EntitlementCreate`, `Update`, `Delete`, `SubscriptionCreate`, `Update`, `Delete` | ENTITLEMENT_*, SUBSCRIPTION_* |
| `discord.IntegrationCreate`, `Update`, `Delete`, `GuildIntegrationsUpdate` | INTEGRATION_*, GUILD_INTEGRATIONS_UPDATE |
| `discord.SoundboardSoundCreate`, `Update`, `Delete`, `SoundboardSoundsUpdate`, `SoundboardSounds` | GUILD_SOUNDBOARD_*, SOUNDBOARD_SOUNDS |
| `discord.ApplicationCommandPermissionsUpdate`, `discord.RateLimited`, `discord.ChannelInfo` | Their events |

`veyfert` adds `RawGuildCreate`, `RawGuildDelete`, `GuildsReady`, `BotReady`, `ShardDisconnect`
and `ShardReconnect`.
