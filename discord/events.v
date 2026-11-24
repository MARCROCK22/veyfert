module discord

// Gateway structures and events. Field names mirror Discord's JSON; unknown fields are ignored.

pub struct Guild {
pub:
	id                         Snowflake
	name                       string
	icon                       ?string
	splash                     ?string
	banner                     ?string
	description                ?string
	owner_id                   Snowflake
	afk_channel_id             ?Snowflake
	afk_timeout                int
	verification_level         int
	features                   []string
	premium_tier               int
	premium_subscription_count ?int
	preferred_locale           string
	system_channel_id          ?Snowflake
	rules_channel_id           ?Snowflake
	vanity_url_code            ?string
	nsfw_level                 int
	unavailable                bool
	// Only in GUILD_CREATE. The cache keeps them apart, so cached guilds have them empty.
	joined_at       ?string
	large           bool
	member_count    int
	roles           []Role
	emojis          []GuildEmoji
	stickers        []Sticker
	channels        []Channel
	threads         []Channel
	members         []Member
	presences       []PresenceUpdate
	voice_states    []VoiceState
	stage_instances []StageInstance
}

pub struct GuildEmoji {
pub:
	id             ?Snowflake
	name           ?string
	roles          []Snowflake
	user           ?User
	require_colons bool
	managed        bool
	animated       bool
	available      bool
}

pub struct Sticker {
pub:
	id          Snowflake
	name        string
	description ?string
	tags        string
	kind        int @[json: 'type']
	format_type int
	available   bool
	guild_id    ?Snowflake
}

// PresenceUpdate is a member's status and activities; it needs the GUILD_PRESENCES intent.
@[Event('PRESENCE_UPDATE')]
pub struct PresenceUpdate {
pub:
	user          User // only `id` is sure to be set
	guild_id      ?Snowflake
	status        string // online, idle, dnd or offline
	activities    []PresenceActivity
	client_status ClientStatus
}

pub struct PresenceActivity {
pub:
	name    string
	kind    int @[json: 'type']
	url     ?string
	state   ?string
	details ?string
	emoji   ?Emoji
}

pub struct ClientStatus {
pub:
	desktop ?string
	mobile  ?string
	web     ?string
}

// VoiceState is who is in which voice channel; a none `channel_id` means the user left.
@[Event('VOICE_STATE_UPDATE')]
pub struct VoiceState {
pub:
	guild_id    ?Snowflake
	channel_id  ?Snowflake
	user_id     Snowflake
	member      ?Member
	session_id  string
	deaf        bool
	mute        bool
	self_deaf   bool
	self_mute   bool
	self_stream ?bool
	self_video  bool
	suppress    bool
}

pub struct StageInstance {
pub:
	id            Snowflake
	guild_id      Snowflake
	channel_id    Snowflake
	topic         string
	privacy_level int
}

@[Event('GUILD_UPDATE')]
pub struct GuildUpdate {
	Guild
}

// GuildDelete is a guild the bot left or was removed from, or, with `unavailable`, an outage.
@[Event('GUILD_DELETE')]
pub struct GuildDelete {
pub:
	id          Snowflake
	unavailable bool
}

@[Event('CHANNEL_CREATE')]
pub struct ChannelCreate {
	Channel
}

@[Event('CHANNEL_UPDATE')]
pub struct ChannelUpdate {
	Channel
}

@[Event('CHANNEL_DELETE')]
pub struct ChannelDelete {
	Channel
}

@[Event('THREAD_CREATE')]
pub struct ThreadCreate {
	Channel
}

@[Event('THREAD_UPDATE')]
pub struct ThreadUpdate {
	Channel
}

@[Event('THREAD_DELETE')]
pub struct ThreadDelete {
	Channel
}

@[Event('THREAD_LIST_SYNC')]
pub struct ThreadListSync {
pub:
	guild_id    Snowflake
	channel_ids []Snowflake
	threads     []Channel
}

@[Event('GUILD_ROLE_CREATE')]
pub struct GuildRoleCreate {
pub:
	guild_id Snowflake
	role     Role
}

@[Event('GUILD_ROLE_UPDATE')]
pub struct GuildRoleUpdate {
pub:
	guild_id Snowflake
	role     Role
}

@[Event('GUILD_ROLE_DELETE')]
pub struct GuildRoleDelete {
pub:
	guild_id Snowflake
	role_id  Snowflake
}

// GuildMemberAdd, GuildMemberUpdate and GuildMemberRemove need the GUILD_MEMBERS intent.
@[Event('GUILD_MEMBER_ADD')]
pub struct GuildMemberAdd {
	Member
}

@[Event('GUILD_MEMBER_UPDATE')]
pub struct GuildMemberUpdate {
	Member
}

@[Event('GUILD_MEMBER_REMOVE')]
pub struct GuildMemberRemove {
pub:
	guild_id Snowflake
	user     User
}

@[Event('GUILD_EMOJIS_UPDATE')]
pub struct GuildEmojisUpdate {
pub:
	guild_id Snowflake
	emojis   []GuildEmoji
}

@[Event('GUILD_STICKERS_UPDATE')]
pub struct GuildStickersUpdate {
pub:
	guild_id Snowflake
	stickers []Sticker
}

@[Event('GUILD_BAN_ADD')]
pub struct GuildBanAdd {
pub:
	guild_id Snowflake
	user     User
}

@[Event('GUILD_BAN_REMOVE')]
pub struct GuildBanRemove {
pub:
	guild_id Snowflake
	user     User
}

@[Event('MESSAGE_CREATE')]
pub struct MessageCreate {
	Message
}

@[Event('MESSAGE_UPDATE')]
pub struct MessageUpdate {
	Message
}

@[Event('MESSAGE_DELETE')]
pub struct MessageDelete {
pub:
	id         Snowflake
	channel_id Snowflake
	guild_id   ?Snowflake
}

@[Event('MESSAGE_DELETE_BULK')]
pub struct MessageDeleteBulk {
pub:
	ids        []Snowflake
	channel_id Snowflake
	guild_id   ?Snowflake
}

@[Event('MESSAGE_REACTION_ADD')]
pub struct MessageReactionAdd {
pub:
	user_id    Snowflake
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
	member     ?Member
	emoji      Emoji
	burst      bool
}

@[Event('MESSAGE_REACTION_REMOVE')]
pub struct MessageReactionRemove {
pub:
	user_id    Snowflake
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
	emoji      Emoji
	burst      bool
}

@[Event('TYPING_START')]
pub struct TypingStart {
pub:
	channel_id Snowflake
	guild_id   ?Snowflake
	user_id    Snowflake
	timestamp  i64
	member     ?Member
}

@[Event('USER_UPDATE')]
pub struct UserUpdate {
	User
}

@[Event('STAGE_INSTANCE_CREATE')]
pub struct StageInstanceCreate {
	StageInstance
}

@[Event('STAGE_INSTANCE_UPDATE')]
pub struct StageInstanceUpdate {
	StageInstance
}

@[Event('STAGE_INSTANCE_DELETE')]
pub struct StageInstanceDelete {
	StageInstance
}
