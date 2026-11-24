module veyfert

import encoding.base64
import json2
import net.urllib
import time
import veyfert.discord

// Shorters wrap the REST endpoints bots use most. As in Seyfert, each one asks Discord, keeps
// the answer in the cache, then returns it; `fetch` reads the cache first unless `force: true`.

@[params]
pub struct FetchOptions {
pub:
	force bool // skip the cache
}

// MessageShorter sends and manages channel messages: `c.messages.write(channel_id, content: 'hi')!`.
pub struct MessageShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut m MessageShorter) write(channel_id discord.Snowflake, opts MessageOptions) !discord.Message {
	msg := json2.decode[discord.Message](m.client.rest.request(.post,
		'/channels/${channel_id}/messages',
		body:  json2.encode(message_payload(opts)!)
		files: opts.files
	)!)!
	m.client.cache.store_message(msg)
	return msg
}

// reply answers a message in its channel, quoting it.
pub fn (mut m MessageShorter) reply(to discord.Message, opts MessageOptions) !discord.Message {
	return m.write(to.channel_id, MessageOptions{
		...opts
		reply_to: to.id
	})
}

pub fn (mut m MessageShorter) edit(channel_id discord.Snowflake, message_id discord.Snowflake, opts MessageOptions) !discord.Message {
	msg := json2.decode[discord.Message](m.client.rest.request(.patch,
		'/channels/${channel_id}/messages/${message_id}',
		body:  json2.encode(message_payload(opts)!)
		files: opts.files
	)!)!
	m.client.cache.store_message(msg)
	return msg
}

pub fn (mut m MessageShorter) delete(channel_id discord.Snowflake, message_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.delete, '/channels/${channel_id}/messages/${message_id}',
		reason: reason
	)!
	m.client.cache.forget_messages(channel_id, [message_id])
}

pub fn (mut m MessageShorter) fetch(channel_id discord.Snowflake, message_id discord.Snowflake, opts FetchOptions) !discord.Message {
	if !opts.force {
		if cached := m.client.cache.message(channel_id, message_id) {
			return cached
		}
	}
	msg := json2.decode[discord.Message](m.client.rest.request(.get, '/channels/${channel_id}/messages/${message_id}')!)!
	m.client.cache.store_message(msg)
	return msg
}

@[params]
pub struct ListMessages {
pub:
	limit  int = 50 // 1 to 100
	before ?discord.Snowflake
	after  ?discord.Snowflake
	around ?discord.Snowflake
}

// list returns up to `limit` messages, newest first.
pub fn (mut m MessageShorter) list(channel_id discord.Snowflake, opts ListMessages) ![]discord.Message {
	mut query := 'limit=${opts.limit}'
	if id := opts.before {
		query += '&before=${id}'
	}
	if id := opts.after {
		query += '&after=${id}'
	}
	if id := opts.around {
		query += '&around=${id}'
	}
	msgs := json2.decode[[]discord.Message](m.client.rest.request(.get,
		'/channels/${channel_id}/messages',
		query: query
	)!)!
	for msg in msgs {
		m.client.cache.store_message(msg)
	}
	return msgs
}

struct BulkDelete {
	messages []discord.Snowflake
}

// delete_bulk deletes 2 to 100 messages younger than two weeks.
pub fn (mut m MessageShorter) delete_bulk(channel_id discord.Snowflake, ids []discord.Snowflake, reason string) ! {
	m.client.rest.request(.post, '/channels/${channel_id}/messages/bulk-delete',
		body:   json2.encode(BulkDelete{ids})
		reason: reason
	)!
	m.client.cache.forget_messages(channel_id, ids)
}

// crosspost publishes a message of an announcement channel to the channels that follow it.
pub fn (mut m MessageShorter) crosspost(channel_id discord.Snowflake, message_id discord.Snowflake) !discord.Message {
	msg := json2.decode[discord.Message](m.client.rest.request(.post, '/channels/${channel_id}/messages/${message_id}/crosspost')!)!
	m.client.cache.store_message(msg)
	return msg
}

pub fn (mut m MessageShorter) pin(channel_id discord.Snowflake, message_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.put, '/channels/${channel_id}/messages/pins/${message_id}',
		reason: reason
	)!
}

pub fn (mut m MessageShorter) unpin(channel_id discord.Snowflake, message_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.delete, '/channels/${channel_id}/messages/pins/${message_id}',
		reason: reason
	)!
}

struct Pin {
	message discord.Message
}

struct Pins {
	items []Pin
}

// pins lists the pinned messages of a channel, newest pin first. Pins can be old, so they do
// not go to the cache, which keeps the latest messages.
pub fn (mut m MessageShorter) pins(channel_id discord.Snowflake) ![]discord.Message {
	pins := json2.decode[Pins](m.client.rest.request(.get, '/channels/${channel_id}/messages/pins')!)!
	return pins.items.map(it.message)
}

// ReactionShorter adds and removes reactions. `emoji` is a Unicode emoji or `name:id` for a custom one.
pub struct ReactionShorter {
mut:
	client &Client = unsafe { nil }
}

fn reaction_path(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string) string {
	return '/channels/${channel_id}/messages/${message_id}/reactions/${urllib.path_escape(emoji)}'
}

pub fn (mut r ReactionShorter) add(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string) ! {
	r.client.rest.request(.put, '${reaction_path(channel_id, message_id, emoji)}/@me')!
}

pub fn (mut r ReactionShorter) delete_own(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string) ! {
	r.client.rest.request(.delete, '${reaction_path(channel_id, message_id, emoji)}/@me')!
}

pub fn (mut r ReactionShorter) delete(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string, user_id discord.Snowflake) ! {
	r.client.rest.request(.delete, '${reaction_path(channel_id, message_id, emoji)}/${user_id}')!
}

// list returns up to 100 users who reacted with `emoji`.
pub fn (mut r ReactionShorter) list(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string) ![]discord.User {
	users := json2.decode[[]discord.User](r.client.rest.request(.get, reaction_path(channel_id,
		message_id, emoji),
		query: 'limit=100'
	)!)!
	for u in users {
		r.client.cache.store_user(u)
	}
	return users
}

// clear removes every reaction, or only those of `emoji` when it is not empty.
pub fn (mut r ReactionShorter) clear(channel_id discord.Snowflake, message_id discord.Snowflake, emoji string) ! {
	path := if emoji == '' {
		'/channels/${channel_id}/messages/${message_id}/reactions'
	} else {
		reaction_path(channel_id, message_id, emoji)
	}
	r.client.rest.request(.delete, path)!
}

// ChannelShorter reads and manages channels and their permission overwrites.
pub struct ChannelShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut ch ChannelShorter) fetch(id discord.Snowflake, opts FetchOptions) !discord.Channel {
	if !opts.force {
		if cached := ch.client.cache.channel(id) {
			return cached
		}
	}
	channel := json2.decode[discord.Channel](ch.client.rest.request(.get, '/channels/${id}')!)!
	ch.client.cache.store_channel(channel)
	return channel
}

// list returns the channels of a guild, from the cache once the guild has loaded.
pub fn (mut ch ChannelShorter) list(guild_id discord.Snowflake, opts FetchOptions) ![]discord.Channel {
	if !opts.force && ch.client.cache.options.channels && ch.client.cache.guild(guild_id) != none {
		return ch.client.cache.channels(guild_id)
	}
	channels := json2.decode[[]discord.Channel](ch.client.rest.request(.get, '/guilds/${guild_id}/channels')!)!
	for channel in channels {
		ch.client.cache.store_channel(channel)
	}
	return channels
}

@[params]
pub struct ChannelOptions {
pub:
	name                  ?string
	kind                  ?int @[json: 'type'] // a channel type; text when creating without it
	topic                 ?string
	nsfw                  ?bool
	parent_id             ?discord.Snowflake
	position              ?int
	rate_limit_per_user   ?int
	bitrate               ?int
	user_limit            ?int
	permission_overwrites ?[]discord.Overwrite
	reason                string @[skip] // written to the audit log
}

pub fn (mut ch ChannelShorter) create(guild_id discord.Snowflake, opts ChannelOptions) !discord.Channel {
	channel := json2.decode[discord.Channel](ch.client.rest.request(.post,
		'/guilds/${guild_id}/channels',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	ch.client.cache.store_channel(channel)
	return channel
}

pub fn (mut ch ChannelShorter) edit(id discord.Snowflake, opts ChannelOptions) !discord.Channel {
	channel := json2.decode[discord.Channel](ch.client.rest.request(.patch, '/channels/${id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	ch.client.cache.store_channel(channel)
	return channel
}

pub fn (mut ch ChannelShorter) delete(id discord.Snowflake, reason string) ! {
	ch.client.rest.request(.delete, '/channels/${id}', reason: reason)!
	ch.client.cache.forget_channel(id)
}

// typing shows the bot as typing for about 10 seconds, or until it sends a message.
pub fn (mut ch ChannelShorter) typing(id discord.Snowflake) ! {
	ch.client.rest.request(.post, '/channels/${id}/typing')!
}

struct OverwriteBody {
	kind  int @[json: 'type']
	allow string
	deny  string
}

// set_permission writes the overwrite of a role or member in a channel; the CHANNEL_UPDATE that
// follows updates the cache.
pub fn (mut ch ChannelShorter) set_permission(id discord.Snowflake, o discord.Overwrite, reason string) ! {
	ch.client.rest.request(.put, '/channels/${id}/permissions/${o.id}',
		body:   json2.encode(OverwriteBody{o.kind, o.allow, o.deny})
		reason: reason
	)!
}

pub fn (mut ch ChannelShorter) delete_permission(id discord.Snowflake, overwrite_id discord.Snowflake, reason string) ! {
	ch.client.rest.request(.delete, '/channels/${id}/permissions/${overwrite_id}',
		reason: reason
	)!
}

// MemberShorter reads and moderates guild members.
pub struct MemberShorter {
mut:
	client &Client = unsafe { nil }
}

// keep marks a member from REST with its guild and caches it.
fn (mut m MemberShorter) keep(guild_id discord.Snowflake, member discord.Member) discord.Member {
	kept := discord.Member{
		...member
		guild_id: guild_id
	}
	m.client.cache.store_member(guild_id, kept)
	return kept
}

pub fn (mut m MemberShorter) fetch(guild_id discord.Snowflake, user_id discord.Snowflake, opts FetchOptions) !discord.Member {
	if !opts.force {
		if cached := m.client.cache.member(guild_id, user_id) {
			return cached
		}
	}
	return m.keep(guild_id, json2.decode[discord.Member](m.client.rest.request(.get, '/guilds/${guild_id}/members/${user_id}')!)!)
}

// list returns up to `limit` (1 to 1000) members after the user ID `after`; it needs the
// GUILD_MEMBERS intent.
pub fn (mut m MemberShorter) list(guild_id discord.Snowflake, limit int, after discord.Snowflake) ![]discord.Member {
	members := json2.decode[[]discord.Member](m.client.rest.request(.get,
		'/guilds/${guild_id}/members',
		query: 'limit=${limit}&after=${after}'
	)!)!
	mut kept := []discord.Member{cap: members.len}
	for member in members {
		kept << m.keep(guild_id, member)
	}
	return kept
}

// search returns up to `limit` members whose username or nickname starts with `query`.
pub fn (mut m MemberShorter) search(guild_id discord.Snowflake, query string, limit int) ![]discord.Member {
	members := json2.decode[[]discord.Member](m.client.rest.request(.get,
		'/guilds/${guild_id}/members/search',
		query: 'query=${urllib.query_escape(query)}&limit=${limit}'
	)!)!
	mut kept := []discord.Member{cap: members.len}
	for member in members {
		kept << m.keep(guild_id, member)
	}
	return kept
}

@[params]
pub struct MemberOptions {
pub:
	nick                         ?discord.Nullable[string]
	roles                        ?[]discord.Snowflake
	mute                         ?bool
	deaf                         ?bool
	channel_id                   ?discord.Nullable[discord.Snowflake] // moves the member; null disconnects
	communication_disabled_until ?discord.Nullable[string]            // ISO 8601; null lifts a timeout
	reason                       string @[skip] // written to the audit log
}

pub fn (mut m MemberShorter) edit(guild_id discord.Snowflake, user_id discord.Snowflake, opts MemberOptions) !discord.Member {
	return m.keep(guild_id, json2.decode[discord.Member](m.client.rest.request(.patch,
		'/guilds/${guild_id}/members/${user_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!)
}

pub fn (mut m MemberShorter) kick(guild_id discord.Snowflake, user_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.delete, '/guilds/${guild_id}/members/${user_id}', reason: reason)!
	m.client.cache.forget_member(guild_id, user_id)
}

struct BanBody {
	delete_message_seconds int
}

// ban bans a user, deleting their messages of the last `delete_messages` (up to 7 days).
pub fn (mut m MemberShorter) ban(guild_id discord.Snowflake, user_id discord.Snowflake, delete_messages time.Duration, reason string) ! {
	m.client.rest.request(.put, '/guilds/${guild_id}/bans/${user_id}',
		body:   json2.encode(BanBody{int(delete_messages / time.second)})
		reason: reason
	)!
	m.client.cache.forget_member(guild_id, user_id)
	m.client.cache.store_ban(guild_id, user_id, true)
}

pub fn (mut m MemberShorter) unban(guild_id discord.Snowflake, user_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.delete, '/guilds/${guild_id}/bans/${user_id}', reason: reason)!
	m.client.cache.store_ban(guild_id, user_id, false)
}

pub fn (mut m MemberShorter) add_role(guild_id discord.Snowflake, user_id discord.Snowflake, role_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.put, '/guilds/${guild_id}/members/${user_id}/roles/${role_id}',
		reason: reason
	)!
}

pub fn (mut m MemberShorter) remove_role(guild_id discord.Snowflake, user_id discord.Snowflake, role_id discord.Snowflake, reason string) ! {
	m.client.rest.request(.delete, '/guilds/${guild_id}/members/${user_id}/roles/${role_id}',
		reason: reason
	)!
}

// timeout keeps a member from talking for `duration` (up to 28 days); 0 lifts it.
pub fn (mut m MemberShorter) timeout(guild_id discord.Snowflake, user_id discord.Snowflake, duration time.Duration, reason string) !discord.Member {
	until := if duration > 0 {
		discord.Nullable[string]{
			value: time.now().add(duration).format_rfc3339()
		}
	} else {
		discord.Nullable[string]{
			is_null: true
		}
	}
	return m.edit(guild_id, user_id, communication_disabled_until: until, reason: reason)
}

// RoleShorter reads and manages the roles of a guild.
pub struct RoleShorter {
mut:
	client &Client = unsafe { nil }
}

// list returns the roles of a guild, from the cache once the guild has loaded.
pub fn (mut r RoleShorter) list(guild_id discord.Snowflake, opts FetchOptions) ![]discord.Role {
	if !opts.force && r.client.cache.options.roles && r.client.cache.guild(guild_id) != none {
		return r.client.cache.roles(guild_id)
	}
	roles := json2.decode[[]discord.Role](r.client.rest.request(.get, '/guilds/${guild_id}/roles')!)!
	r.client.cache.store_roles(guild_id, roles)
	return roles
}

pub fn (mut r RoleShorter) fetch(guild_id discord.Snowflake, role_id discord.Snowflake, opts FetchOptions) !discord.Role {
	if !opts.force {
		if cached := r.client.cache.role(guild_id, role_id) {
			return cached
		}
	}
	role := json2.decode[discord.Role](r.client.rest.request(.get, '/guilds/${guild_id}/roles/${role_id}')!)!
	r.client.cache.store_role(guild_id, role)
	return role
}

@[params]
pub struct RoleOptions {
pub:
	name        ?string
	permissions ?string // Permissions.wire()
	color       ?int
	hoist       ?bool
	mentionable ?bool
	reason      string @[skip] // written to the audit log
}

pub fn (mut r RoleShorter) create(guild_id discord.Snowflake, opts RoleOptions) !discord.Role {
	role := json2.decode[discord.Role](r.client.rest.request(.post, '/guilds/${guild_id}/roles',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	r.client.cache.store_role(guild_id, role)
	return role
}

pub fn (mut r RoleShorter) edit(guild_id discord.Snowflake, role_id discord.Snowflake, opts RoleOptions) !discord.Role {
	role := json2.decode[discord.Role](r.client.rest.request(.patch,
		'/guilds/${guild_id}/roles/${role_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	r.client.cache.store_role(guild_id, role)
	return role
}

pub fn (mut r RoleShorter) delete(guild_id discord.Snowflake, role_id discord.Snowflake, reason string) ! {
	r.client.rest.request(.delete, '/guilds/${guild_id}/roles/${role_id}', reason: reason)!
	r.client.cache.forget_role(guild_id, role_id)
}

// GuildShorter reads the guilds of the bot and leaves them.
pub struct GuildShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut g GuildShorter) fetch(id discord.Snowflake, opts FetchOptions) !discord.Guild {
	if !opts.force {
		if cached := g.client.cache.guild(id) {
			return cached
		}
	}
	guild := json2.decode[discord.Guild](g.client.rest.request(.get, '/guilds/${id}',
		query: 'with_counts=true'
	)!)!
	g.client.cache.store_guild(guild)
	return guild
}

// list returns the cached guilds: every guild of this process's shards once BOT_READY fired.
pub fn (mut g GuildShorter) list() []discord.Guild {
	return g.client.cache.guilds()
}

pub fn (mut g GuildShorter) leave(id discord.Snowflake) ! {
	g.client.rest.request(.delete, '/users/@me/guilds/${id}')!
	g.client.cache.forget_guild(id)
}

// UserShorter reads users and sends them direct messages.
pub struct UserShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut u UserShorter) fetch(id discord.Snowflake, opts FetchOptions) !discord.User {
	if !opts.force {
		if cached := u.client.cache.user(id) {
			return cached
		}
	}
	user := json2.decode[discord.User](u.client.rest.request(.get, '/users/${id}')!)!
	u.client.cache.store_user(user)
	return user
}

struct DmBody {
	recipient_id discord.Snowflake
}

// dm opens, or finds, the direct message channel with a user.
pub fn (mut u UserShorter) dm(id discord.Snowflake) !discord.Channel {
	channel := json2.decode[discord.Channel](u.client.rest.request(.post, '/users/@me/channels',
		body: json2.encode(DmBody{id})
	)!)!
	u.client.cache.store_channel(channel)
	return channel
}

// write sends a direct message; users who share no server with the bot, or who closed their
// DMs, cannot receive it.
pub fn (mut u UserShorter) write(id discord.Snowflake, opts MessageOptions) !discord.Message {
	channel := u.dm(id)!
	return u.client.messages.write(channel.id, opts)
}

// ThreadShorter creates threads and manages who is in them.
pub struct ThreadShorter {
mut:
	client &Client = unsafe { nil }
}

@[params]
pub struct ThreadOptions {
pub:
	kind                  ?int @[json: 'type'] // 11 public (default), 12 private
	auto_archive_duration ?int // minutes: 60, 1440, 4320 or 10080
	invitable             ?bool
	rate_limit_per_user   ?int
	reason                string @[skip] // written to the audit log
}

struct ThreadBody {
	ThreadOptions
	name string
}

pub fn (mut t ThreadShorter) create(channel_id discord.Snowflake, name string, opts ThreadOptions) !discord.Channel {
	created := json2.decode[discord.Channel](t.client.rest.request(.post,
		'/channels/${channel_id}/threads',
		body:   json2.encode(ThreadBody{ ThreadOptions: opts, name: name })
		reason: opts.reason
	)!)!
	t.client.cache.store_channel(created)
	return created
}

// create_from_message starts a thread on a message.
pub fn (mut t ThreadShorter) create_from_message(channel_id discord.Snowflake, message_id discord.Snowflake, name string, opts ThreadOptions) !discord.Channel {
	created := json2.decode[discord.Channel](t.client.rest.request(.post,
		'/channels/${channel_id}/messages/${message_id}/threads',
		body:   json2.encode(ThreadBody{ ThreadOptions: opts, name: name })
		reason: opts.reason
	)!)!
	t.client.cache.store_channel(created)
	return created
}

pub fn (mut t ThreadShorter) join(thread_id discord.Snowflake) ! {
	t.client.rest.request(.put, '/channels/${thread_id}/thread-members/@me')!
}

pub fn (mut t ThreadShorter) leave(thread_id discord.Snowflake) ! {
	t.client.rest.request(.delete, '/channels/${thread_id}/thread-members/@me')!
}

pub fn (mut t ThreadShorter) add_member(thread_id discord.Snowflake, user_id discord.Snowflake) ! {
	t.client.rest.request(.put, '/channels/${thread_id}/thread-members/${user_id}')!
}

pub fn (mut t ThreadShorter) remove_member(thread_id discord.Snowflake, user_id discord.Snowflake) ! {
	t.client.rest.request(.delete, '/channels/${thread_id}/thread-members/${user_id}')!
}

struct ActiveThreads {
	threads []discord.Channel
}

// list_active returns the active threads of a guild.
pub fn (mut t ThreadShorter) list_active(guild_id discord.Snowflake) ![]discord.Channel {
	threads := json2.decode[ActiveThreads](t.client.rest.request(.get, '/guilds/${guild_id}/threads/active')!)!.threads
	for th in threads {
		t.client.cache.store_channel(th)
	}
	return threads
}

// WebhookShorter creates webhooks and sends messages through them. Webhooks are not cached.
pub struct WebhookShorter {
mut:
	client &Client = unsafe { nil }
}

struct WebhookBody {
	name string
}

pub fn (mut w WebhookShorter) create(channel_id discord.Snowflake, name string, reason string) !discord.Webhook {
	return json2.decode[discord.Webhook](w.client.rest.request(.post,
		'/channels/${channel_id}/webhooks',
		body:   json2.encode(WebhookBody{name})
		reason: reason
	)!)!
}

pub fn (mut w WebhookShorter) list(channel_id discord.Snowflake) ![]discord.Webhook {
	return json2.decode[[]discord.Webhook](w.client.rest.request(.get, '/channels/${channel_id}/webhooks')!)!
}

pub fn (mut w WebhookShorter) delete(id discord.Snowflake, reason string) ! {
	w.client.rest.request(.delete, '/webhooks/${id}', reason: reason)!
}

@[params]
pub struct WebhookMessage {
	MessageOptions
pub:
	username   ?string
	avatar_url ?string
	thread_id  ?discord.Snowflake // send into this thread of the webhook's channel
}

struct WebhookPayload {
	MessagePayload
	username   ?string
	avatar_url ?string
}

// execute sends a message as the webhook; the token authorizes it, not the bot.
pub fn (mut w WebhookShorter) execute(id discord.Snowflake, token string, opts WebhookMessage) !discord.Message {
	mut query := 'wait=true'
	if thread_id := opts.thread_id {
		query += '&thread_id=${thread_id}'
	}
	msg := json2.decode[discord.Message](w.client.rest.request(.post, '/webhooks/${id}/${token}',
		body:  json2.encode(WebhookPayload{
			MessagePayload: message_payload(opts.MessageOptions)!
			username:       opts.username
			avatar_url:     opts.avatar_url
		})
		query: query
		files: opts.files
		auth:  false
	)!)!
	w.client.cache.store_message(msg)
	return msg
}

// BanShorter lists bans; `c.members.ban` and `c.members.unban` change them.
pub struct BanShorter {
mut:
	client &Client = unsafe { nil }
}

// list returns up to 1000 bans of a guild.
pub fn (mut b BanShorter) list(guild_id discord.Snowflake) ![]discord.Ban {
	bans := json2.decode[[]discord.Ban](b.client.rest.request(.get, '/guilds/${guild_id}/bans',
		query: 'limit=1000'
	)!)!
	for ban in bans {
		b.client.cache.store_ban(guild_id, ban.user.id, true)
	}
	return bans
}

pub fn (mut b BanShorter) fetch(guild_id discord.Snowflake, user_id discord.Snowflake) !discord.Ban {
	ban := json2.decode[discord.Ban](b.client.rest.request(.get, '/guilds/${guild_id}/bans/${user_id}')!)!
	b.client.cache.store_ban(guild_id, user_id, true)
	return ban
}

// EmojiShorter reads and manages the custom emojis of a guild.
pub struct EmojiShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut e EmojiShorter) list(guild_id discord.Snowflake, opts FetchOptions) ![]discord.GuildEmoji {
	if !opts.force && e.client.cache.options.emojis && e.client.cache.guild(guild_id) != none {
		return e.client.cache.emojis(guild_id)
	}
	emojis := json2.decode[[]discord.GuildEmoji](e.client.rest.request(.get, '/guilds/${guild_id}/emojis')!)!
	e.client.cache.store_emojis(guild_id, emojis)
	return emojis
}

struct EmojiBody {
	name  string
	image string
	roles []discord.Snowflake
}

// create uploads an emoji (PNG, JPEG, GIF or WebP, up to 256 KiB), usable by `roles`, or by
// everyone when it is empty.
pub fn (mut e EmojiShorter) create(guild_id discord.Snowflake, name string, image discord.File, roles []discord.Snowflake, reason string) !discord.GuildEmoji {
	emoji := json2.decode[discord.GuildEmoji](e.client.rest.request(.post,
		'/guilds/${guild_id}/emojis',
		body:   json2.encode(EmojiBody{name, 'data:${image.content_type};base64,${base64.encode(image.data)}', roles})
		reason: reason
	)!)!
	e.client.cache.store_emoji(guild_id, emoji)
	return emoji
}

pub fn (mut e EmojiShorter) delete(guild_id discord.Snowflake, emoji_id discord.Snowflake, reason string) ! {
	e.client.rest.request(.delete, '/guilds/${guild_id}/emojis/${emoji_id}', reason: reason)!
	e.client.cache.forget_emoji(guild_id, emoji_id)
}
