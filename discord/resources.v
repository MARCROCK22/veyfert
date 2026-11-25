module discord

// The resources that the shorters added for parity with Seyfert return. Fields follow Discord's
// JSON; nested shapes that veyfert does not model stay as RawJson.

// Entitlement is a user's or guild's access to a premium SKU.
pub struct Entitlement {
pub:
	id             Snowflake
	sku_id         Snowflake
	application_id Snowflake
	user_id        ?Snowflake
	guild_id       ?Snowflake
	kind           int @[json: 'type'] // 8 application subscription, 4 test mode purchase…
	deleted        bool
	starts_at      ?string
	ends_at        ?string
	consumed       ?bool
}

// Sku is something an application sells.
pub struct Sku {
pub:
	id             Snowflake
	kind           int @[json: 'type'] // 2 durable, 3 consumable, 5 subscription, 6 subscription group
	application_id Snowflake
	name           string
	slug           string
	flags          int
}

pub struct Subscription {
pub:
	id                   Snowflake
	user_id              Snowflake
	sku_ids              []Snowflake
	entitlement_ids      []Snowflake
	renewal_sku_ids      ?[]Snowflake
	current_period_start string
	current_period_end   string
	status               int // 0 active, 1 ending, 2 inactive
	canceled_at          ?string
	country              ?string
}

// ActivityInstance is a running instance of an activity (an embedded app).
pub struct ActivityInstance {
pub:
	application_id Snowflake
	instance_id    string
	launch_id      string
	location       RawJson // id, kind ('gc' or 'pc'), channel_id and guild_id
	users          []Snowflake
}

pub struct SoundboardSound {
pub:
	name       string
	sound_id   Snowflake
	volume     f64
	emoji_id   ?Snowflake
	emoji_name ?string
	guild_id   ?Snowflake
	available  bool
	user       ?User
}

pub struct GuildTemplate {
pub:
	code                    string
	name                    string
	description             ?string
	usage_count             int
	creator_id              Snowflake
	creator                 ?User
	created_at              string
	updated_at              string
	source_guild_id         Snowflake
	serialized_source_guild RawJson
	is_dirty                ?bool
}

pub struct Invite {
pub:
	kind                       int @[json: 'type'] // 0 guild, 1 group DM, 2 friend
	code                       string
	guild                      ?Guild
	channel                    ?Channel
	inviter                    ?User
	target_type                ?int // 1 stream, 2 embedded application
	target_user                ?User
	target_application         ?RawJson
	approximate_presence_count ?int
	approximate_member_count   ?int
	expires_at                 ?string
	guild_scheduled_event      ?ScheduledEvent
	flags                      ?int
	// Only in the lists of a channel or a guild, and when creating:
	uses       ?int
	max_uses   ?int
	max_age    ?int
	temporary  ?bool
	created_at ?string
}

// InviteJobStatus is how far Discord got with a target users upload.
pub struct InviteJobStatus {
pub:
	status          int // 0 unspecified, 1 processing, 2 completed, 3 failed
	total_users     int
	processed_users int
	created_at      ?string
	completed_at    ?string
	error_message   ?string
}

pub struct ScheduledEvent {
pub:
	id                   Snowflake
	guild_id             Snowflake
	channel_id           ?Snowflake
	creator_id           ?Snowflake
	creator              ?User
	name                 string
	description          ?string
	scheduled_start_time string
	scheduled_end_time   ?string
	privacy_level        int // 2 guild only
	status               int // 1 scheduled, 2 active, 3 completed, 4 canceled
	entity_type          int // 1 stage instance, 2 voice, 3 external
	entity_id            ?Snowflake
	entity_metadata      ?ScheduledEventMetadata
	user_count           ?int
	image                ?string
	recurrence_rule      ?RawJson
}

pub struct ScheduledEventMetadata {
pub:
	location ?string // for external events
}

// ScheduledEventUser is someone interested in a scheduled event.
pub struct ScheduledEventUser {
pub:
	guild_scheduled_event_id Snowflake
	user                     User
	member                   ?Member
}

pub struct AutoModerationRule {
pub:
	id               Snowflake
	guild_id         Snowflake
	name             string
	creator_id       Snowflake
	event_type       int // 1 message send, 2 member update
	trigger_type     int // 1 keyword, 3 spam, 4 keyword preset, 5 mention spam, 6 member profile
	trigger_metadata AutoModerationTrigger
	actions          []AutoModerationAction
	enabled          bool
	exempt_roles     []Snowflake
	exempt_channels  []Snowflake
}

pub struct AutoModerationTrigger {
pub:
	keyword_filter                  ?[]string
	regex_patterns                  ?[]string
	presets                         ?[]int // 1 profanity, 2 sexual content, 3 slurs
	allow_list                      ?[]string
	mention_total_limit             ?int
	mention_raid_protection_enabled ?bool
}

pub struct AutoModerationAction {
pub:
	kind     int @[json: 'type'] // 1 block message, 2 send an alert, 3 timeout, 4 block interactions
	metadata ?AutoModerationActionMetadata
}

pub struct AutoModerationActionMetadata {
pub:
	channel_id       ?Snowflake // where alerts go
	duration_seconds ?int       // of a timeout
	custom_message   ?string    // shown when a message is blocked
}

pub struct AuditLog {
pub:
	audit_log_entries      []AuditLogEntry
	users                  []User
	threads                []Channel
	webhooks               []Webhook
	guild_scheduled_events []ScheduledEvent
	auto_moderation_rules  []AutoModerationRule
	integrations           RawJson
	application_commands   RawJson
}

pub struct AuditLogEntry {
pub:
	id          Snowflake
	action_type int
	user_id     ?Snowflake
	target_id   ?Snowflake
	changes     ?[]AuditLogChange
	options     ?map[string]string
	reason      ?string
}

pub struct AuditLogChange {
pub:
	key       string
	new_value RawJson
	old_value RawJson
}

// Onboarding is what new members answer when they join.
pub struct Onboarding {
pub:
	guild_id            Snowflake
	prompts             []OnboardingPrompt
	default_channel_ids []Snowflake
	enabled             bool
	mode                int // 0 default, 1 advanced
}

pub struct OnboardingPrompt {
pub:
	id            Snowflake
	kind          int @[json: 'type'] // 0 multiple choice, 1 dropdown
	options       []OnboardingOption
	title         string
	single_select bool
	required      bool
	in_onboarding bool
}

pub struct OnboardingOption {
pub:
	id          Snowflake
	channel_ids []Snowflake
	role_ids    []Snowflake
	emoji       ?Emoji
	title       string
	description ?string
}

pub struct WelcomeScreen {
pub:
	description      ?string
	welcome_channels []WelcomeChannel
}

pub struct WelcomeChannel {
pub:
	channel_id  Snowflake
	description string
	emoji_id    ?Snowflake
	emoji_name  ?string
}

pub struct WidgetSettings {
pub:
	enabled    bool
	channel_id ?Snowflake
}

pub struct Widget {
pub:
	id             Snowflake
	name           string
	instant_invite ?string
	channels       []WidgetChannel
	members        []WidgetMember
	presence_count int
}

pub struct WidgetChannel {
pub:
	id       Snowflake
	name     string
	position int
}

pub struct WidgetMember {
pub:
	id         string // anonymized: an index, not the user's ID
	username   string
	status     string
	avatar_url string
	channel_id ?Snowflake
}

// FollowedChannel is the webhook that copies an announcement channel's posts.
pub struct FollowedChannel {
pub:
	channel_id Snowflake
	webhook_id Snowflake
}

pub struct ThreadMember {
pub:
	id             ?Snowflake // the thread
	user_id        ?Snowflake
	join_timestamp string
	flags          int
	member         ?Member // with `with_member: true`
}

// ThreadList is a page of threads with the bot's thread memberships.
pub struct ThreadList {
pub:
	threads  []Channel
	members  []ThreadMember
	has_more bool
}

pub struct BulkBan {
pub:
	banned_users []Snowflake
	failed_users []Snowflake
}

// IncidentActions are the safety measures in place in a guild.
pub struct IncidentActions {
pub:
	invites_disabled_until ?string
	dms_disabled_until     ?string
}

// MessageSearch is one page of a guild message search. Each entry of `messages` is a hit, as a
// list whose first message matches.
pub struct MessageSearch {
pub:
	messages                    [][]Message
	total_results               int
	doing_deep_historical_index bool
	threads                     ?[]Channel
	members                     ?[]ThreadMember
}
