module discord

import json2

// Event names the gateway event that a payload type carries, for `Client.on`.
@[attribute]
pub struct Event {
pub:
	name string
}

// Payloads used by phase 0. Field names mirror Discord's JSON, which is snake_case like V;
// unknown fields are ignored. Generated models replace these in phase 2.

pub struct User {
pub:
	id            Snowflake
	username      string
	discriminator string
	global_name   ?string
	avatar        ?string
	banner        ?string
	accent_color  ?int
	bot           bool
	system        bool
	public_flags  int
}

pub struct Member {
pub:
	user                         ?User
	nick                         ?string
	avatar                       ?string
	roles                        []Snowflake
	joined_at                    ?string
	premium_since                ?string
	deaf                         bool
	mute                         bool
	pending                      bool
	flags                        int
	communication_disabled_until ?string
	permissions                  ?string    // in interactions: the member's permissions in the channel
	guild_id                     ?Snowflake // set by member events and by the cache
}

// Application is the bot's application; READY carries only `id` and `flags`.
pub struct Application {
pub:
	id                                Snowflake
	name                              string
	icon                              ?string
	description                       string
	rpc_origins                       ?[]string
	bot_public                        bool
	bot_require_code_grant            bool
	bot                               ?User
	terms_of_service_url              ?string
	privacy_policy_url                ?string
	owner                             ?User
	verify_key                        string
	team                              ?RawJson
	guild_id                          ?Snowflake
	primary_sku_id                    ?Snowflake
	slug                              ?string
	cover_image                       ?string
	flags                             ?int
	approximate_guild_count           ?int
	approximate_user_install_count    ?int
	redirect_uris                     ?[]string
	interactions_endpoint_url         ?string
	role_connections_verification_url ?string
	event_webhooks_url                ?string
	event_webhooks_status             ?int
	tags                              ?[]string
	install_params                    ?RawJson
	integration_types_config          ?RawJson
	custom_install_url                ?string
}

pub struct UnavailableGuild {
pub:
	id Snowflake
}

@[Event('READY')]
pub struct Ready {
pub:
	user               User
	session_id         string
	resume_gateway_url string
	application        Application
	guilds             []UnavailableGuild
}

// GuildCreate is a guild the bot joins, or one that becomes available again; at startup the
// guilds arrive as RawGuildCreate.
@[Event('GUILD_CREATE')]
pub struct GuildCreate {
	Guild
}

pub struct InteractionOption {
pub:
	name    string
	kind    int    @[json: 'type']
	value   string @[raw] // the JSON text of a string, number or boolean
	options []InteractionOption
	focused bool
}

pub struct InteractionData {
pub:
	id             Snowflake // commands
	name           string
	kind           int @[json: 'type']
	options        []InteractionOption
	resolved       ?Resolved
	target_id      ?Snowflake // the user or message a context menu command targets
	custom_id      ?string    // components and modals
	component_type ?int
	values         []string // what a select picked
	components     ?RawJson // what a modal sent
}

@[Event('INTERACTION_CREATE')]
pub struct Interaction {
pub:
	id              Snowflake
	application_id  Snowflake
	kind            int @[json: 'type']
	data            ?InteractionData
	guild_id        ?Snowflake
	channel_id      ?Snowflake
	member          ?Member
	user            ?User
	token           string
	locale          ?string
	guild_locale    ?string
	app_permissions ?string  // the bot's permissions in the channel
	message         ?Message // the message of a component
}

// Nullable writes JSON null when `is_null` is set. A `?Nullable[T]` field tells apart the
// three states a PATCH body needs: none omits the field, null clears it, a value sets it.
pub struct Nullable[T] {
pub:
	is_null bool
	value   T
}

pub fn (n Nullable[T]) to_json() string {
	if n.is_null {
		return 'null'
	}
	return json2.encode(n.value)
}

pub enum Status {
	online
	dnd
	idle
	invisible
}

@[json_as_number]
pub enum ActivityType {
	playing   = 0
	streaming = 1
	listening = 2
	watching  = 3
	custom    = 4
	competing = 5
}

pub struct Activity {
pub:
	name  string
	kind  ActivityType @[json: 'type']
	state ?string // the text of a custom status
	url   ?string // the stream of a streaming activity
}

pub struct Presence {
pub:
	status     Status = .online
	activities []Activity
	afk        bool
}

@[Event('RESUMED')]
pub struct Resumed {}

// MembersChunk is one part of the answer to a guild members request.
@[Event('GUILD_MEMBERS_CHUNK')]
pub struct MembersChunk {
pub:
	guild_id    Snowflake
	members     []Member
	chunk_index int
	chunk_count int
	nonce       ?string
	presences   []PresenceUpdate
}

pub struct RateLimitedMeta {
pub:
	nonce ?string
}

// RateLimited is the gateway's answer to a request it limits, such as a members request.
@[Event('RATE_LIMITED')]
pub struct RateLimited {
pub:
	opcode      int
	retry_after f64
	meta        RateLimitedMeta
}

// RawJson holds a JSON value as text. Generated models use it where Discord's spec has a
// union that V cannot model: it decodes any value and encodes the text as it is.
pub struct RawJson {
pub mut:
	text string
}

pub fn (r RawJson) to_json() string {
	return if r.text == '' { 'null' } else { r.text }
}

pub fn (mut r RawJson) from_json(value json2.Any) {
	r.text = json2.encode(value)
}

// decode reads the value as T, such as a generated endpoint's channel as a veyfert.Channel.
pub fn (r RawJson) decode[T]() !T {
	return json2.decode[T](r.text)!
}

pub struct Role {
pub:
	id            Snowflake
	name          string
	color         int
	hoist         bool
	icon          ?string
	unicode_emoji ?string
	position      int
	permissions   string
	managed       bool
	mentionable   bool
	flags         int
}

pub struct Attachment {
pub:
	id           Snowflake
	filename     string
	size         int
	url          string
	proxy_url    string
	content_type ?string
	width        ?int
	height       ?int
}

// Channel is any channel, thread included; `kind` is its ChannelTypes value. Options and
// resolved data carry partial ones.
pub struct Channel {
pub:
	id                    Snowflake
	kind                  int @[json: 'type']
	guild_id              ?Snowflake
	position              ?int
	permission_overwrites []Overwrite
	name                  ?string
	topic                 ?string
	nsfw                  bool
	last_message_id       ?Snowflake
	bitrate               ?int
	user_limit            ?int
	rate_limit_per_user   ?int
	parent_id             ?Snowflake
	owner_id              ?Snowflake // threads
	thread_metadata       ?ThreadMetadata
	message_count         ?int
	member_count          ?int
	permissions           ?string // in interactions: the bot's permissions there
	flags                 int
}

// Overwrite changes the permissions of a role (`kind` 0) or a member (1) in a channel.
pub struct Overwrite {
pub:
	id    Snowflake
	kind  int @[json: 'type']
	allow string
	deny  string
}

pub struct ThreadMetadata {
pub:
	archived              bool
	auto_archive_duration int
	archive_timestamp     string
	locked                bool
	invitable             ?bool
}

// Mentionable is a user or a role picked in a mentionable option.
pub struct Mentionable {
pub:
	id     Snowflake
	user   ?User
	member ?Member
	role   ?Role
}

pub struct Message {
pub:
	id                Snowflake
	channel_id        Snowflake
	guild_id          ?Snowflake
	author            User
	member            ?Member // the author's member, in guild messages from the gateway
	content           string  // needs the MESSAGE_CONTENT intent, except in DMs and mentions
	timestamp         string
	edited_timestamp  ?string
	tts               bool
	mention_everyone  bool
	mentions          []User
	mention_roles     []Snowflake
	attachments       []Attachment
	embeds            []Embed
	pinned            bool
	webhook_id        ?Snowflake
	kind              int @[json: 'type']
	flags             int
	message_reference ?MessageReference
	components        ?RawJson // as Discord sent them; build new ones with the constructors
}

pub struct MessageReference {
pub:
	message_id         ?Snowflake
	channel_id         ?Snowflake
	guild_id           ?Snowflake
	fail_if_not_exists ?bool
}

// Resolved holds the users, roles, channels, attachments and messages that options and
// context menus point to, by ID.
pub struct Resolved {
pub:
	users       map[string]User
	members     map[string]Member
	roles       map[string]Role
	channels    map[string]Channel
	attachments map[string]Attachment
	messages    map[string]Message
}

pub struct Webhook {
pub:
	id             Snowflake
	kind           int @[json: 'type']
	guild_id       ?Snowflake
	channel_id     ?Snowflake
	name           ?string
	avatar         ?string
	token          ?string // set for the incoming webhooks the bot can read
	application_id ?Snowflake
}

pub struct Ban {
pub:
	reason ?string
	user   User
}
