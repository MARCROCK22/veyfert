module veyfert

import json2
import veyfert.discord

fn sf(v u64) discord.Snowflake {
	return discord.Snowflake{v}
}

// decoded checks the event name of T and decodes a payload as a listener of T would.
fn decoded[T](name string, raw string) !T {
	assert event_name[T]() == name
	return json2.decode[T](raw)!
}

fn test_the_new_gateway_events_have_their_names_and_decode() ! {
	perms := decoded[discord.ApplicationCommandPermissionsUpdate]('APPLICATION_COMMAND_PERMISSIONS_UPDATE',
		'{"id":"1","application_id":"2","guild_id":"3","permissions":[{"id":"4","type":1,"permission":true}]}')!
	assert perms.permissions[0].permission && perms.permissions[0].kind == 1

	rule := '{"id":"5","guild_id":"3","name":"spam","creator_id":"1","event_type":1,"trigger_type":1,"trigger_metadata":{"keyword_filter":["x"]},"actions":[{"type":1}],"enabled":true,"exempt_roles":[],"exempt_channels":[]}'
	assert decoded[discord.AutoModerationRuleCreate]('AUTO_MODERATION_RULE_CREATE', rule)!.name == 'spam'
	assert decoded[discord.AutoModerationRuleUpdate]('AUTO_MODERATION_RULE_UPDATE', rule)!.enabled
	deleted_rule := decoded[discord.AutoModerationRuleDelete]('AUTO_MODERATION_RULE_DELETE', rule)!
	assert deleted_rule.trigger_metadata.keyword_filter or { [] } == ['x']
	exec := decoded[discord.AutoModerationActionExecution]('AUTO_MODERATION_ACTION_EXECUTION',
		'{"guild_id":"3","action":{"type":1},"rule_id":"5","rule_trigger_type":1,"user_id":"7","content":"bad","matched_keyword":"bad","matched_content":null}')!
	assert exec.content == 'bad' && exec.action.kind == 1 && exec.matched_content == none

	pins := decoded[discord.ChannelPinsUpdate]('CHANNEL_PINS_UPDATE', '{"channel_id":"40","last_pin_timestamp":"2026-01-01T00:00:00Z"}')!
	assert pins.channel_id == sf(40) && pins.guild_id == none
	info := decoded[discord.ChannelInfo]('CHANNEL_INFO', '{"guild_id":"3","channels":[{"id":"45","status":"lofi","voice_start_time":1700000000}]}')!
	assert info.channels[0].status or { '' } == 'lofi'
	assert info.channels[0].voice_start_time or { 0 } == 1700000000

	entitlement := '{"id":"80","sku_id":"1","application_id":"99","user_id":"7","type":8,"deleted":false}'
	assert decoded[discord.EntitlementCreate]('ENTITLEMENT_CREATE', entitlement)!.kind == 8
	assert decoded[discord.EntitlementUpdate]('ENTITLEMENT_UPDATE', entitlement)!.sku_id == sf(1)
	assert decoded[discord.EntitlementDelete]('ENTITLEMENT_DELETE', entitlement)!.id == sf(80)

	entry := decoded[discord.GuildAuditLogEntryCreate]('GUILD_AUDIT_LOG_ENTRY_CREATE',
		'{"id":"1","action_type":20,"user_id":"7","target_id":"8","guild_id":"3","reason":"spam"}')!
	assert entry.action_type == 20 && entry.guild_id == sf(3) && entry.reason or { '' } == 'spam'
	assert decoded[discord.GuildIntegrationsUpdate]('GUILD_INTEGRATIONS_UPDATE', '{"guild_id":"3"}')!.guild_id == sf(3)

	event := '{"id":"6","guild_id":"3","name":"Party","scheduled_start_time":"2026-12-01T20:00:00Z","privacy_level":2,"status":1,"entity_type":3,"entity_metadata":{"location":"Park"}}'
	created := decoded[discord.ScheduledEventCreate]('GUILD_SCHEDULED_EVENT_CREATE', event)!
	assert (created.entity_metadata or { discord.ScheduledEventMetadata{} }).location or { '' } == 'Park'
	assert decoded[discord.ScheduledEventUpdate]('GUILD_SCHEDULED_EVENT_UPDATE', event)!.status == 1
	assert decoded[discord.ScheduledEventDelete]('GUILD_SCHEDULED_EVENT_DELETE', event)!.name == 'Party'
	rsvp := '{"guild_scheduled_event_id":"6","user_id":"7","guild_id":"3"}'
	assert decoded[discord.ScheduledEventUserAdd]('GUILD_SCHEDULED_EVENT_USER_ADD', rsvp)!.user_id == sf(7)
	assert decoded[discord.ScheduledEventUserRemove]('GUILD_SCHEDULED_EVENT_USER_REMOVE', rsvp)!.guild_scheduled_event_id == sf(6)

	sound := '{"name":"quack","sound_id":"1","volume":1,"guild_id":"3","available":true}'
	assert decoded[discord.SoundboardSoundCreate]('GUILD_SOUNDBOARD_SOUND_CREATE', sound)!.name == 'quack'
	assert decoded[discord.SoundboardSoundUpdate]('GUILD_SOUNDBOARD_SOUND_UPDATE', sound)!.volume == 1.0
	assert decoded[discord.SoundboardSoundDelete]('GUILD_SOUNDBOARD_SOUND_DELETE', '{"sound_id":"1","guild_id":"3"}')!.sound_id == sf(1)
	sounds := '{"soundboard_sounds":[${sound}],"guild_id":"3"}'
	assert decoded[discord.SoundboardSoundsUpdate]('GUILD_SOUNDBOARD_SOUNDS_UPDATE', sounds)!.soundboard_sounds.len == 1
	assert decoded[discord.SoundboardSounds]('SOUNDBOARD_SOUNDS', sounds)!.guild_id == sf(3)

	integration := '{"id":"9","name":"bot","type":"discord","enabled":true,"account":{"id":"1","name":"Bot"},"guild_id":"3"}'
	added := decoded[discord.IntegrationCreate]('INTEGRATION_CREATE', integration)!
	assert added.kind == 'discord' && added.account.name == 'Bot' && added.guild_id == sf(3)
	assert decoded[discord.IntegrationUpdate]('INTEGRATION_UPDATE', integration)!.enabled
	removed := decoded[discord.IntegrationDelete]('INTEGRATION_DELETE', '{"id":"9","guild_id":"3","application_id":"99"}')!
	assert removed.application_id or { sf(0) } == sf(99)

	invite := decoded[discord.InviteCreate]('INVITE_CREATE', '{"channel_id":"40","code":"abc","created_at":"2026-01-01T00:00:00Z","guild_id":"3","max_age":3600,"max_uses":0,"temporary":false,"uses":0}')!
	assert invite.code == 'abc' && invite.max_age == 3600
	assert decoded[discord.InviteDelete]('INVITE_DELETE', '{"channel_id":"40","guild_id":"3","code":"abc"}')!.code == 'abc'

	vote := '{"user_id":"7","channel_id":"40","message_id":"5","guild_id":"3","answer_id":2}'
	assert decoded[discord.MessagePollVoteAdd]('MESSAGE_POLL_VOTE_ADD', vote)!.answer_id == 2
	assert decoded[discord.MessagePollVoteRemove]('MESSAGE_POLL_VOTE_REMOVE', vote)!.user_id == sf(7)
	assert decoded[discord.MessageReactionRemoveAll]('MESSAGE_REACTION_REMOVE_ALL', '{"channel_id":"40","message_id":"5","guild_id":"3"}')!.message_id == sf(5)
	emoji := decoded[discord.MessageReactionRemoveEmoji]('MESSAGE_REACTION_REMOVE_EMOJI', '{"channel_id":"40","message_id":"5","guild_id":"3","emoji":{"id":null,"name":"👍"}}')!
	assert emoji.emoji.name == '👍'

	subscription := '{"id":"90","user_id":"7","sku_ids":["1"],"entitlement_ids":["80"],"current_period_start":"a","current_period_end":"b","status":0}'
	assert decoded[discord.SubscriptionCreate]('SUBSCRIPTION_CREATE', subscription)!.sku_ids == [sf(1)]
	assert decoded[discord.SubscriptionUpdate]('SUBSCRIPTION_UPDATE', subscription)!.status == 0
	assert decoded[discord.SubscriptionDelete]('SUBSCRIPTION_DELETE', subscription)!.entitlement_ids == [sf(80)]

	own := decoded[discord.ThreadMemberUpdate]('THREAD_MEMBER_UPDATE', '{"id":"42","user_id":"1","join_timestamp":"t","flags":1,"guild_id":"3"}')!
	assert own.flags == 1 && own.guild_id == sf(3)
	members := decoded[discord.ThreadMembersUpdate]('THREAD_MEMBERS_UPDATE', '{"id":"42","guild_id":"3","member_count":3,"added_members":[{"id":"42","user_id":"7","join_timestamp":"t","flags":0}],"removed_member_ids":["8"]}')!
	assert members.member_count == 3 && (members.added_members or { [] }).len == 1
	assert members.removed_member_ids or { [] } == [sf(8)]

	server := decoded[discord.VoiceServerUpdate]('VOICE_SERVER_UPDATE', '{"token":"t","guild_id":"3","endpoint":"x.discord.media:443"}')!
	assert server.endpoint or { '' } == 'x.discord.media:443'
	effect := decoded[discord.VoiceChannelEffectSend]('VOICE_CHANNEL_EFFECT_SEND', '{"channel_id":"45","guild_id":"3","user_id":"7","emoji":{"id":null,"name":"🎉"},"animation_type":1,"animation_id":2}')!
	assert effect.animation_id or { 0 } == 2 && effect.sound_id == none
	status := decoded[discord.VoiceChannelStatusUpdate]('VOICE_CHANNEL_STATUS_UPDATE', '{"id":"45","guild_id":"3","status":"lofi"}')!
	assert status.status or { '' } == 'lofi'
	start := decoded[discord.VoiceChannelStartTimeUpdate]('VOICE_CHANNEL_START_TIME_UPDATE', '{"id":"45","guild_id":"3","voice_start_time":null}')!
	assert start.voice_start_time == none
	assert decoded[discord.WebhooksUpdate]('WEBHOOKS_UPDATE', '{"guild_id":"3","channel_id":"40"}')!.channel_id == sf(40)
	assert decoded[RawGuildDelete]('RAW_GUILD_DELETE', '{"id":"3","unavailable":false}')!.id == sf(3)
}

fn test_the_cache_follows_interactions_reactions_typing_and_voice_status() {
	mut c := new_client(token: 'test')
	c.cache.apply('RAW_GUILD_CREATE', '{"id":"3","name":"G","owner_id":"1","channels":[{"id":"45","type":2}],"members":[],"roles":[]}')
	// The member who used a command, and the users and members its options mention.
	c.cache.apply('INTERACTION_CREATE', '{"id":"1","application_id":"99","type":2,"token":"t","guild_id":"3","member":{"user":{"id":"7","username":"ana"},"roles":[]},"data":{"id":"5","name":"x","type":1,"resolved":{"users":{"8":{"id":"8","username":"bob"},"9":{"id":"9","username":"cy"}},"members":{"8":{"roles":["50"]}}}}}')
	assert (c.cache.member(sf(3), sf(7)) or { discord.Member{} }).roles.len == 0
	bob := c.cache.member(sf(3), sf(8)) or { discord.Member{} }
	assert (bob.user or { discord.User{} }).username == 'bob' && bob.roles == [sf(50)]
	assert (c.cache.user(sf(9)) or { discord.User{} }).username == 'cy'
	assert c.cache.member(sf(3), sf(9)) == none
	// A direct message carries a user, not a member.
	c.cache.apply('INTERACTION_CREATE', '{"id":"2","application_id":"99","type":2,"token":"t","user":{"id":"10","username":"dm"}}')
	assert (c.cache.user(sf(10)) or { discord.User{} }).username == 'dm'

	c.cache.apply('MESSAGE_REACTION_ADD', '{"user_id":"11","channel_id":"45","message_id":"5","guild_id":"3","member":{"user":{"id":"11","username":"rex"},"roles":[]},"emoji":{"name":"x"}}')
	assert c.cache.member(sf(3), sf(11)) != none
	c.cache.apply('TYPING_START', '{"channel_id":"45","guild_id":"3","user_id":"12","timestamp":1,"member":{"user":{"id":"12","username":"tia"},"roles":[]}}')
	assert c.cache.member(sf(3), sf(12)) != none

	c.cache.apply('VOICE_CHANNEL_STATUS_UPDATE', '{"id":"45","guild_id":"3","status":"lofi"}')
	assert (c.cache.channel(sf(45)) or { discord.Channel{} }).status or { '' } == 'lofi'

	c.cache.apply('RAW_GUILD_DELETE', '{"id":"3","unavailable":false}')
	assert c.cache.guild(sf(3)) == none
}
