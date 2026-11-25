module veyfert

import json2
import net.urllib
import time
import veyfert.discord
import veyfert.rest

// The guild-side shorters that Seyfert has and veyfert lacked: guild settings and sub-resources
// (`c.guilds.stickers`, `c.guilds.events`…), and more of channels, members, roles, bans and emojis.

struct PermissionsAnswer {
	permissions string
}

fn permissions_of(text string) !discord.Permissions {
	return discord.Permissions.parse(json2.decode[PermissionsAnswer](text)!.permissions)
}

@[params]
pub struct GuildOptions {
pub:
	name                          ?string
	verification_level            ?int
	default_message_notifications ?int
	explicit_content_filter       ?int
	afk_channel_id                ?discord.Nullable[discord.Snowflake]
	afk_timeout                   ?int
	icon                          ?discord.Nullable[string] // File.data_uri(); null removes it
	splash                        ?discord.Nullable[string]
	discovery_splash              ?discord.Nullable[string]
	banner                        ?discord.Nullable[string]
	system_channel_id             ?discord.Nullable[discord.Snowflake]
	system_channel_flags          ?int
	rules_channel_id              ?discord.Nullable[discord.Snowflake]
	public_updates_channel_id     ?discord.Nullable[discord.Snowflake]
	safety_alerts_channel_id      ?discord.Nullable[discord.Snowflake]
	preferred_locale              ?string
	features                      ?[]string
	description                   ?discord.Nullable[string]
	premium_progress_bar_enabled  ?bool
	reason                        string @[skip] // written to the audit log
}

pub fn (mut g GuildShorter) edit(id discord.Snowflake, opts GuildOptions) !discord.Guild {
	guild := json2.decode[discord.Guild](g.client.rest.request(.patch, '/guilds/${id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	g.client.cache.store_guild(guild)
	return guild
}

// fetch_self returns the bot's own member in a guild.
pub fn (mut g GuildShorter) fetch_self(id discord.Snowflake, opts FetchOptions) !discord.Member {
	return g.client.members.fetch(id, g.client.bot_id()!, opts)
}

// widget_url is the address of the guild's widget image; `style` is shield (when empty) or
// banner1 to banner4.
pub fn (g &GuildShorter) widget_url(id discord.Snowflake, style string) string {
	url := '${rest.api_base}/guilds/${id}/widget.png'
	return if style == '' { url } else { '${url}?style=${style}' }
}

@[params]
pub struct IncidentOptions {
pub:
	// ISO 8601, at most 24 hours ahead; null lifts the measure.
	invites_disabled_until ?discord.Nullable[string]
	dms_disabled_until     ?discord.Nullable[string]
	reason                 string @[skip] // written to the audit log
}

// incidents pauses new invites or direct messages between members, or lifts the pause.
pub fn (mut g GuildShorter) incidents(id discord.Snowflake, opts IncidentOptions) !discord.IncidentActions {
	if opts.invites_disabled_until == none && opts.dms_disabled_until == none {
		return error('veyfert: incidents needs invites_disabled_until or dms_disabled_until')
	}
	return json2.decode[discord.IncidentActions](g.client.rest.request(.put,
		'/guilds/${id}/incident-actions',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

@[params]
pub struct SearchMessages {
pub:
	content      string
	author_id    []discord.Snowflake
	mentions     []discord.Snowflake
	channel_id   []discord.Snowflake
	has          []string // link, embed, file, image, video, sound, sticker, poll, snapshot
	pinned       ?bool
	max_id       ?discord.Snowflake
	min_id       ?discord.Snowflake
	limit        int = 25 // 1 to 25
	offset       int
	sort_by      string // timestamp (default) or relevance
	sort_order   string // desc (default) or asc
	include_nsfw bool
}

// search_messages searches the messages of a guild. While Discord indexes a guild it answers
// with no results and `doing_deep_historical_index`.
pub fn (mut g GuildShorter) search_messages(id discord.Snowflake, opts SearchMessages) !discord.MessageSearch {
	mut q := ['limit=${opts.limit}']
	if opts.content != '' {
		q << 'content=${urllib.query_escape(opts.content)}'
	}
	for a in opts.author_id {
		q << 'author_id=${a}'
	}
	for m in opts.mentions {
		q << 'mentions=${m}'
	}
	for c in opts.channel_id {
		q << 'channel_id=${c}'
	}
	for h in opts.has {
		q << 'has=${h}'
	}
	if pinned := opts.pinned {
		q << 'pinned=${pinned}'
	}
	if id_ := opts.max_id {
		q << 'max_id=${id_}'
	}
	if id_ := opts.min_id {
		q << 'min_id=${id_}'
	}
	if opts.offset > 0 {
		q << 'offset=${opts.offset}'
	}
	if opts.sort_by != '' {
		q << 'sort_by=${opts.sort_by}'
	}
	if opts.sort_order != '' {
		q << 'sort_order=${opts.sort_order}'
	}
	if opts.include_nsfw {
		q << 'include_nsfw=true'
	}
	return json2.decode[discord.MessageSearch](g.client.rest.request(.get,
		'/guilds/${id}/messages/search',
		query: q.join('&')
	)!)!
}

// AuditLogShorter reads the audit log: `c.guilds.audit.fetch(guild_id)`.
pub struct AuditLogShorter {
mut:
	client &Client = unsafe { nil }
}

@[params]
pub struct AuditLogQuery {
pub:
	user_id     ?discord.Snowflake
	action_type ?int
	before      ?discord.Snowflake
	after       ?discord.Snowflake
	limit       int = 50 // 1 to 100
}

pub fn (mut a AuditLogShorter) fetch(guild_id discord.Snowflake, opts AuditLogQuery) !discord.AuditLog {
	if opts.limit < 1 || opts.limit > 100 {
		return error('veyfert: an audit log page has 1 to 100 entries, not ${opts.limit}')
	}
	mut q := ['limit=${opts.limit}']
	if id := opts.user_id {
		q << 'user_id=${id}'
	}
	if t := opts.action_type {
		q << 'action_type=${t}'
	}
	if id := opts.before {
		q << 'before=${id}'
	}
	if id := opts.after {
		q << 'after=${id}'
	}
	return json2.decode[discord.AuditLog](a.client.rest.request(.get,
		'/guilds/${guild_id}/audit-logs',
		query: q.join('&')
	)!)!
}

// OnboardingShorter reads and changes what new members answer: `c.guilds.onboarding`.
pub struct OnboardingShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut o OnboardingShorter) fetch(guild_id discord.Snowflake) !discord.Onboarding {
	return json2.decode[discord.Onboarding](o.client.rest.request(.get, '/guilds/${guild_id}/onboarding')!)!
}

pub struct OnboardingPromptData {
pub:
	id            discord.Snowflake // any new ID for a new prompt
	kind          int @[json: 'type'] // 0 multiple choice, 1 dropdown
	options       []OnboardingOptionData
	title         string
	single_select bool
	required      bool
	in_onboarding bool
}

pub struct OnboardingOptionData {
pub:
	id             ?discord.Snowflake
	channel_ids    []discord.Snowflake
	role_ids       []discord.Snowflake
	emoji_id       ?discord.Snowflake
	emoji_name     ?string
	emoji_animated ?bool
	title          string
	description    ?string
}

@[params]
pub struct OnboardingOptions {
pub:
	prompts             ?[]OnboardingPromptData
	default_channel_ids ?[]discord.Snowflake
	enabled             ?bool
	mode                ?int // 0 default, 1 advanced
	reason              string @[skip] // written to the audit log
}

pub fn (mut o OnboardingShorter) edit(guild_id discord.Snowflake, opts OnboardingOptions) !discord.Onboarding {
	return json2.decode[discord.Onboarding](o.client.rest.request(.put,
		'/guilds/${guild_id}/onboarding',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

// WelcomeShorter reads and changes the welcome screen: `c.guilds.welcome`.
pub struct WelcomeShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut w WelcomeShorter) fetch(guild_id discord.Snowflake) !discord.WelcomeScreen {
	return json2.decode[discord.WelcomeScreen](w.client.rest.request(.get, '/guilds/${guild_id}/welcome-screen')!)!
}

@[params]
pub struct WelcomeOptions {
pub:
	enabled          ?bool
	welcome_channels ?[]discord.WelcomeChannel
	description      ?discord.Nullable[string]
	reason           string @[skip] // written to the audit log
}

pub fn (mut w WelcomeShorter) edit(guild_id discord.Snowflake, opts WelcomeOptions) !discord.WelcomeScreen {
	return json2.decode[discord.WelcomeScreen](w.client.rest.request(.patch,
		'/guilds/${guild_id}/welcome-screen',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

// WidgetShorter reads and changes the guild widget: `c.guilds.widget`.
pub struct WidgetShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut w WidgetShorter) settings(guild_id discord.Snowflake) !discord.WidgetSettings {
	return json2.decode[discord.WidgetSettings](w.client.rest.request(.get, '/guilds/${guild_id}/widget')!)!
}

@[params]
pub struct WidgetOptions {
pub:
	enabled    ?bool
	channel_id ?discord.Nullable[discord.Snowflake] // where the widget's invite leads
	reason     string @[skip] // written to the audit log
}

pub fn (mut w WidgetShorter) edit(guild_id discord.Snowflake, opts WidgetOptions) !discord.WidgetSettings {
	return json2.decode[discord.WidgetSettings](w.client.rest.request(.patch,
		'/guilds/${guild_id}/widget',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

// fetch returns the public widget: online members and voice channels.
pub fn (mut w WidgetShorter) fetch(guild_id discord.Snowflake) !discord.Widget {
	return json2.decode[discord.Widget](w.client.rest.request(.get, '/guilds/${guild_id}/widget.json')!)!
}

// image downloads the widget as a PNG; `style` is shield (when empty) or banner1 to banner4.
pub fn (mut w WidgetShorter) image(guild_id discord.Snowflake, style string) ![]u8 {
	return w.client.rest.request(.get, '/guilds/${guild_id}/widget.png',
		query: if style == '' { '' } else { 'style=${style}' }
	)!.bytes()
}

// AutoModerationShorter manages auto moderation rules: `c.guilds.moderation`.
pub struct AutoModerationShorter {
mut:
	client &Client = unsafe { nil }
}

@[params]
pub struct AutoModerationOptions {
pub:
	name             ?string
	event_type       ?int // 1 message send, 2 member update
	trigger_type     ?int // set when creating
	trigger_metadata ?discord.AutoModerationTrigger
	actions          ?[]discord.AutoModerationAction
	enabled          ?bool
	exempt_roles     ?[]discord.Snowflake
	exempt_channels  ?[]discord.Snowflake
	reason           string @[skip] // written to the audit log
}

pub fn (mut a AutoModerationShorter) list(guild_id discord.Snowflake) ![]discord.AutoModerationRule {
	return json2.decode[[]discord.AutoModerationRule](a.client.rest.request(.get, '/guilds/${guild_id}/auto-moderation/rules')!)!
}

pub fn (mut a AutoModerationShorter) create(guild_id discord.Snowflake, opts AutoModerationOptions) !discord.AutoModerationRule {
	return json2.decode[discord.AutoModerationRule](a.client.rest.request(.post,
		'/guilds/${guild_id}/auto-moderation/rules',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut a AutoModerationShorter) fetch(guild_id discord.Snowflake, rule_id discord.Snowflake) !discord.AutoModerationRule {
	return json2.decode[discord.AutoModerationRule](a.client.rest.request(.get, '/guilds/${guild_id}/auto-moderation/rules/${rule_id}')!)!
}

pub fn (mut a AutoModerationShorter) edit(guild_id discord.Snowflake, rule_id discord.Snowflake, opts AutoModerationOptions) !discord.AutoModerationRule {
	return json2.decode[discord.AutoModerationRule](a.client.rest.request(.patch,
		'/guilds/${guild_id}/auto-moderation/rules/${rule_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut a AutoModerationShorter) delete(guild_id discord.Snowflake, rule_id discord.Snowflake, reason string) ! {
	a.client.rest.request(.delete, '/guilds/${guild_id}/auto-moderation/rules/${rule_id}',
		reason: reason
	)!
}

// ScheduledEventShorter manages scheduled events: `c.guilds.events`.
pub struct ScheduledEventShorter {
mut:
	client &Client = unsafe { nil }
}

@[params]
pub struct ScheduledEventOptions {
pub:
	name                 ?string
	channel_id           ?discord.Nullable[discord.Snowflake] // stage and voice events
	entity_metadata      ?discord.ScheduledEventMetadata      // the location of external events
	privacy_level        int = 2 // the only level Discord accepts
	scheduled_start_time ?string // ISO 8601
	scheduled_end_time   ?string // required for external events
	description          ?discord.Nullable[string]
	entity_type          ?int                      // 1 stage instance, 2 voice, 3 external
	status               ?int                      // when editing: 2 starts it, 3 ends it, 4 cancels it
	image                ?discord.Nullable[string] // File.data_uri()
	recurrence_rule      ?discord.RawJson
	reason               string @[skip] // written to the audit log
}

pub fn (mut e ScheduledEventShorter) list(guild_id discord.Snowflake, with_user_count bool) ![]discord.ScheduledEvent {
	return json2.decode[[]discord.ScheduledEvent](e.client.rest.request(.get,
		'/guilds/${guild_id}/scheduled-events',
		query: 'with_user_count=${with_user_count}'
	)!)!
}

pub fn (mut e ScheduledEventShorter) create(guild_id discord.Snowflake, opts ScheduledEventOptions) !discord.ScheduledEvent {
	return json2.decode[discord.ScheduledEvent](e.client.rest.request(.post,
		'/guilds/${guild_id}/scheduled-events',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut e ScheduledEventShorter) fetch(guild_id discord.Snowflake, event_id discord.Snowflake, with_user_count bool) !discord.ScheduledEvent {
	return json2.decode[discord.ScheduledEvent](e.client.rest.request(.get,
		'/guilds/${guild_id}/scheduled-events/${event_id}',
		query: 'with_user_count=${with_user_count}'
	)!)!
}

pub fn (mut e ScheduledEventShorter) edit(guild_id discord.Snowflake, event_id discord.Snowflake, opts ScheduledEventOptions) !discord.ScheduledEvent {
	return json2.decode[discord.ScheduledEvent](e.client.rest.request(.patch,
		'/guilds/${guild_id}/scheduled-events/${event_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut e ScheduledEventShorter) delete(guild_id discord.Snowflake, event_id discord.Snowflake, reason string) ! {
	e.client.rest.request(.delete, '/guilds/${guild_id}/scheduled-events/${event_id}',
		reason: reason
	)!
}

@[params]
pub struct SubscribersQuery {
pub:
	limit       int = 100 // 1 to 100
	with_member bool
	before      ?discord.Snowflake
	after       ?discord.Snowflake
}

// subscribers returns the users interested in an event.
pub fn (mut e ScheduledEventShorter) subscribers(guild_id discord.Snowflake, event_id discord.Snowflake, opts SubscribersQuery) ![]discord.ScheduledEventUser {
	mut q := ['limit=${opts.limit}', 'with_member=${opts.with_member}']
	if id := opts.before {
		q << 'before=${id}'
	}
	if id := opts.after {
		q << 'after=${id}'
	}
	users := json2.decode[[]discord.ScheduledEventUser](e.client.rest.request(.get,
		'/guilds/${guild_id}/scheduled-events/${event_id}/users',
		query: q.join('&')
	)!)!
	for u in users {
		e.client.cache.store_user(u.user)
	}
	return users
}

// StickerShorter manages the custom stickers of a guild: `c.guilds.stickers`.
pub struct StickerShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut s StickerShorter) list(guild_id discord.Snowflake, opts FetchOptions) ![]discord.Sticker {
	if !opts.force && s.client.cache.options.stickers && s.client.cache.guild(guild_id) != none {
		return s.client.cache.stickers(guild_id)
	}
	stickers := json2.decode[[]discord.Sticker](s.client.rest.request(.get, '/guilds/${guild_id}/stickers')!)!
	for st in stickers {
		s.client.cache.store_sticker(guild_id, st)
	}
	return stickers
}

pub fn (mut s StickerShorter) fetch(guild_id discord.Snowflake, sticker_id discord.Snowflake, opts FetchOptions) !discord.Sticker {
	if !opts.force {
		if cached := s.client.cache.sticker(guild_id, sticker_id) {
			return cached
		}
	}
	sticker := json2.decode[discord.Sticker](s.client.rest.request(.get, '/guilds/${guild_id}/stickers/${sticker_id}')!)!
	s.client.cache.store_sticker(guild_id, sticker)
	return sticker
}

@[params]
pub struct StickerCreate {
pub:
	name        string @[required] // 2 to 30 characters
	description string // empty or 2 to 100 characters
	tags        string @[required] // the emoji the sticker stands for
	reason      string // written to the audit log
}

// create uploads a PNG, APNG, GIF or Lottie JSON sticker of up to 512 KiB.
pub fn (mut s StickerShorter) create(guild_id discord.Snowflake, file discord.File, opts StickerCreate) !discord.Sticker {
	sticker := json2.decode[discord.Sticker](s.client.rest.request(.post,
		'/guilds/${guild_id}/stickers',
		form:       {
			'name':        opts.name
			'description': opts.description
			'tags':        opts.tags
		}
		file_field: 'file'
		files:      [file]
		reason:     opts.reason
	)!)!
	s.client.cache.store_sticker(guild_id, sticker)
	return sticker
}

@[params]
pub struct StickerOptions {
pub:
	name        ?string
	description ?discord.Nullable[string]
	tags        ?string
	reason      string @[skip] // written to the audit log
}

pub fn (mut s StickerShorter) edit(guild_id discord.Snowflake, sticker_id discord.Snowflake, opts StickerOptions) !discord.Sticker {
	sticker := json2.decode[discord.Sticker](s.client.rest.request(.patch,
		'/guilds/${guild_id}/stickers/${sticker_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	s.client.cache.store_sticker(guild_id, sticker)
	return sticker
}

pub fn (mut s StickerShorter) delete(guild_id discord.Snowflake, sticker_id discord.Snowflake, reason string) ! {
	s.client.rest.request(.delete, '/guilds/${guild_id}/stickers/${sticker_id}', reason: reason)!
	s.client.cache.forget_sticker(guild_id, sticker_id)
}

// Channels.

pub struct ChannelPosition {
pub:
	id               discord.Snowflake
	position         ?discord.Nullable[int]
	lock_permissions ?discord.Nullable[bool] // take the permissions of the new parent
	parent_id        ?discord.Nullable[discord.Snowflake]
}

// edit_positions moves the channels of a guild; the CHANNEL_UPDATE events that follow update
// the cache.
pub fn (mut ch ChannelShorter) edit_positions(guild_id discord.Snowflake, positions []ChannelPosition, reason string) ! {
	ch.client.rest.request(.patch, '/guilds/${guild_id}/channels',
		body:   json2.encode(positions)
		reason: reason
	)!
}

struct FollowBody {
	webhook_channel_id discord.Snowflake
}

// add_follower makes `webhook_channel_id` receive the posts of an announcement channel.
pub fn (mut ch ChannelShorter) add_follower(channel_id discord.Snowflake, webhook_channel_id discord.Snowflake, reason string) !discord.FollowedChannel {
	return json2.decode[discord.FollowedChannel](ch.client.rest.request(.post,
		'/channels/${channel_id}/followers',
		body:   json2.encode(FollowBody{webhook_channel_id})
		reason: reason
	)!)!
}

// cached_guild_channel returns a cached guild channel, which the permission helpers need.
fn (mut ch ChannelShorter) cached_guild_channel(channel_id discord.Snowflake) !(discord.Channel, discord.Snowflake) {
	channel := ch.client.cache.channel(channel_id) or {
		return error('veyfert: channel ${channel_id} is not in the cache')
	}
	guild_id := channel.guild_id or { return error('veyfert: channel ${channel_id} is not in a guild') }
	return channel, guild_id
}

// member_permissions works out a member's permissions in a channel from the cache.
pub fn (mut ch ChannelShorter) member_permissions(channel_id discord.Snowflake, member discord.Member) !discord.Permissions {
	_, guild_id := ch.cached_guild_channel(channel_id)!
	user := member.user or { return error('veyfert: the member has no user') }
	return ch.client.cache.permissions(guild_id, user.id, member.roles, channel_id) or {
		error('veyfert: guild ${guild_id} is not in the cache')
	}
}

// role_permissions works out what a role (with @everyone) can do in a channel, from the cache.
pub fn (mut ch ChannelShorter) role_permissions(channel_id discord.Snowflake, role_id discord.Snowflake) !discord.Permissions {
	_, guild_id := ch.cached_guild_channel(channel_id)!
	return ch.client.cache.permissions(guild_id, discord.Snowflake{}, [role_id], channel_id) or {
		error('veyfert: guild ${guild_id} is not in the cache')
	}
}

// ChannelOverwrites are the overwrites of a channel that apply to one member.
pub struct ChannelOverwrites {
pub:
	everyone ?discord.Overwrite
	roles    []discord.Overwrite
	member   ?discord.Overwrite
}

pub fn (mut ch ChannelShorter) overwrites_for(channel_id discord.Snowflake, member discord.Member) !ChannelOverwrites {
	channel, guild_id := ch.cached_guild_channel(channel_id)!
	user := member.user or { return error('veyfert: the member has no user') }
	mut everyone := ?discord.Overwrite(none)
	mut roles := []discord.Overwrite{}
	mut own := ?discord.Overwrite(none)
	for o in channel.permission_overwrites {
		if o.id == guild_id {
			everyone = o
		} else if o.kind == 0 && o.id in member.roles {
			roles << o
		} else if o.kind == 1 && o.id == user.id {
			own = o
		}
	}
	return ChannelOverwrites{
		everyone: everyone
		roles:    roles
		member:   own
	}
}

// fetch_member_permissions asks Discord for a member's permissions in a channel.
pub fn (mut ch ChannelShorter) fetch_member_permissions(channel_id discord.Snowflake, user_id discord.Snowflake) !discord.Permissions {
	return permissions_of(ch.client.rest.request(.get, '/channels/${channel_id}/permissions/member/${user_id}')!)
}

// fetch_role_permissions asks Discord for a role's permissions in a channel.
pub fn (mut ch ChannelShorter) fetch_role_permissions(channel_id discord.Snowflake, role_id discord.Snowflake) !discord.Permissions {
	return permissions_of(ch.client.rest.request(.get, '/channels/${channel_id}/permissions/role/${role_id}')!)
}

struct VoiceStatusBody {
	status string
}

// set_voice_status sets the status line of a voice channel the bot is in; empty clears it.
pub fn (mut ch ChannelShorter) set_voice_status(channel_id discord.Snowflake, status string, reason string) ! {
	ch.client.rest.request(.put, '/channels/${channel_id}/voice-status',
		body:   json2.encode(VoiceStatusBody{status})
		reason: reason
	)!
}

// Members.

// resolve finds a member from a mention, an ID or, failing those, a username or nickname search.
pub fn (mut m MemberShorter) resolve(guild_id discord.Snowflake, text string) !discord.Member {
	t := text.trim_space()
	if t.starts_with('<@') && t.ends_with('>') {
		if id := discord.Snowflake.parse(t.trim_left('<@!').trim_right('>')) {
			return m.fetch(guild_id, id)
		}
	}
	if t.len >= 17 && t.len <= 20 && t.bytes().all(it.is_digit()) {
		return m.fetch(guild_id, discord.Snowflake.parse(t)!)
	}
	found := m.search(guild_id, t, 1)!
	return found[0] or { error('veyfert: no member matches "${t}"') }
}

@[params]
pub struct AddMember {
pub:
	access_token string @[required] // an OAuth2 token of the user, with the guilds.join scope
	nick         ?string
	roles        ?[]discord.Snowflake
	mute         ?bool
	deaf         ?bool
}

// add puts a user in a guild with their OAuth2 token; it returns the member, also when they
// already were in the guild.
pub fn (mut m MemberShorter) add(guild_id discord.Snowflake, user_id discord.Snowflake, opts AddMember) !discord.Member {
	text := m.client.rest.request(.put, '/guilds/${guild_id}/members/${user_id}',
		body: json2.encode(opts)
	)!
	if text.trim_space() == '' {
		return m.fetch(guild_id, user_id)
	}
	return m.keep(guild_id, json2.decode[discord.Member](text)!)
}

// roles returns the roles of a member, in the member's order.
pub fn (mut m MemberShorter) roles(guild_id discord.Snowflake, user_id discord.Snowflake, opts FetchOptions) ![]discord.Role {
	member := m.fetch(guild_id, user_id, opts)!
	all := m.client.roles.list(guild_id, opts)!
	mut out := []discord.Role{cap: member.roles.len}
	for id in member.roles {
		for r in all {
			if r.id == id {
				out << r
			}
		}
	}
	return out
}

// sort_roles returns the roles of a member, highest first.
pub fn (mut m MemberShorter) sort_roles(guild_id discord.Snowflake, user_id discord.Snowflake, opts FetchOptions) ![]discord.Role {
	mut roles := m.roles(guild_id, user_id, opts)!
	roles.sort(a.position > b.position)
	return roles
}

// permissions works out a member's guild permissions from the cache.
pub fn (mut m MemberShorter) permissions(guild_id discord.Snowflake, user_id discord.Snowflake, opts FetchOptions) !discord.Permissions {
	member := m.fetch(guild_id, user_id, opts)!
	return m.client.cache.permissions(guild_id, user_id, member.roles, discord.Snowflake{}) or {
		error('veyfert: guild ${guild_id} is not in the cache')
	}
}

// fetch_permissions asks Discord for a member's guild permissions.
pub fn (mut m MemberShorter) fetch_permissions(guild_id discord.Snowflake, user_id discord.Snowflake) !discord.Permissions {
	return permissions_of(m.client.rest.request(.get, '/guilds/${guild_id}/permissions/member/${user_id}')!)
}

// presence is a member's presence from the cache, which needs the GUILD_PRESENCES intent.
pub fn (mut m MemberShorter) presence(guild_id discord.Snowflake, user_id discord.Snowflake) ?discord.PresenceUpdate {
	return m.client.cache.presence(guild_id, user_id)
}

// voice returns a member's voice state: from the cache, or from Discord.
pub fn (mut m MemberShorter) voice(guild_id discord.Snowflake, user_id discord.Snowflake, opts FetchOptions) !discord.VoiceState {
	if !opts.force {
		if cached := m.client.cache.voice_state(guild_id, user_id) {
			return cached
		}
	}
	return json2.decode[discord.VoiceState](m.client.rest.request(.get, '/guilds/${guild_id}/voice-states/${user_id}')!)!
}

// has_timeout tells whether a member is timed out now.
pub fn (m &MemberShorter) has_timeout(member discord.Member) bool {
	until := member.communication_disabled_until or { return false }
	return (time.parse_iso8601(until) or { return false }) > time.now()
}

// Roles.

// member_counts returns how many members have each role, by role ID.
pub fn (mut r RoleShorter) member_counts(guild_id discord.Snowflake) !map[string]int {
	return json2.decode[map[string]int](r.client.rest.request(.get, '/guilds/${guild_id}/roles/member-counts')!)!
}

// fetch_permissions asks Discord for a role's guild permissions, with those of @everyone.
pub fn (mut r RoleShorter) fetch_permissions(guild_id discord.Snowflake, role_id discord.Snowflake) !discord.Permissions {
	return permissions_of(r.client.rest.request(.get, '/guilds/${guild_id}/permissions/role/${role_id}')!)
}

pub struct RolePosition {
pub:
	id       discord.Snowflake
	position ?discord.Nullable[int]
}

// edit_positions moves roles and returns every role of the guild.
pub fn (mut r RoleShorter) edit_positions(guild_id discord.Snowflake, positions []RolePosition, reason string) ![]discord.Role {
	roles := json2.decode[[]discord.Role](r.client.rest.request(.patch, '/guilds/${guild_id}/roles',
		body:   json2.encode(positions)
		reason: reason
	)!)!
	r.client.cache.store_roles(guild_id, roles)
	return roles
}

// Bans.

// create bans a user, as `c.members.ban` does.
pub fn (mut b BanShorter) create(guild_id discord.Snowflake, user_id discord.Snowflake, delete_messages time.Duration, reason string) ! {
	b.client.members.ban(guild_id, user_id, delete_messages, reason)!
}

// remove lifts a ban, as `c.members.unban` does.
pub fn (mut b BanShorter) remove(guild_id discord.Snowflake, user_id discord.Snowflake, reason string) ! {
	b.client.members.unban(guild_id, user_id, reason)!
}

struct BulkBanBody {
	user_ids               []discord.Snowflake
	delete_message_seconds int
}

// bulk_create bans up to 200 users at once.
pub fn (mut b BanShorter) bulk_create(guild_id discord.Snowflake, user_ids []discord.Snowflake, delete_messages time.Duration, reason string) !discord.BulkBan {
	if user_ids.len < 1 || user_ids.len > 200 {
		return error('veyfert: a bulk ban takes 1 to 200 users, not ${user_ids.len}')
	}
	result := json2.decode[discord.BulkBan](b.client.rest.request(.post,
		'/guilds/${guild_id}/bulk-ban',
		body:   json2.encode(BulkBanBody{user_ids, int(delete_messages / time.second)})
		reason: reason
	)!)!
	for id in result.banned_users {
		b.client.cache.forget_member(guild_id, id)
		b.client.cache.store_ban(guild_id, id, true)
	}
	return result
}

// Emojis.

pub fn (mut e EmojiShorter) fetch(guild_id discord.Snowflake, emoji_id discord.Snowflake, opts FetchOptions) !discord.GuildEmoji {
	if !opts.force {
		for cached in e.client.cache.emojis(guild_id) {
			if (cached.id or { discord.Snowflake{} }) == emoji_id {
				return cached
			}
		}
	}
	emoji := json2.decode[discord.GuildEmoji](e.client.rest.request(.get, '/guilds/${guild_id}/emojis/${emoji_id}')!)!
	e.client.cache.store_emoji(guild_id, emoji)
	return emoji
}

@[params]
pub struct EmojiOptions {
pub:
	name   ?string
	roles  ?[]discord.Snowflake // who can use it; empty lets everyone
	reason string @[skip] // written to the audit log
}

pub fn (mut e EmojiShorter) edit(guild_id discord.Snowflake, emoji_id discord.Snowflake, opts EmojiOptions) !discord.GuildEmoji {
	emoji := json2.decode[discord.GuildEmoji](e.client.rest.request(.patch,
		'/guilds/${guild_id}/emojis/${emoji_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	e.client.cache.store_emoji(guild_id, emoji)
	return emoji
}
