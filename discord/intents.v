module discord

// Intents selects which gateway events Discord sends. Values are bit positions, so
// `.guilds | .guild_messages` builds the bitfield. Privileged intents must also be
// enabled in the Developer Portal.
@[flag]
pub enum Intents {
	guilds
	guild_members // privileged
	guild_moderation
	guild_expressions
	guild_integrations
	guild_webhooks
	guild_invites
	guild_voice_states
	guild_presences // privileged
	guild_messages
	guild_message_reactions
	guild_message_typing
	direct_messages
	direct_message_reactions
	direct_message_typing
	message_content // privileged
	guild_scheduled_events
	auto_moderation_configuration = 20
	auto_moderation_execution
	guild_message_polls           = 24
	direct_message_polls
}
