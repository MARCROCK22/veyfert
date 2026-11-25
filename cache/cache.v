module cache

import json2
import sync
import veyfert.discord

// CacheOptions chooses what the cache keeps. Everything but messages is on; each resource also
// needs the intents that bring its events.
pub struct Options {
pub:
	guilds          bool = true
	channels        bool = true // threads and permission overwrites included
	roles           bool = true
	users           bool = true
	members         bool = true // complete only with the GUILD_MEMBERS intent
	emojis          bool = true
	stickers        bool = true
	presences       bool = true // needs GUILD_PRESENCES
	voice_states    bool = true
	stage_instances bool = true
	bans            bool = true // only the bans seen since startup
	messages        int // messages kept per channel; 0 keeps none
}

// Cache is an in-memory copy of what the gateway sent. Shard threads write it in event order,
// before listeners run; any thread can read it.
// ponytail: one RwMutex for every resource; split it per resource if readers contend.
@[heap]
pub struct Cache {
pub:
	options Options
mut:
	mu              &sync.RwMutex = sync.new_rwmutex()
	guilds          map[u64]discord.Guild
	channels        map[u64]discord.Channel
	users           map[u64]discord.User
	members         map[u64]map[u64]discord.Member
	roles           map[u64]map[u64]discord.Role
	emojis          map[u64][]discord.GuildEmoji
	stickers        map[u64][]discord.Sticker
	presences       map[u64]map[u64]discord.PresenceUpdate
	voice_states    map[u64]map[u64]discord.VoiceState
	stage_instances map[u64]map[u64]discord.StageInstance
	bans            map[u64]map[u64]bool
	messages        map[u64][]discord.Message
}

pub fn (mut c Cache) guild(id discord.Snowflake) ?discord.Guild {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.guilds[id.value] or { return none }
}

pub fn (mut c Cache) guilds() []discord.Guild {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.guilds.values()
}

pub fn (mut c Cache) channel(id discord.Snowflake) ?discord.Channel {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.channels[id.value] or { return none }
}

// channels lists the channels and threads of a guild.
// ponytail: scans every cached channel; index them by guild if bots with many guilds call it often.
pub fn (mut c Cache) channels(guild_id discord.Snowflake) []discord.Channel {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.channels.values().filter((it.guild_id or { discord.Snowflake{} }) == guild_id)
}

pub fn (mut c Cache) user(id discord.Snowflake) ?discord.User {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.users[id.value] or { return none }
}

pub fn (mut c Cache) member(guild_id discord.Snowflake, user_id discord.Snowflake) ?discord.Member {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.members[guild_id.value][user_id.value] or { return none }
}

pub fn (mut c Cache) members(guild_id discord.Snowflake) []discord.Member {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.members[guild_id.value].values()
}

pub fn (mut c Cache) role(guild_id discord.Snowflake, role_id discord.Snowflake) ?discord.Role {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.roles[guild_id.value][role_id.value] or { return none }
}

pub fn (mut c Cache) roles(guild_id discord.Snowflake) []discord.Role {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.roles[guild_id.value].values()
}

pub fn (mut c Cache) emojis(guild_id discord.Snowflake) []discord.GuildEmoji {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.emojis[guild_id.value].clone()
}

pub fn (mut c Cache) stickers(guild_id discord.Snowflake) []discord.Sticker {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.stickers[guild_id.value].clone()
}

pub fn (mut c Cache) presence(guild_id discord.Snowflake, user_id discord.Snowflake) ?discord.PresenceUpdate {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.presences[guild_id.value][user_id.value] or { return none }
}

pub fn (mut c Cache) voice_state(guild_id discord.Snowflake, user_id discord.Snowflake) ?discord.VoiceState {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.voice_states[guild_id.value][user_id.value] or { return none }
}

// voice_states lists who is in a voice channel of the guild.
pub fn (mut c Cache) voice_states(guild_id discord.Snowflake) []discord.VoiceState {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.voice_states[guild_id.value].values()
}

pub fn (mut c Cache) stage_instances(guild_id discord.Snowflake) []discord.StageInstance {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.stage_instances[guild_id.value].values()
}

// banned tells whether a ban of the user was seen since startup.
pub fn (mut c Cache) banned(guild_id discord.Snowflake, user_id discord.Snowflake) bool {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.bans[guild_id.value][user_id.value] or { false }
}

// messages lists the last messages of a channel, oldest first.
pub fn (mut c Cache) messages(channel_id discord.Snowflake) []discord.Message {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	return c.messages[channel_id.value].clone()
}

pub fn (mut c Cache) message(channel_id discord.Snowflake, id discord.Snowflake) ?discord.Message {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	for m in c.messages[channel_id.value] {
		if m.id == id {
			return m
		}
	}
	return none
}

// apply updates the cache from one dispatch. The client calls it on each shard's thread,
// before listeners run; bots do not need to.
pub fn (mut c Cache) apply(name string, raw string) {
	match name {
		'GUILD_CREATE', 'RAW_GUILD_CREATE', 'GUILD_UPDATE' {
			g := json2.decode[discord.Guild](raw) or { return }
			c.put_guild(g)
		}
		'GUILD_DELETE' {
			g := json2.decode[discord.GuildDelete](raw) or { return }
			c.remove_guild(g.id, g.unavailable)
		}
		'CHANNEL_CREATE', 'CHANNEL_UPDATE', 'THREAD_CREATE', 'THREAD_UPDATE' {
			ch := json2.decode[discord.Channel](raw) or { return }
			c.mu.lock()
			c.put_channel(ch, ch.guild_id)
			c.mu.unlock()
		}
		'CHANNEL_DELETE', 'THREAD_DELETE' {
			ch := json2.decode[discord.Channel](raw) or { return }
			c.mu.lock()
			c.channels.delete(ch.id.value)
			c.messages.delete(ch.id.value)
			c.mu.unlock()
		}
		'THREAD_LIST_SYNC' {
			sync_ := json2.decode[discord.ThreadListSync](raw) or { return }
			c.mu.lock()
			for t in sync_.threads {
				c.put_channel(t, sync_.guild_id)
			}
			c.mu.unlock()
		}
		'GUILD_ROLE_CREATE', 'GUILD_ROLE_UPDATE' {
			e := json2.decode[discord.GuildRoleCreate](raw) or { return }
			c.mu.lock()
			c.put_role(e.guild_id, e.role)
			c.mu.unlock()
		}
		'GUILD_ROLE_DELETE' {
			e := json2.decode[discord.GuildRoleDelete](raw) or { return }
			c.mu.lock()
			if e.guild_id.value in c.roles {
				c.roles[e.guild_id.value].delete(e.role_id.value)
			}
			c.mu.unlock()
		}
		'GUILD_MEMBER_ADD', 'GUILD_MEMBER_UPDATE' {
			m := json2.decode[discord.Member](raw) or { return }
			guild_id := m.guild_id or { return }
			c.mu.lock()
			c.put_member(guild_id, m)
			if name == 'GUILD_MEMBER_ADD' {
				c.count_member(guild_id, 1)
			}
			c.mu.unlock()
		}
		'GUILD_MEMBER_REMOVE' {
			e := json2.decode[discord.GuildMemberRemove](raw) or { return }
			c.mu.lock()
			if e.guild_id.value in c.members {
				c.members[e.guild_id.value].delete(e.user.id.value)
			}
			c.count_member(e.guild_id, -1)
			c.mu.unlock()
		}
		'GUILD_MEMBERS_CHUNK' {
			chunk := json2.decode[discord.MembersChunk](raw) or { return }
			c.mu.lock()
			for m in chunk.members {
				c.put_member(chunk.guild_id, m)
			}
			for p in chunk.presences {
				c.put_presence(chunk.guild_id, p)
			}
			c.mu.unlock()
		}
		'GUILD_EMOJIS_UPDATE' {
			e := json2.decode[discord.GuildEmojisUpdate](raw) or { return }
			if c.options.emojis {
				c.mu.lock()
				c.emojis[e.guild_id.value] = e.emojis
				c.mu.unlock()
			}
		}
		'GUILD_STICKERS_UPDATE' {
			e := json2.decode[discord.GuildStickersUpdate](raw) or { return }
			if c.options.stickers {
				c.mu.lock()
				c.stickers[e.guild_id.value] = e.stickers
				c.mu.unlock()
			}
		}
		'PRESENCE_UPDATE' {
			p := json2.decode[discord.PresenceUpdate](raw) or { return }
			guild_id := p.guild_id or { return }
			c.mu.lock()
			c.put_presence(guild_id, p)
			c.mu.unlock()
		}
		'VOICE_STATE_UPDATE' {
			v := json2.decode[discord.VoiceState](raw) or { return }
			guild_id := v.guild_id or { return }
			c.mu.lock()
			c.put_voice_state(guild_id, v)
			c.mu.unlock()
		}
		'STAGE_INSTANCE_CREATE', 'STAGE_INSTANCE_UPDATE', 'STAGE_INSTANCE_DELETE' {
			s := json2.decode[discord.StageInstance](raw) or { return }
			if c.options.stage_instances {
				c.mu.lock()
				if name == 'STAGE_INSTANCE_DELETE' {
					if s.guild_id.value in c.stage_instances {
						c.stage_instances[s.guild_id.value].delete(s.id.value)
					}
				} else {
					c.put_stage_instance(s)
				}
				c.mu.unlock()
			}
		}
		'GUILD_BAN_ADD', 'GUILD_BAN_REMOVE' {
			e := json2.decode[discord.GuildBanAdd](raw) or { return }
			if c.options.bans {
				c.mu.lock()
				if e.guild_id.value !in c.bans {
					c.bans[e.guild_id.value] = map[u64]bool{}
				}
				if name == 'GUILD_BAN_ADD' {
					c.bans[e.guild_id.value][e.user.id.value] = true
				} else {
					c.bans[e.guild_id.value].delete(e.user.id.value)
				}
				c.mu.unlock()
			}
		}
		'MESSAGE_CREATE', 'MESSAGE_UPDATE' {
			m := json2.decode[discord.Message](raw) or { return }
			c.mu.lock()
			c.put_message(m, name == 'MESSAGE_CREATE')
			c.mu.unlock()
		}
		'MESSAGE_DELETE' {
			e := json2.decode[discord.MessageDelete](raw) or { return }
			c.mu.lock()
			c.delete_messages(e.channel_id, [e.id])
			c.mu.unlock()
		}
		'MESSAGE_DELETE_BULK' {
			e := json2.decode[discord.MessageDeleteBulk](raw) or { return }
			c.mu.lock()
			c.delete_messages(e.channel_id, e.ids)
			c.mu.unlock()
		}
		'READY', 'USER_UPDATE' {
			u := if name == 'READY' {
				(json2.decode[discord.Ready](raw) or { return }).user
			} else {
				json2.decode[discord.User](raw) or { return }
			}
			c.mu.lock()
			c.put_user(u)
			c.mu.unlock()
		}
		else {}
	}
}

// put_guild stores a guild and everything a GUILD_CREATE brings; GUILD_UPDATE only brings the
// guild, its roles and its emojis.
fn (mut c Cache) put_guild(g discord.Guild) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	id := g.id.value
	if c.options.guilds {
		mut member_count := g.member_count
		if member_count == 0 {
			member_count = (c.guilds[id] or { discord.Guild{} }).member_count
		}
		c.guilds[id] = discord.Guild{
			...g
			member_count:    member_count
			roles:           []
			emojis:          []
			stickers:        []
			channels:        []
			threads:         []
			members:         []
			presences:       []
			voice_states:    []
			stage_instances: []
		}
	}
	if g.roles.len > 0 && c.options.roles {
		c.roles[id] = map[u64]discord.Role{}
		for r in g.roles {
			c.put_role(g.id, r)
		}
	}
	if g.emojis.len > 0 && c.options.emojis {
		c.emojis[id] = g.emojis
	}
	if g.stickers.len > 0 && c.options.stickers {
		c.stickers[id] = g.stickers
	}
	for ch in g.channels {
		c.put_channel(ch, g.id)
	}
	for t in g.threads {
		c.put_channel(t, g.id)
	}
	for m in g.members {
		c.put_member(g.id, m)
	}
	for p in g.presences {
		c.put_presence(g.id, p)
	}
	for v in g.voice_states {
		c.put_voice_state(g.id, v)
	}
	for s in g.stage_instances {
		c.put_stage_instance(s)
	}
}

// remove_guild forgets a guild the bot left; an unavailable guild only gets marked.
fn (mut c Cache) remove_guild(id discord.Snowflake, unavailable bool) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if unavailable {
		if g := c.guilds[id.value] {
			c.guilds[id.value] = discord.Guild{
				...g
				unavailable: true
			}
		}
		return
	}
	c.guilds.delete(id.value)
	for ch in c.channels.values() {
		if (ch.guild_id or { discord.Snowflake{} }) == id {
			c.channels.delete(ch.id.value)
			c.messages.delete(ch.id.value)
		}
	}
	c.members.delete(id.value)
	c.roles.delete(id.value)
	c.emojis.delete(id.value)
	c.stickers.delete(id.value)
	c.presences.delete(id.value)
	c.voice_states.delete(id.value)
	c.stage_instances.delete(id.value)
	c.bans.delete(id.value)
}

// The put helpers run with the write lock held.

fn (mut c Cache) put_channel(ch discord.Channel, guild_id ?discord.Snowflake) {
	if c.options.channels {
		// Channels inside GUILD_CREATE come without their guild_id.
		c.channels[ch.id.value] = if ch.guild_id == none {
			discord.Channel{
				...ch
				guild_id: guild_id
			}
		} else {
			ch
		}
	}
}

fn (mut c Cache) put_role(guild_id discord.Snowflake, r discord.Role) {
	if c.options.roles {
		if guild_id.value !in c.roles {
			c.roles[guild_id.value] = map[u64]discord.Role{}
		}
		c.roles[guild_id.value][r.id.value] = r
	}
}

fn (mut c Cache) put_user(u discord.User) {
	if c.options.users && u.username != '' {
		c.users[u.id.value] = u
	}
}

fn (mut c Cache) put_member(guild_id discord.Snowflake, m discord.Member) {
	user := m.user or { return }
	c.put_user(user)
	if c.options.members {
		if guild_id.value !in c.members {
			c.members[guild_id.value] = map[u64]discord.Member{}
		}
		c.members[guild_id.value][user.id.value] = discord.Member{
			...m
			guild_id: guild_id
		}
	}
}

fn (mut c Cache) count_member(guild_id discord.Snowflake, delta int) {
	if g := c.guilds[guild_id.value] {
		c.guilds[guild_id.value] = discord.Guild{
			...g
			member_count: g.member_count + delta
		}
	}
}

fn (mut c Cache) put_presence(guild_id discord.Snowflake, p discord.PresenceUpdate) {
	if c.options.presences {
		if guild_id.value !in c.presences {
			c.presences[guild_id.value] = map[u64]discord.PresenceUpdate{}
		}
		c.presences[guild_id.value][p.user.id.value] = discord.PresenceUpdate{
			...p
			guild_id: guild_id
		}
	}
}

fn (mut c Cache) put_voice_state(guild_id discord.Snowflake, v discord.VoiceState) {
	if !c.options.voice_states {
		return
	}
	if guild_id.value !in c.voice_states {
		c.voice_states[guild_id.value] = map[u64]discord.VoiceState{}
	}
	if v.channel_id == none {
		c.voice_states[guild_id.value].delete(v.user_id.value)
	} else {
		c.voice_states[guild_id.value][v.user_id.value] = discord.VoiceState{
			...v
			guild_id: guild_id
		}
	}
}

fn (mut c Cache) put_stage_instance(s discord.StageInstance) {
	if c.options.stage_instances {
		if s.guild_id.value !in c.stage_instances {
			c.stage_instances[s.guild_id.value] = map[u64]discord.StageInstance{}
		}
		c.stage_instances[s.guild_id.value][s.id.value] = s
	}
}

// put_message keeps the last `options.messages` messages of each channel. An update replaces
// the message when it is still kept.
fn (mut c Cache) put_message(m discord.Message, created bool) {
	c.put_user(m.author)
	if guild_id := m.guild_id {
		if member := m.member {
			c.put_member(guild_id, discord.Member{
				...member
				user: m.author
			})
		}
	}
	if c.options.messages <= 0 {
		return
	}
	key := m.channel_id.value
	mut kept := c.messages[key] or { []discord.Message{} }
	for i, old in kept {
		if old.id == m.id {
			kept[i] = m
			c.messages[key] = kept
			return
		}
	}
	if !created {
		return // an update of a message no longer kept
	}
	// Keep the messages in ID order, which is the order they were sent in.
	mut at := kept.len
	for at > 0 && kept[at - 1].id.value > m.id.value {
		at--
	}
	kept.insert(at, m)
	if kept.len > c.options.messages {
		// ponytail: shifts the array; a ring buffer only matters with large limits.
		kept.delete(0)
	}
	c.messages[key] = kept
}

fn (mut c Cache) delete_messages(channel_id discord.Snowflake, ids []discord.Snowflake) {
	if kept := c.messages[channel_id.value] {
		c.messages[channel_id.value] = kept.filter(it.id !in ids)
	}
}

// permissions works out what a member with `roles` may do in a channel, as Discord does: the
// guild's roles, then the channel's overwrites (a thread's come from its parent). It is none
// until the guild and its roles are cached.
pub fn (mut c Cache) permissions(guild_id discord.Snowflake, user_id discord.Snowflake, roles []discord.Snowflake, channel_id discord.Snowflake) ?discord.Permissions {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	all := discord.all_permissions()
	g := c.guilds[guild_id.value] or { return none }
	if g.owner_id == user_id {
		return all
	}
	if guild_id.value !in c.roles {
		return none
	}
	// The @everyone role has the guild's ID.
	mut perms := u64(discord.Permissions.parse((c.roles[guild_id.value][guild_id.value] or { discord.Role{} }).permissions))
	for id in roles {
		if r := c.roles[guild_id.value][id.value] {
			perms |= u64(discord.Permissions.parse(r.permissions))
		}
	}
	if perms & u64(discord.Permissions.administrator) != 0 {
		return all
	}
	mut ch := c.channels[channel_id.value] or { return unsafe { discord.Permissions(perms) } }
	if ch.thread_metadata != none {
		if parent_id := ch.parent_id {
			ch = c.channels[parent_id.value] or { ch }
		}
	}
	mut allowed := u64(0)
	mut denied := u64(0)
	for o in ch.permission_overwrites {
		if o.id == guild_id {
			perms = (perms & ~u64(discord.Permissions.parse(o.deny))) | u64(discord.Permissions.parse(o.allow))
		} else if o.kind == 0 && o.id in roles {
			allowed |= u64(discord.Permissions.parse(o.allow))
			denied |= u64(discord.Permissions.parse(o.deny))
		}
	}
	perms = (perms & ~denied) | allowed
	for o in ch.permission_overwrites {
		if o.kind == 1 && o.id == user_id {
			perms = (perms & ~u64(discord.Permissions.parse(o.deny))) | u64(discord.Permissions.parse(o.allow))
		}
	}
	return unsafe { discord.Permissions(perms) }
}

// The store and forget methods keep the cache in step with REST results: the shorters call
// them after Discord answers, before returning, as Seyfert does.

pub fn (mut c Cache) store_guild(g discord.Guild) {
	c.put_guild(g)
}

pub fn (mut c Cache) forget_guild(id discord.Snowflake) {
	c.remove_guild(id, false)
}

pub fn (mut c Cache) store_channel(ch discord.Channel) {
	c.mu.lock()
	c.put_channel(ch, ch.guild_id)
	c.mu.unlock()
}

pub fn (mut c Cache) forget_channel(id discord.Snowflake) {
	c.mu.lock()
	c.channels.delete(id.value)
	c.messages.delete(id.value)
	c.mu.unlock()
}

pub fn (mut c Cache) store_user(u discord.User) {
	c.mu.lock()
	c.put_user(u)
	c.mu.unlock()
}

pub fn (mut c Cache) store_member(guild_id discord.Snowflake, m discord.Member) {
	c.mu.lock()
	c.put_member(guild_id, m)
	c.mu.unlock()
}

pub fn (mut c Cache) forget_member(guild_id discord.Snowflake, user_id discord.Snowflake) {
	c.mu.lock()
	if guild_id.value in c.members {
		c.members[guild_id.value].delete(user_id.value)
	}
	c.mu.unlock()
}

pub fn (mut c Cache) store_role(guild_id discord.Snowflake, r discord.Role) {
	c.mu.lock()
	c.put_role(guild_id, r)
	c.mu.unlock()
}

// store_roles replaces the roles of a guild with a full list.
pub fn (mut c Cache) store_roles(guild_id discord.Snowflake, roles []discord.Role) {
	if !c.options.roles {
		return
	}
	c.mu.lock()
	c.roles[guild_id.value] = map[u64]discord.Role{}
	for r in roles {
		c.put_role(guild_id, r)
	}
	c.mu.unlock()
}

pub fn (mut c Cache) forget_role(guild_id discord.Snowflake, role_id discord.Snowflake) {
	c.mu.lock()
	if guild_id.value in c.roles {
		c.roles[guild_id.value].delete(role_id.value)
	}
	c.mu.unlock()
}

// store_message keeps a message a REST call returned, in ID order and within the limit.
pub fn (mut c Cache) store_message(m discord.Message) {
	c.mu.lock()
	c.put_message(m, true)
	c.mu.unlock()
}

pub fn (mut c Cache) forget_messages(channel_id discord.Snowflake, ids []discord.Snowflake) {
	c.mu.lock()
	c.delete_messages(channel_id, ids)
	c.mu.unlock()
}

pub fn (mut c Cache) store_emojis(guild_id discord.Snowflake, emojis []discord.GuildEmoji) {
	if !c.options.emojis {
		return
	}
	c.mu.lock()
	c.emojis[guild_id.value] = emojis
	c.mu.unlock()
}

pub fn (mut c Cache) store_emoji(guild_id discord.Snowflake, e discord.GuildEmoji) {
	if !c.options.emojis {
		return
	}
	c.mu.lock()
	mut kept := (c.emojis[guild_id.value] or { []discord.GuildEmoji{} }).filter((it.id or { discord.Snowflake{} }) != (e.id or { discord.Snowflake{} }))
	kept << e
	c.emojis[guild_id.value] = kept
	c.mu.unlock()
}

pub fn (mut c Cache) forget_emoji(guild_id discord.Snowflake, emoji_id discord.Snowflake) {
	c.mu.lock()
	if kept := c.emojis[guild_id.value] {
		c.emojis[guild_id.value] = kept.filter((it.id or { discord.Snowflake{} }) != emoji_id)
	}
	c.mu.unlock()
}

pub fn (mut c Cache) store_ban(guild_id discord.Snowflake, user_id discord.Snowflake, banned bool) {
	if !c.options.bans {
		return
	}
	c.mu.lock()
	if guild_id.value !in c.bans {
		c.bans[guild_id.value] = map[u64]bool{}
	}
	if banned {
		c.bans[guild_id.value][user_id.value] = true
	} else {
		c.bans[guild_id.value].delete(user_id.value)
	}
	c.mu.unlock()
}

pub fn (mut c Cache) sticker(guild_id discord.Snowflake, sticker_id discord.Snowflake) ?discord.Sticker {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	for s in c.stickers[guild_id.value] or { return none } {
		if s.id == sticker_id {
			return s
		}
	}
	return none
}

pub fn (mut c Cache) store_sticker(guild_id discord.Snowflake, s discord.Sticker) {
	if !c.options.stickers {
		return
	}
	c.mu.lock()
	mut kept := (c.stickers[guild_id.value] or { []discord.Sticker{} }).filter(it.id != s.id)
	kept << s
	c.stickers[guild_id.value] = kept
	c.mu.unlock()
}

pub fn (mut c Cache) forget_sticker(guild_id discord.Snowflake, sticker_id discord.Snowflake) {
	c.mu.lock()
	if kept := c.stickers[guild_id.value] {
		c.stickers[guild_id.value] = kept.filter(it.id != sticker_id)
	}
	c.mu.unlock()
}

// stage_instance returns the live stage instance of a stage channel.
pub fn (mut c Cache) stage_instance(channel_id discord.Snowflake) ?discord.StageInstance {
	c.mu.rlock()
	defer {
		c.mu.runlock()
	}
	for _, instances in c.stage_instances {
		for _, s in instances {
			if s.channel_id == channel_id {
				return s
			}
		}
	}
	return none
}

pub fn (mut c Cache) store_stage_instance(s discord.StageInstance) {
	if !c.options.stage_instances {
		return
	}
	c.mu.lock()
	c.put_stage_instance(s)
	c.mu.unlock()
}

pub fn (mut c Cache) forget_stage_instance(guild_id discord.Snowflake, channel_id discord.Snowflake) {
	c.mu.lock()
	if guild_id.value in c.stage_instances {
		for id, s in c.stage_instances[guild_id.value] {
			if s.channel_id == channel_id {
				c.stage_instances[guild_id.value].delete(id)
				break
			}
		}
	}
	c.mu.unlock()
}
