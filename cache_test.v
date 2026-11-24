module veyfert

import veyfert.cache
import veyfert.discord

const guild_create = '{"id":"30","name":"Test","owner_id":"1","member_count":2,"roles":[{"id":"30","name":"@everyone","permissions":"0"},{"id":"31","name":"mods","permissions":"8"}],"emojis":[{"id":"50","name":"v","roles":[],"available":true}],"channels":[{"id":"40","type":0,"name":"general"},{"id":"41","type":2,"name":"voice"}],"threads":[{"id":"42","type":11,"name":"thread","parent_id":"40"}],"members":[{"user":{"id":"7","username":"ana"},"roles":["31"],"joined_at":"2026-01-01T00:00:00Z"},{"user":{"id":"8","username":"bob"},"roles":[]}],"presences":[{"user":{"id":"7"},"status":"online","activities":[],"client_status":{"desktop":"online"}}],"voice_states":[{"channel_id":"41","user_id":"8","session_id":"s"}]}'

fn sf(v u64) discord.Snowflake {
	return discord.Snowflake{v}
}

fn loaded_client(messages int) &Client {
	mut c := new_client(token: 'test', cache: cache.Options{ messages: messages })
	c.dispatch(0, 'RAW_GUILD_CREATE', guild_create)
	return c
}

fn test_guild_create_fills_every_resource() {
	mut c := loaded_client(0)
	g := c.cache.guild(sf(30)) or { panic('guild missing') }
	assert g.name == 'Test' && g.member_count == 2
	assert g.channels.len == 0 && g.members.len == 0 // kept apart, not twice
	assert c.cache.channels(sf(30)).len == 3
	th := c.cache.channel(sf(42)) or { panic('thread missing') }
	assert (th.guild_id or { sf(0) }) == sf(30) // filled in from the guild
	assert c.cache.roles(sf(30)).len == 2
	assert (c.cache.role(sf(30), sf(31)) or { discord.Role{} }).name == 'mods'
	ana := c.cache.member(sf(30), sf(7)) or { panic('member missing') }
	assert ana.roles == [sf(31)] && (ana.guild_id or { sf(0) }) == sf(30)
	assert (c.cache.user(sf(8)) or { discord.User{} }).username == 'bob'
	assert c.cache.emojis(sf(30)).len == 1
	assert (c.cache.presence(sf(30), sf(7)) or { discord.PresenceUpdate{} }).status == 'online'
	assert (c.cache.voice_state(sf(30), sf(8)) or { discord.VoiceState{} }).session_id == 's'
}

fn test_updates_keep_the_cache_consistent() {
	mut c := loaded_client(0)
	c.dispatch(0, 'CHANNEL_UPDATE', '{"id":"40","type":0,"guild_id":"30","name":"renamed"}')
	assert (c.cache.channel(sf(40)) or { discord.Channel{} }).name or { '' } == 'renamed'
	c.dispatch(0, 'CHANNEL_DELETE', '{"id":"41","type":2,"guild_id":"30"}')
	assert c.cache.channel(sf(41)) == none
	c.dispatch(0, 'GUILD_ROLE_UPDATE', '{"guild_id":"30","role":{"id":"31","name":"admins","permissions":"8"}}')
	assert (c.cache.role(sf(30), sf(31)) or { discord.Role{} }).name == 'admins'
	c.dispatch(0, 'GUILD_ROLE_DELETE', '{"guild_id":"30","role_id":"31"}')
	assert c.cache.role(sf(30), sf(31)) == none
	c.dispatch(0, 'GUILD_MEMBER_ADD', '{"guild_id":"30","user":{"id":"9","username":"cy"},"roles":[]}')
	assert (c.cache.guild(sf(30)) or { discord.Guild{} }).member_count == 3
	c.dispatch(0, 'GUILD_MEMBER_REMOVE', '{"guild_id":"30","user":{"id":"7","username":"ana"}}')
	assert c.cache.member(sf(30), sf(7)) == none
	assert (c.cache.guild(sf(30)) or { discord.Guild{} }).member_count == 2
	c.dispatch(0, 'GUILD_UPDATE', '{"id":"30","name":"Renamed","owner_id":"1","roles":[{"id":"30","name":"@everyone","permissions":"0"}]}')
	g := c.cache.guild(sf(30)) or { panic('guild missing') }
	assert g.name == 'Renamed' && g.member_count == 2 // GUILD_UPDATE has no count
	assert c.cache.channels(sf(30)).len == 2 // channels survive a GUILD_UPDATE
	c.dispatch(0, 'VOICE_STATE_UPDATE', '{"guild_id":"30","channel_id":null,"user_id":"8","session_id":"s"}')
	assert c.cache.voice_state(sf(30), sf(8)) == none
	c.dispatch(0, 'GUILD_BAN_ADD', '{"guild_id":"30","user":{"id":"9","username":"cy"}}')
	assert c.cache.banned(sf(30), sf(9))
	c.dispatch(0, 'GUILD_BAN_REMOVE', '{"guild_id":"30","user":{"id":"9","username":"cy"}}')
	assert !c.cache.banned(sf(30), sf(9))
}

fn test_a_guild_outage_marks_it_and_leaving_forgets_it() {
	mut c := loaded_client(0)
	c.dispatch(0, 'GUILD_DELETE', '{"id":"30","unavailable":true}')
	assert (c.cache.guild(sf(30)) or { discord.Guild{} }).unavailable
	assert c.cache.channels(sf(30)).len == 3
	c.dispatch(0, 'GUILD_DELETE', '{"id":"30"}')
	assert c.cache.guild(sf(30)) == none
	assert c.cache.channels(sf(30)).len == 0
	assert c.cache.members(sf(30)).len == 0
}

fn message_json(n int) string {
	return '{"id":"${100 + n}","channel_id":"40","guild_id":"30","author":{"id":"7","username":"ana"},"member":{"roles":[]},"content":"m${n}","timestamp":""}'
}

fn test_messages_keep_the_last_n_per_channel() {
	mut c := loaded_client(2)
	for n in 1 .. 4 {
		c.dispatch(0, 'MESSAGE_CREATE', message_json(n))
	}
	assert c.cache.messages(sf(40)).map(it.content) == ['m2', 'm3']
	c.dispatch(0, 'MESSAGE_UPDATE', message_json(3).replace('"m3"', '"edited"'))
	assert (c.cache.message(sf(40), sf(103)) or { discord.Message{} }).content == 'edited'
	c.dispatch(0, 'MESSAGE_DELETE', '{"id":"102","channel_id":"40"}')
	assert c.cache.messages(sf(40)).len == 1
	// Authors become cached members and users.
	assert c.cache.member(sf(30), sf(7)) != none
	mut off := loaded_client(0)
	off.dispatch(0, 'MESSAGE_CREATE', message_json(1))
	assert off.cache.messages(sf(40)).len == 0
}

fn test_repeated_member_and_presence_updates_reach_only_raw_listeners() {
	mut c := loaded_client(0)
	update := '{"guild_id":"30","user":{"id":"8","username":"bob"},"roles":[],"nick":"b"}'
	presence := '{"user":{"id":"8"},"guild_id":"30","status":"idle","activities":[],"client_status":{}}'
	c.on_raw(fn (e RawEvent, mut c Client) ! {})
	for raw in [update, update, update.replace('"b"', '"bo"'), presence, presence] {
		c.dispatch(0, if raw.contains('status') { 'PRESENCE_UPDATE' } else { 'GUILD_MEMBER_UPDATE' },
			raw)
	}
	mut duplicates := []bool{}
	for c.jobs.len > 0 {
		job := <-c.jobs
		duplicates << job.duplicate
	}
	assert duplicates == [false, true, false, false, true]
	assert (c.cache.member(sf(30), sf(8)) or { discord.Member{} }).nick or { '' } == 'bo'
}
