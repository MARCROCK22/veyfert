module veyfert

import json2
import time
import veyfert.discord

// The application-side shorters that Seyfert has and veyfert lacked: the application itself,
// monetization, interactions by token, invites, soundboard, stages, templates and voice states;
// and more of messages, threads, users and webhooks.

// ApplicationShorter manages the bot's application: `c.application`.
pub struct ApplicationShorter {
mut:
	client &Client = unsafe { nil }
}

struct EmojiList {
	items []discord.GuildEmoji
}

// list_emojis returns the application's emojis, which the bot can use anywhere.
pub fn (mut a ApplicationShorter) list_emojis() ![]discord.GuildEmoji {
	return json2.decode[EmojiList](a.client.rest.request(.get, '/applications/${a.client.application_id()!}/emojis')!)!.items
}

pub fn (mut a ApplicationShorter) fetch_emoji(emoji_id discord.Snowflake) !discord.GuildEmoji {
	return json2.decode[discord.GuildEmoji](a.client.rest.request(.get, '/applications/${a.client.application_id()!}/emojis/${emoji_id}')!)!
}

struct AppEmojiBody {
	name  string
	image string
}

pub fn (mut a ApplicationShorter) create_emoji(name string, image discord.File) !discord.GuildEmoji {
	return json2.decode[discord.GuildEmoji](a.client.rest.request(.post,
		'/applications/${a.client.application_id()!}/emojis',
		body: json2.encode(AppEmojiBody{name, image.data_uri()})
	)!)!
}

struct NameBody {
	name string
}

pub fn (mut a ApplicationShorter) edit_emoji(emoji_id discord.Snowflake, name string) !discord.GuildEmoji {
	return json2.decode[discord.GuildEmoji](a.client.rest.request(.patch,
		'/applications/${a.client.application_id()!}/emojis/${emoji_id}',
		body: json2.encode(NameBody{name})
	)!)!
}

pub fn (mut a ApplicationShorter) delete_emoji(emoji_id discord.Snowflake) ! {
	a.client.rest.request(.delete, '/applications/${a.client.application_id()!}/emojis/${emoji_id}')!
}

@[params]
pub struct EntitlementQuery {
pub:
	user_id         ?discord.Snowflake
	sku_ids         []discord.Snowflake
	before          ?discord.Snowflake
	after           ?discord.Snowflake
	limit           int = 100 // 1 to 100
	guild_id        ?discord.Snowflake
	exclude_ended   bool
	exclude_deleted bool = true
}

pub fn (mut a ApplicationShorter) list_entitlements(opts EntitlementQuery) ![]discord.Entitlement {
	mut q := ['limit=${opts.limit}', 'exclude_ended=${opts.exclude_ended}',
		'exclude_deleted=${opts.exclude_deleted}']
	if id := opts.user_id {
		q << 'user_id=${id}'
	}
	if opts.sku_ids.len > 0 {
		q << 'sku_ids=${opts.sku_ids.map(it.str()).join(',')}'
	}
	if id := opts.before {
		q << 'before=${id}'
	}
	if id := opts.after {
		q << 'after=${id}'
	}
	if id := opts.guild_id {
		q << 'guild_id=${id}'
	}
	return json2.decode[[]discord.Entitlement](a.client.rest.request(.get,
		'/applications/${a.client.application_id()!}/entitlements',
		query: q.join('&')
	)!)!
}

pub fn (mut a ApplicationShorter) fetch_entitlement(entitlement_id discord.Snowflake) !discord.Entitlement {
	return json2.decode[discord.Entitlement](a.client.rest.request(.get, '/applications/${a.client.application_id()!}/entitlements/${entitlement_id}')!)!
}

// consume marks a consumable entitlement as used.
pub fn (mut a ApplicationShorter) consume_entitlement(entitlement_id discord.Snowflake) ! {
	a.client.rest.request(.post, '/applications/${a.client.application_id()!}/entitlements/${entitlement_id}/consume')!
}

struct TestEntitlementBody {
	sku_id     discord.Snowflake
	owner_id   discord.Snowflake
	owner_type int
}

// create_test_entitlement grants a SKU for free, to test premium features; `owner_type` is 1 for a
// guild and 2 for a user.
pub fn (mut a ApplicationShorter) create_test_entitlement(sku_id discord.Snowflake, owner_id discord.Snowflake, owner_type int) !discord.Entitlement {
	return json2.decode[discord.Entitlement](a.client.rest.request(.post,
		'/applications/${a.client.application_id()!}/entitlements',
		body: json2.encode(TestEntitlementBody{sku_id, owner_id, owner_type})
	)!)!
}

pub fn (mut a ApplicationShorter) delete_test_entitlement(entitlement_id discord.Snowflake) ! {
	a.client.rest.request(.delete, '/applications/${a.client.application_id()!}/entitlements/${entitlement_id}')!
}

pub fn (mut a ApplicationShorter) list_skus() ![]discord.Sku {
	return json2.decode[[]discord.Sku](a.client.rest.request(.get, '/applications/${a.client.application_id()!}/skus')!)!
}

pub fn (mut a ApplicationShorter) fetch() !discord.Application {
	return json2.decode[discord.Application](a.client.rest.request(.get, '/applications/@me')!)!
}

@[params]
pub struct ApplicationOptions {
pub:
	custom_install_url                ?string
	description                       ?string
	role_connections_verification_url ?string
	interactions_endpoint_url         ?string
	install_params                    ?discord.RawJson
	integration_types_config          ?discord.RawJson
	flags                             ?int
	icon                              ?discord.Nullable[string] // File.data_uri()
	cover_image                       ?discord.Nullable[string]
	tags                              ?[]string
	event_webhooks_url                ?string
	event_webhooks_status             ?int
	event_webhooks_types              ?[]string
}

pub fn (mut a ApplicationShorter) edit(opts ApplicationOptions) !discord.Application {
	return json2.decode[discord.Application](a.client.rest.request(.patch, '/applications/@me',
		body: json2.encode(opts)
	)!)!
}

pub fn (mut a ApplicationShorter) activity_instance(instance_id string) !discord.ActivityInstance {
	return json2.decode[discord.ActivityInstance](a.client.rest.request(.get, '/applications/${a.client.application_id()!}/activity-instances/${instance_id}')!)!
}

// MonetizationShorter reads SKUs and subscriptions: `c.monetization`.
pub struct MonetizationShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut m MonetizationShorter) list_skus() ![]discord.Sku {
	return m.client.application.list_skus()
}

// fetch_sku finds one of the application's SKUs; Discord has no endpoint for a single SKU.
pub fn (mut m MonetizationShorter) fetch_sku(sku_id discord.Snowflake) !discord.Sku {
	for sku in m.list_skus()! {
		if sku.id == sku_id {
			return sku
		}
	}
	return error('veyfert: the application has no SKU ${sku_id}')
}

@[params]
pub struct SubscriptionQuery {
pub:
	before  ?discord.Snowflake
	after   ?discord.Snowflake
	limit   int = 50 // 1 to 100
	user_id ?discord.Snowflake
}

pub fn (mut m MonetizationShorter) subscriptions(sku_id discord.Snowflake, opts SubscriptionQuery) ![]discord.Subscription {
	mut q := ['limit=${opts.limit}']
	if id := opts.before {
		q << 'before=${id}'
	}
	if id := opts.after {
		q << 'after=${id}'
	}
	if id := opts.user_id {
		q << 'user_id=${id}'
	}
	return json2.decode[[]discord.Subscription](m.client.rest.request(.get,
		'/skus/${sku_id}/subscriptions',
		query: q.join('&')
	)!)!
}

pub fn (mut m MonetizationShorter) fetch_subscription(sku_id discord.Snowflake, subscription_id discord.Snowflake) !discord.Subscription {
	return json2.decode[discord.Subscription](m.client.rest.request(.get, '/skus/${sku_id}/subscriptions/${subscription_id}')!)!
}

// InteractionShorter answers interactions by ID and token, outside a context: `c.interactions`.
pub struct InteractionShorter {
mut:
	client &Client = unsafe { nil }
}

// reply sends the first answer: `kind` 4 is a message, 5 defers it, 6 defers an update and 7
// updates the component's message.
pub fn (mut i InteractionShorter) reply(interaction_id discord.Snowflake, token string, kind int, opts MessageOptions) ! {
	i.client.rest.request(.post, '/interactions/${interaction_id}/${token}/callback',
		body:  json2.encode(Callback[MessagePayload]{ kind: kind, data: message_payload(opts)! })
		files: opts.files
	)!
}

fn (mut i InteractionShorter) path(token string) !string {
	return '/webhooks/${i.client.application_id()!}/${token}'
}

pub fn (mut i InteractionShorter) fetch_response(token string, message_id discord.Snowflake) !discord.Message {
	return json2.decode[discord.Message](i.client.rest.request(.get, '${i.path(token)!}/messages/${message_id}')!)!
}

pub fn (mut i InteractionShorter) fetch_original(token string) !discord.Message {
	return json2.decode[discord.Message](i.client.rest.request(.get, '${i.path(token)!}/messages/@original')!)!
}

pub fn (mut i InteractionShorter) edit_message(token string, message_id discord.Snowflake, opts MessageOptions) !discord.Message {
	return json2.decode[discord.Message](i.client.rest.request(.patch,
		'${i.path(token)!}/messages/${message_id}',
		body:  json2.encode(message_payload(opts)!)
		files: opts.files
	)!)!
}

pub fn (mut i InteractionShorter) edit_original(token string, opts MessageOptions) !discord.Message {
	return json2.decode[discord.Message](i.client.rest.request(.patch,
		'${i.path(token)!}/messages/@original',
		body:  json2.encode(message_payload(opts)!)
		files: opts.files
	)!)!
}

pub fn (mut i InteractionShorter) delete_response(token string, message_id discord.Snowflake) ! {
	i.client.rest.request(.delete, '${i.path(token)!}/messages/${message_id}')!
}

pub fn (mut i InteractionShorter) delete_original(token string) ! {
	i.client.rest.request(.delete, '${i.path(token)!}/messages/@original')!
}

pub fn (mut i InteractionShorter) followup(token string, opts MessageOptions) !discord.Message {
	return json2.decode[discord.Message](i.client.rest.request(.post, i.path(token)!,
		body:  json2.encode(message_payload(opts)!)
		query: 'wait=true'
		files: opts.files
	)!)!
}

// InviteShorter reads, creates and deletes invites: `c.invites`.
pub struct InviteShorter {
mut:
	client &Client = unsafe { nil }
}

@[params]
pub struct InviteQuery {
pub:
	with_counts              bool = true
	guild_scheduled_event_id ?discord.Snowflake
}

pub fn (mut i InviteShorter) fetch(code string, opts InviteQuery) !discord.Invite {
	mut query := 'with_counts=${opts.with_counts}'
	if id := opts.guild_scheduled_event_id {
		query += '&guild_scheduled_event_id=${id}'
	}
	return json2.decode[discord.Invite](i.client.rest.request(.get, '/invites/${code}',
		query: query
	)!)!
}

pub fn (mut i InviteShorter) delete(code string, reason string) !discord.Invite {
	return json2.decode[discord.Invite](i.client.rest.request(.delete, '/invites/${code}',
		reason: reason
	)!)!
}

@[params]
pub struct InviteOptions {
pub:
	max_age               ?int // seconds, 0 to 604800; 0 never expires
	max_uses              ?int // 0 to 100; 0 is unlimited
	temporary             ?bool
	unique                ?bool
	target_type           ?int // 1 a stream, 2 an embedded application
	target_user_id        ?discord.Snowflake
	target_application_id ?discord.Snowflake
	reason                string @[skip] // written to the audit log
}

pub fn (mut i InviteShorter) create(channel_id discord.Snowflake, opts InviteOptions) !discord.Invite {
	return json2.decode[discord.Invite](i.client.rest.request(.post,
		'/channels/${channel_id}/invites',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut i InviteShorter) list_channel(channel_id discord.Snowflake) ![]discord.Invite {
	return json2.decode[[]discord.Invite](i.client.rest.request(.get, '/channels/${channel_id}/invites')!)!
}

pub fn (mut i InviteShorter) list_guild(guild_id discord.Snowflake) ![]discord.Invite {
	return json2.decode[[]discord.Invite](i.client.rest.request(.get, '/guilds/${guild_id}/invites')!)!
}

// target_users returns who may accept an invite that only some users can use; Discord sends a
// CSV with one ID per line under a header.
pub fn (mut i InviteShorter) target_users(code string) ![]discord.Snowflake {
	csv := i.client.rest.request(.get, '/invites/${code}/target-users')!
	mut ids := []discord.Snowflake{}
	for line in csv.split_into_lines() {
		if id := discord.Snowflake.parse(line.trim_space()) {
			ids << id
		}
	}
	return ids
}

// update_target_users replaces who may accept an invite; check the upload with `job_status`.
pub fn (mut i InviteShorter) update_target_users(code string, user_ids []discord.Snowflake) ! {
	csv := 'users\n' + user_ids.map(it.str()).join('\n')
	i.client.rest.request(.put, '/invites/${code}/target-users',
		file_field: 'target_users_file'
		files:      [discord.File{
			name:         'users.csv'
			data:         csv.bytes()
			content_type: 'text/csv'
		}]
	)!
}

pub fn (mut i InviteShorter) job_status(code string) !discord.InviteJobStatus {
	return json2.decode[discord.InviteJobStatus](i.client.rest.request(.get, '/invites/${code}/target-users/job-status')!)!
}

pub fn (mut i InviteShorter) add_target_user(code string, user_id discord.Snowflake) ! {
	i.client.rest.request(.put, '/invites/${code}/target-users/${user_id}')!
}

pub fn (mut i InviteShorter) remove_target_user(code string, user_id discord.Snowflake) ! {
	i.client.rest.request(.delete, '/invites/${code}/target-users/${user_id}')!
}

struct UserIdsBody {
	user_ids []discord.Snowflake
}

pub fn (mut i InviteShorter) bulk_add_target_users(code string, user_ids []discord.Snowflake) ! {
	i.client.rest.request(.post, '/invites/${code}/target-users/bulk-add',
		body: json2.encode(UserIdsBody{user_ids})
	)!
}

pub fn (mut i InviteShorter) bulk_remove_target_users(code string, user_ids []discord.Snowflake) ! {
	i.client.rest.request(.post, '/invites/${code}/target-users/bulk-delete',
		body: json2.encode(UserIdsBody{user_ids})
	)!
}

// SoundboardShorter plays and manages soundboard sounds: `c.soundboard`.
pub struct SoundboardShorter {
mut:
	client &Client = unsafe { nil }
}

// defaults returns the sounds every guild has.
pub fn (mut s SoundboardShorter) defaults() ![]discord.SoundboardSound {
	return json2.decode[[]discord.SoundboardSound](s.client.rest.request(.get, '/soundboard-default-sounds')!)!
}

@[params]
pub struct SendSound {
pub:
	source_guild_id ?discord.Snowflake // the guild of a sound from another guild
}

struct SendSoundBody {
	sound_id        discord.Snowflake
	source_guild_id ?discord.Snowflake
}

// send plays a sound in the voice channel the bot is in.
pub fn (mut s SoundboardShorter) send(channel_id discord.Snowflake, sound_id discord.Snowflake, opts SendSound) ! {
	s.client.rest.request(.post, '/channels/${channel_id}/send-soundboard-sound',
		body: json2.encode(SendSoundBody{sound_id, opts.source_guild_id})
	)!
}

struct SoundList {
	items []discord.SoundboardSound
}

pub fn (mut s SoundboardShorter) list(guild_id discord.Snowflake) ![]discord.SoundboardSound {
	return json2.decode[SoundList](s.client.rest.request(.get, '/guilds/${guild_id}/soundboard-sounds')!)!.items
}

pub fn (mut s SoundboardShorter) fetch(guild_id discord.Snowflake, sound_id discord.Snowflake) !discord.SoundboardSound {
	return json2.decode[discord.SoundboardSound](s.client.rest.request(.get, '/guilds/${guild_id}/soundboard-sounds/${sound_id}')!)!
}

@[params]
pub struct SoundCreate {
pub:
	name       string @[required]
	volume     ?f64 // 0 to 1
	emoji_id   ?discord.Snowflake
	emoji_name ?string
	reason     string // written to the audit log
}

struct SoundBody {
	name       string
	sound      string
	volume     ?f64
	emoji_id   ?discord.Snowflake
	emoji_name ?string
}

// create uploads an MP3 or OGG sound of up to 512 KiB and 5.2 seconds.
pub fn (mut s SoundboardShorter) create(guild_id discord.Snowflake, sound discord.File, opts SoundCreate) !discord.SoundboardSound {
	return json2.decode[discord.SoundboardSound](s.client.rest.request(.post,
		'/guilds/${guild_id}/soundboard-sounds',
		body:   json2.encode(SoundBody{opts.name, sound.data_uri(), opts.volume, opts.emoji_id, opts.emoji_name})
		reason: opts.reason
	)!)!
}

@[params]
pub struct SoundOptions {
pub:
	name       ?string
	volume     ?discord.Nullable[f64]
	emoji_id   ?discord.Nullable[discord.Snowflake]
	emoji_name ?discord.Nullable[string]
	reason     string @[skip] // written to the audit log
}

pub fn (mut s SoundboardShorter) edit(guild_id discord.Snowflake, sound_id discord.Snowflake, opts SoundOptions) !discord.SoundboardSound {
	return json2.decode[discord.SoundboardSound](s.client.rest.request(.patch,
		'/guilds/${guild_id}/soundboard-sounds/${sound_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
}

pub fn (mut s SoundboardShorter) delete(guild_id discord.Snowflake, sound_id discord.Snowflake, reason string) ! {
	s.client.rest.request(.delete, '/guilds/${guild_id}/soundboard-sounds/${sound_id}',
		reason: reason
	)!
}

// StageShorter manages the live instance of stage channels: `c.stages`.
pub struct StageShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut s StageShorter) fetch(channel_id discord.Snowflake, opts FetchOptions) !discord.StageInstance {
	if !opts.force {
		if cached := s.client.cache.stage_instance(channel_id) {
			return cached
		}
	}
	instance := json2.decode[discord.StageInstance](s.client.rest.request(.get, '/stage-instances/${channel_id}')!)!
	s.client.cache.store_stage_instance(instance)
	return instance
}

@[params]
pub struct StageCreate {
pub:
	topic                    string @[required] // 1 to 120 characters
	privacy_level            int = 2
	send_start_notification  bool // notify @everyone; needs MENTION_EVERYONE
	guild_scheduled_event_id ?discord.Snowflake
	reason                   string // written to the audit log
}

struct StageBody {
	channel_id               discord.Snowflake
	topic                    string
	privacy_level            int
	send_start_notification  bool
	guild_scheduled_event_id ?discord.Snowflake
}

// create starts a stage in a stage channel.
pub fn (mut s StageShorter) create(channel_id discord.Snowflake, opts StageCreate) !discord.StageInstance {
	instance := json2.decode[discord.StageInstance](s.client.rest.request(.post, '/stage-instances',
		body:   json2.encode(StageBody{channel_id, opts.topic, opts.privacy_level, opts.send_start_notification, opts.guild_scheduled_event_id})
		reason: opts.reason
	)!)!
	s.client.cache.store_stage_instance(instance)
	return instance
}

@[params]
pub struct StageOptions {
pub:
	topic         ?string
	privacy_level ?int
	reason        string @[skip] // written to the audit log
}

pub fn (mut s StageShorter) edit(channel_id discord.Snowflake, opts StageOptions) !discord.StageInstance {
	instance := json2.decode[discord.StageInstance](s.client.rest.request(.patch,
		'/stage-instances/${channel_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	s.client.cache.store_stage_instance(instance)
	return instance
}

// delete ends the stage.
pub fn (mut s StageShorter) delete(channel_id discord.Snowflake, reason string) ! {
	s.client.rest.request(.delete, '/stage-instances/${channel_id}', reason: reason)!
	if instance := s.client.cache.stage_instance(channel_id) {
		s.client.cache.forget_stage_instance(instance.guild_id, channel_id)
	}
}

// TemplateShorter manages guild templates: `c.templates`.
pub struct TemplateShorter {
mut:
	client &Client = unsafe { nil }
}

pub fn (mut t TemplateShorter) fetch(code string) !discord.GuildTemplate {
	return json2.decode[discord.GuildTemplate](t.client.rest.request(.get, '/guilds/templates/${code}')!)!
}

pub fn (mut t TemplateShorter) list(guild_id discord.Snowflake) ![]discord.GuildTemplate {
	return json2.decode[[]discord.GuildTemplate](t.client.rest.request(.get, '/guilds/${guild_id}/templates')!)!
}

@[params]
pub struct TemplateOptions {
pub:
	name        ?string // 1 to 100 characters
	description ?discord.Nullable[string]
}

// create makes a template of a guild; it needs `name`.
pub fn (mut t TemplateShorter) create(guild_id discord.Snowflake, opts TemplateOptions) !discord.GuildTemplate {
	if opts.name == none {
		return error('veyfert: a template needs a name')
	}
	return json2.decode[discord.GuildTemplate](t.client.rest.request(.post,
		'/guilds/${guild_id}/templates',
		body: json2.encode(opts)
	)!)!
}

// sync updates a template to the guild's current state.
pub fn (mut t TemplateShorter) sync(guild_id discord.Snowflake, code string) !discord.GuildTemplate {
	return json2.decode[discord.GuildTemplate](t.client.rest.request(.put, '/guilds/${guild_id}/templates/${code}')!)!
}

pub fn (mut t TemplateShorter) edit(guild_id discord.Snowflake, code string, opts TemplateOptions) !discord.GuildTemplate {
	return json2.decode[discord.GuildTemplate](t.client.rest.request(.patch,
		'/guilds/${guild_id}/templates/${code}',
		body: json2.encode(opts)
	)!)!
}

pub fn (mut t TemplateShorter) delete(guild_id discord.Snowflake, code string) !discord.GuildTemplate {
	return json2.decode[discord.GuildTemplate](t.client.rest.request(.delete, '/guilds/${guild_id}/templates/${code}')!)!
}

// VoiceStateShorter changes voice states in stage channels: `c.voice_states`.
pub struct VoiceStateShorter {
mut:
	client &Client = unsafe { nil }
}

struct SpeakBody {
	channel_id                 discord.Snowflake
	request_to_speak_timestamp discord.Nullable[string]
}

// request_speak raises the bot's hand in a stage channel, or lowers it with `request` false.
pub fn (mut v VoiceStateShorter) request_speak(guild_id discord.Snowflake, channel_id discord.Snowflake, request bool) ! {
	stamp := if request {
		discord.Nullable[string]{
			value: time.now().format_rfc3339()
		}
	} else {
		discord.Nullable[string]{
			is_null: true
		}
	}
	v.client.rest.request(.patch, '/guilds/${guild_id}/voice-states/@me',
		body: json2.encode(SpeakBody{channel_id, stamp})
	)!
}

@[params]
pub struct Suppress {
pub:
	user_id ?discord.Snowflake // someone else; the bot when none
}

struct SuppressBody {
	channel_id discord.Snowflake
	suppress   bool
}

// set_suppress makes a stage speaker an audience member (true) or a speaker (false).
pub fn (mut v VoiceStateShorter) set_suppress(guild_id discord.Snowflake, channel_id discord.Snowflake, suppress bool, opts Suppress) ! {
	who := if id := opts.user_id { id.str() } else { '@me' }
	v.client.rest.request(.patch, '/guilds/${guild_id}/voice-states/${who}',
		body: json2.encode(SuppressBody{channel_id, suppress})
	)!
}

// Messages.

// end_poll closes a poll of the bot's before its time.
pub fn (mut m MessageShorter) end_poll(channel_id discord.Snowflake, message_id discord.Snowflake) !discord.Message {
	msg := json2.decode[discord.Message](m.client.rest.request(.post, '/channels/${channel_id}/polls/${message_id}/expire')!)!
	m.client.cache.store_message(msg)
	return msg
}

@[params]
pub struct AnswerVoters {
pub:
	after ?discord.Snowflake
	limit int = 25 // 1 to 100
}

struct Voters {
	users []discord.User
}

// answer_voters returns who voted for an answer of a poll.
pub fn (mut m MessageShorter) answer_voters(channel_id discord.Snowflake, message_id discord.Snowflake, answer_id int, opts AnswerVoters) ![]discord.User {
	mut query := 'limit=${opts.limit}'
	if id := opts.after {
		query += '&after=${id}'
	}
	users := json2.decode[Voters](m.client.rest.request(.get,
		'/channels/${channel_id}/polls/${message_id}/answers/${answer_id}',
		query: query
	)!)!.users
	for u in users {
		m.client.cache.store_user(u)
	}
	return users
}

// Threads.

@[params]
pub struct ThreadEdit {
pub:
	name                  ?string
	archived              ?bool
	auto_archive_duration ?int // minutes: 60, 1440, 4320 or 10080
	locked                ?bool
	invitable             ?bool
	rate_limit_per_user   ?int
	flags                 ?int
	applied_tags          ?[]discord.Snowflake // forum tags
	reason                string @[skip] // written to the audit log
}

pub fn (mut t ThreadShorter) edit(thread_id discord.Snowflake, opts ThreadEdit) !discord.Channel {
	th := json2.decode[discord.Channel](t.client.rest.request(.patch, '/channels/${thread_id}',
		body:   json2.encode(opts)
		reason: opts.reason
	)!)!
	t.client.cache.store_channel(th)
	return th
}

// lock locks a thread, so only moderators can unarchive it, or unlocks it.
pub fn (mut t ThreadShorter) lock(thread_id discord.Snowflake, locked bool, reason string) !discord.Channel {
	return t.edit(thread_id, locked: locked, reason: reason)
}

pub fn (mut t ThreadShorter) fetch_member(thread_id discord.Snowflake, user_id discord.Snowflake, with_member bool) !discord.ThreadMember {
	return json2.decode[discord.ThreadMember](t.client.rest.request(.get,
		'/channels/${thread_id}/thread-members/${user_id}',
		query: 'with_member=${with_member}'
	)!)!
}

@[params]
pub struct ThreadMembersQuery {
pub:
	with_member bool
	after       ?discord.Snowflake
	limit       int = 100 // 1 to 100
}

pub fn (mut t ThreadShorter) list_members(thread_id discord.Snowflake, opts ThreadMembersQuery) ![]discord.ThreadMember {
	mut query := 'with_member=${opts.with_member}&limit=${opts.limit}'
	if id := opts.after {
		query += '&after=${id}'
	}
	return json2.decode[[]discord.ThreadMember](t.client.rest.request(.get,
		'/channels/${thread_id}/thread-members',
		query: query
	)!)!
}

fn (mut t ThreadShorter) keep_threads(list discord.ThreadList) discord.ThreadList {
	for th in list.threads {
		t.client.cache.store_channel(th)
	}
	return list
}

@[params]
pub struct ArchivedThreads {
pub:
	private bool    // private threads, which need MANAGE_THREADS
	before  ?string // ISO 8601: threads archived before then
	limit   int = 50
}

pub fn (mut t ThreadShorter) list_archived(channel_id discord.Snowflake, opts ArchivedThreads) !discord.ThreadList {
	kind := if opts.private { 'private' } else { 'public' }
	mut query := 'limit=${opts.limit}'
	if before := opts.before {
		query += '&before=${before}'
	}
	return t.keep_threads(json2.decode[discord.ThreadList](t.client.rest.request(.get,
		'/channels/${channel_id}/threads/archived/${kind}',
		query: query
	)!)!)
}

@[params]
pub struct JoinedArchivedThreads {
pub:
	before ?discord.Snowflake
	limit  int = 50
}

// list_joined_archived_private returns the archived private threads the bot has joined.
pub fn (mut t ThreadShorter) list_joined_archived_private(channel_id discord.Snowflake, opts JoinedArchivedThreads) !discord.ThreadList {
	mut query := 'limit=${opts.limit}'
	if id := opts.before {
		query += '&before=${id}'
	}
	return t.keep_threads(json2.decode[discord.ThreadList](t.client.rest.request(.get,
		'/channels/${channel_id}/users/@me/threads/archived/private',
		query: query
	)!)!)
}

// Users.

// delete_dm closes a direct message channel; the messages stay.
pub fn (mut u UserShorter) delete_dm(channel_id discord.Snowflake) ! {
	u.client.rest.request(.delete, '/channels/${channel_id}')!
	u.client.cache.forget_channel(channel_id)
}

// Webhooks.

@[params]
pub struct WebhookOptions {
pub:
	name       ?string
	avatar     ?discord.Nullable[string] // File.data_uri()
	channel_id ?discord.Snowflake        // not with a token
	token      string @[skip] // edit with the webhook's token instead of the bot's
	reason     string @[skip] // written to the audit log
}

pub fn (mut w WebhookShorter) edit(id discord.Snowflake, opts WebhookOptions) !discord.Webhook {
	path := if opts.token == '' { '/webhooks/${id}' } else { '/webhooks/${id}/${opts.token}' }
	return json2.decode[discord.Webhook](w.client.rest.request(.patch, path,
		body:   json2.encode(opts)
		reason: opts.reason
		auth:   opts.token == ''
	)!)!
}

@[params]
pub struct WebhookToken {
pub:
	token string // read with the webhook's token instead of the bot's
}

pub fn (mut w WebhookShorter) fetch(id discord.Snowflake, opts WebhookToken) !discord.Webhook {
	path := if opts.token == '' { '/webhooks/${id}' } else { '/webhooks/${id}/${opts.token}' }
	return json2.decode[discord.Webhook](w.client.rest.request(.get, path, auth: opts.token == '')!)!
}

@[params]
pub struct WebhookThread {
pub:
	thread_id ?discord.Snowflake // the message is in this thread of the webhook's channel
}

fn thread_query(thread_id ?discord.Snowflake) string {
	return if id := thread_id { 'thread_id=${id}' } else { '' }
}

pub fn (mut w WebhookShorter) fetch_message(id discord.Snowflake, token string, message_id discord.Snowflake, opts WebhookThread) !discord.Message {
	return json2.decode[discord.Message](w.client.rest.request(.get,
		'/webhooks/${id}/${token}/messages/${message_id}',
		query: thread_query(opts.thread_id)
		auth:  false
	)!)!
}

pub fn (mut w WebhookShorter) edit_message(id discord.Snowflake, token string, message_id discord.Snowflake, opts WebhookMessage) !discord.Message {
	msg := json2.decode[discord.Message](w.client.rest.request(.patch,
		'/webhooks/${id}/${token}/messages/${message_id}',
		body:  json2.encode(message_payload(opts.MessageOptions)!)
		query: thread_query(opts.thread_id)
		files: opts.files
		auth:  false
	)!)!
	w.client.cache.store_message(msg)
	return msg
}

pub fn (mut w WebhookShorter) delete_message(id discord.Snowflake, token string, message_id discord.Snowflake, opts WebhookThread) ! {
	w.client.rest.request(.delete, '/webhooks/${id}/${token}/messages/${message_id}',
		query: thread_query(opts.thread_id)
		auth:  false
	)!
}

pub fn (mut w WebhookShorter) list_guild(guild_id discord.Snowflake) ![]discord.Webhook {
	return json2.decode[[]discord.Webhook](w.client.rest.request(.get, '/guilds/${guild_id}/webhooks')!)!
}
