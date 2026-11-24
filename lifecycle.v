module veyfert

import veyfert.discord

// The framework's own events, and the gateway's shape of a presence.

// RawGuildCreate is a GUILD_CREATE that arrives while a shard loads the guilds announced by
// READY; GUILD_CREATE then only reports guilds the bot joins afterwards.
@[discord.Event('RAW_GUILD_CREATE')]
pub struct RawGuildCreate {
	discord.GuildCreate
}

// GuildsReady is emitted when a shard has received every guild announced by its READY.
@[discord.Event('GUILDS_READY')]
pub struct GuildsReady {
pub:
	shard  int
	guilds int
}

// BotReady is emitted once, when every shard of this process is ready.
@[discord.Event('BOT_READY')]
pub struct BotReady {
pub:
	user   discord.User
	shards int
}

@[discord.Event('SHARD_DISCONNECT')]
pub struct ShardDisconnect {
pub:
	shard     int
	code      int
	reason    string
	resumable bool // whether the shard will resume its session or identify again
}

@[discord.Event('SHARD_RECONNECT')]
pub struct ShardReconnect {
pub:
	shard   int
	resumed bool
}

// RawEvent is every dispatch, before decoding, for `Client.on_raw`.
pub struct RawEvent {
pub:
	shard int
	name  string
	data  string
}

// PresencePayload is the gateway's shape of a presence, where `since` must be present.
struct PresencePayload {
	since      discord.Nullable[i64] = discord.Nullable[i64]{
		is_null: true
	}
	activities []discord.Activity
	status     discord.Status
	afk        bool
}

fn gateway_presence(p discord.Presence) PresencePayload {
	return PresencePayload{
		activities: p.activities
		status:     p.status
		afk:        p.afk
	}
}
