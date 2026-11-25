module discord

// The gateway events that Seyfert types and veyfert did not (phase 8 in docs/PLAN.md). The ones
// that repeat a resource embed it: `e.name` of an AutoModerationRuleCreate is the rule's name.

pub struct CommandPermission {
pub:
	id         Snowflake // a role, a user or a channel; the guild's ID is @everyone
	kind       int @[json: 'type'] // 1 role, 2 user, 3 channel
	permission bool
}

@[Event('APPLICATION_COMMAND_PERMISSIONS_UPDATE')]
pub struct ApplicationCommandPermissionsUpdate {
pub:
	id             Snowflake // the command, or the application for its defaults
	application_id Snowflake
	guild_id       Snowflake
	permissions    []CommandPermission
}

@[Event('AUTO_MODERATION_RULE_CREATE')]
pub struct AutoModerationRuleCreate {
	AutoModerationRule
}

@[Event('AUTO_MODERATION_RULE_UPDATE')]
pub struct AutoModerationRuleUpdate {
	AutoModerationRule
}

@[Event('AUTO_MODERATION_RULE_DELETE')]
pub struct AutoModerationRuleDelete {
	AutoModerationRule
}

// AutoModerationActionExecution is a rule acting; it needs the AUTO_MODERATION_EXECUTION intent,
// and MESSAGE_CONTENT for `content`.
@[Event('AUTO_MODERATION_ACTION_EXECUTION')]
pub struct AutoModerationActionExecution {
pub:
	guild_id                Snowflake
	action                  AutoModerationAction
	rule_id                 Snowflake
	rule_trigger_type       int
	user_id                 Snowflake
	channel_id              ?Snowflake
	message_id              ?Snowflake
	alert_system_message_id ?Snowflake
	content                 string
	matched_keyword         ?string
	matched_content         ?string
}

@[Event('CHANNEL_PINS_UPDATE')]
pub struct ChannelPinsUpdate {
pub:
	guild_id           ?Snowflake
	channel_id         Snowflake
	last_pin_timestamp ?string
}

pub struct ChannelInfoEntry {
pub:
	id               Snowflake
	status           ?string // a voice channel's status line
	voice_start_time ?i64    // Unix seconds since the voice session started
}

// ChannelInfo answers a gateway request for the voice status of a guild's channels.
@[Event('CHANNEL_INFO')]
pub struct ChannelInfo {
pub:
	guild_id Snowflake
	channels []ChannelInfoEntry
}

@[Event('ENTITLEMENT_CREATE')]
pub struct EntitlementCreate {
	Entitlement
}

@[Event('ENTITLEMENT_UPDATE')]
pub struct EntitlementUpdate {
	Entitlement
}

@[Event('ENTITLEMENT_DELETE')]
pub struct EntitlementDelete {
	Entitlement
}

// GuildAuditLogEntryCreate needs the GUILD_MODERATION intent and VIEW_AUDIT_LOG.
@[Event('GUILD_AUDIT_LOG_ENTRY_CREATE')]
pub struct GuildAuditLogEntryCreate {
	AuditLogEntry
pub:
	guild_id Snowflake
}

@[Event('GUILD_INTEGRATIONS_UPDATE')]
pub struct GuildIntegrationsUpdate {
pub:
	guild_id Snowflake
}

@[Event('GUILD_SCHEDULED_EVENT_CREATE')]
pub struct ScheduledEventCreate {
	ScheduledEvent
}

@[Event('GUILD_SCHEDULED_EVENT_UPDATE')]
pub struct ScheduledEventUpdate {
	ScheduledEvent
}

@[Event('GUILD_SCHEDULED_EVENT_DELETE')]
pub struct ScheduledEventDelete {
	ScheduledEvent
}

@[Event('GUILD_SCHEDULED_EVENT_USER_ADD')]
pub struct ScheduledEventUserAdd {
pub:
	guild_scheduled_event_id Snowflake
	user_id                  Snowflake
	guild_id                 Snowflake
}

@[Event('GUILD_SCHEDULED_EVENT_USER_REMOVE')]
pub struct ScheduledEventUserRemove {
pub:
	guild_scheduled_event_id Snowflake
	user_id                  Snowflake
	guild_id                 Snowflake
}

@[Event('GUILD_SOUNDBOARD_SOUND_CREATE')]
pub struct SoundboardSoundCreate {
	SoundboardSound
}

@[Event('GUILD_SOUNDBOARD_SOUND_UPDATE')]
pub struct SoundboardSoundUpdate {
	SoundboardSound
}

@[Event('GUILD_SOUNDBOARD_SOUND_DELETE')]
pub struct SoundboardSoundDelete {
pub:
	sound_id Snowflake
	guild_id Snowflake
}

@[Event('GUILD_SOUNDBOARD_SOUNDS_UPDATE')]
pub struct SoundboardSoundsUpdate {
pub:
	soundboard_sounds []SoundboardSound
	guild_id          Snowflake
}

// SoundboardSounds answers `Client.request_soundboard_sounds`, once per guild.
@[Event('SOUNDBOARD_SOUNDS')]
pub struct SoundboardSounds {
pub:
	soundboard_sounds []SoundboardSound
	guild_id          Snowflake
}

pub struct Integration {
pub:
	id                  Snowflake
	name                string
	kind                string @[json: 'type'] // twitch, youtube, discord or guild_subscription
	enabled             bool
	syncing             ?bool
	role_id             ?Snowflake
	enable_emoticons    ?bool
	expire_behavior     ?int
	expire_grace_period ?int
	user                ?User
	account             IntegrationAccount
	synced_at           ?string
	subscriber_count    ?int
	revoked             ?bool
	application         ?RawJson
	scopes              ?[]string
}

pub struct IntegrationAccount {
pub:
	id   string
	name string
}

@[Event('INTEGRATION_CREATE')]
pub struct IntegrationCreate {
	Integration
pub:
	guild_id Snowflake
}

@[Event('INTEGRATION_UPDATE')]
pub struct IntegrationUpdate {
	Integration
pub:
	guild_id Snowflake
}

@[Event('INTEGRATION_DELETE')]
pub struct IntegrationDelete {
pub:
	id             Snowflake
	guild_id       Snowflake
	application_id ?Snowflake // the bot's, for a bot integration
}

@[Event('INVITE_CREATE')]
pub struct InviteCreate {
pub:
	channel_id         Snowflake
	code               string
	created_at         string
	guild_id           ?Snowflake
	inviter            ?User
	max_age            int
	max_uses           int
	target_type        ?int
	target_user        ?User
	target_application ?RawJson
	temporary          bool
	uses               int
}

@[Event('INVITE_DELETE')]
pub struct InviteDelete {
pub:
	channel_id Snowflake
	guild_id   ?Snowflake
	code       string
}

@[Event('MESSAGE_POLL_VOTE_ADD')]
pub struct MessagePollVoteAdd {
pub:
	user_id    Snowflake
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
	answer_id  int
}

@[Event('MESSAGE_POLL_VOTE_REMOVE')]
pub struct MessagePollVoteRemove {
pub:
	user_id    Snowflake
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
	answer_id  int
}

@[Event('MESSAGE_REACTION_REMOVE_ALL')]
pub struct MessageReactionRemoveAll {
pub:
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
}

@[Event('MESSAGE_REACTION_REMOVE_EMOJI')]
pub struct MessageReactionRemoveEmoji {
pub:
	channel_id Snowflake
	message_id Snowflake
	guild_id   ?Snowflake
	emoji      Emoji
}

@[Event('SUBSCRIPTION_CREATE')]
pub struct SubscriptionCreate {
	Subscription
}

@[Event('SUBSCRIPTION_UPDATE')]
pub struct SubscriptionUpdate {
	Subscription
}

@[Event('SUBSCRIPTION_DELETE')]
pub struct SubscriptionDelete {
	Subscription
}

// ThreadMemberUpdate is the bot's own thread membership changing.
@[Event('THREAD_MEMBER_UPDATE')]
pub struct ThreadMemberUpdate {
	ThreadMember
pub:
	guild_id Snowflake
}

@[Event('THREAD_MEMBERS_UPDATE')]
pub struct ThreadMembersUpdate {
pub:
	id                 Snowflake // the thread
	guild_id           Snowflake
	member_count       int // Discord stops counting at 50
	added_members      ?[]ThreadMember
	removed_member_ids ?[]Snowflake
}

// VoiceServerUpdate carries what a voice connection needs, after the bot joins a channel.
@[Event('VOICE_SERVER_UPDATE')]
pub struct VoiceServerUpdate {
pub:
	token    string
	guild_id Snowflake
	endpoint ?string // none while Discord moves the voice server
}

// VoiceChannelEffectSend is someone sending an emoji reaction or a soundboard sound in a voice
// channel the bot is in.
@[Event('VOICE_CHANNEL_EFFECT_SEND')]
pub struct VoiceChannelEffectSend {
pub:
	channel_id     Snowflake
	guild_id       Snowflake
	user_id        Snowflake
	emoji          ?Emoji
	animation_type ?int // 0 premium, 1 basic
	animation_id   ?int
	sound_id       ?Snowflake
	sound_volume   ?f64
}

@[Event('VOICE_CHANNEL_STATUS_UPDATE')]
pub struct VoiceChannelStatusUpdate {
pub:
	id       Snowflake // the channel
	guild_id Snowflake
	status   ?string
}

@[Event('VOICE_CHANNEL_START_TIME_UPDATE')]
pub struct VoiceChannelStartTimeUpdate {
pub:
	id               Snowflake // the channel
	guild_id         Snowflake
	voice_start_time ?i64 // Unix seconds; none when the session ended
}

@[Event('WEBHOOKS_UPDATE')]
pub struct WebhooksUpdate {
pub:
	guild_id   Snowflake
	channel_id Snowflake
}
