module veyfert

import json2
import time
import veyfert.cache
import veyfert.discord
import veyfert.rest

@[heap]
struct Recorder {
mut:
	requests []rest.HttpRequest
}

fn (mut r Recorder) send(req rest.HttpRequest) !rest.HttpResponse {
	r.requests << req
	body := if req.url.contains('/members/') && req.method == .get {
		'{"user":{"id":"8","username":"bob"},"roles":[]}'
	} else if req.url.contains('/threads/active') {
		'{"threads":[{"id":"42","type":11}],"members":[]}'
	} else if req.url.contains('/messages/pins') && req.method == .get {
		'{"items":[{"pinned_at":"","message":{"id":"101","channel_id":"40","author":{"id":"7","username":"ana"},"content":"pinned","timestamp":""}}],"has_more":false}'
	} else if req.url.contains('/messages') && req.method == .get {
		'[]'
	} else {
		'{"id":"101","channel_id":"40","author":{"id":"7","username":"ana"},"content":"","timestamp":""}'
	}
	return rest.HttpResponse{
		status: 200
		body:   body
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test')
	rec := &Recorder{}
	c.rest.transport = rec
	c.dispatch(0, 'RAW_GUILD_CREATE', '{"id":"30","name":"Test","owner_id":"1","channels":[{"id":"40","type":0}],"members":[{"user":{"id":"7","username":"ana"},"roles":[]}]}')
	return c, rec
}

fn sf(v u64) discord.Snowflake {
	return discord.Snowflake{v}
}

fn test_fetch_reads_the_cache_first() ! {
	mut c, rec := recording_client()
	assert c.members.fetch(sf(30), sf(7))!.guild_id or { sf(0) } == sf(30)
	assert c.channels.fetch(sf(40))!.id == sf(40)
	assert c.channels.list(sf(30))!.len == 1
	assert rec.requests.len == 0
	bob := c.members.fetch(sf(30), sf(8))!
	assert (bob.user or { discord.User{} }).username == 'bob' && bob.guild_id or { sf(0) } == sf(30)
	c.members.fetch(sf(30), sf(7), force: true)!
	assert rec.requests.len == 2
	assert rec.requests[1].url.ends_with('/guilds/30/members/7')
}

fn test_message_shorters_send_what_discord_expects() ! {
	mut c, rec := recording_client()
	msg := c.messages.write(sf(40), content: 'hi')!
	c.messages.reply(msg, content: 'quoted')!
	assert rec.requests.last().body == '{"content":"quoted","message_reference":{"message_id":"101","fail_if_not_exists":false}}'
	c.messages.list(sf(40), limit: 10, before: sf(99))!
	assert rec.requests.last().url.ends_with('/channels/40/messages?limit=10&before=99')
	c.messages.delete_bulk(sf(40), [sf(1), sf(2)], 'cleanup')!
	assert rec.requests.last().body == '{"messages":["1","2"]}'
	assert rec.requests.last().headers['X-Audit-Log-Reason'] == 'cleanup'
	assert c.messages.pins(sf(40))!.map(it.content) == ['pinned']
	c.reactions.add(msg.channel_id, msg.id, '👍')!
	assert rec.requests.last().url.ends_with('/channels/40/messages/101/reactions/%F0%9F%91%8D/@me')
	c.reactions.add(sf(40), sf(101), 'v:50')!
	assert rec.requests.last().url.ends_with('/reactions/v:50/@me')
}

fn test_member_shorters_moderate() ! {
	mut c, rec := recording_client()
	member := c.members.fetch(sf(30), sf(7))!
	c.members.timeout(sf(30), (member.user or { discord.User{} }).id, 10 * time.minute, 'spam')!
	body := json2.decode[map[string]string](rec.requests.last().body)!
	assert body['communication_disabled_until'].len > 0
	c.members.timeout(sf(30), sf(7), 0, 'done')!
	assert rec.requests.last().body == '{"communication_disabled_until":null}'
	c.members.ban(sf(30), sf(7), 24 * time.hour, 'raid')!
	assert rec.requests.last().method == .put
	assert rec.requests.last().body == '{"delete_message_seconds":86400}'
	c.members.add_role(sf(30), sf(7), sf(31), '')!
	assert rec.requests.last().url.ends_with('/guilds/30/members/7/roles/31')
	c.members.edit(sf(30), sf(7),
		nick:   discord.Nullable[string]{
			value: 'Ani'
		}
		roles:  [sf(31)]
		reason: 'rename'
	)!
	assert rec.requests.last().body == '{"nick":"Ani","roles":["31"]}'
	assert rec.requests.last().headers['X-Audit-Log-Reason'] == 'rename'
}

fn test_other_shorters_build_their_requests() ! {
	mut c, rec := recording_client()
	c.webhooks.execute(sf(5), 'secret', content: 'hook', username: 'Bot')!
	last := rec.requests.last()
	assert last.url.ends_with('/webhooks/5/secret?wait=true')
	assert 'Authorization' !in last.headers
	assert last.body == '{"content":"hook","username":"Bot"}'
	c.emojis.create(sf(30), 'v', discord.File{
		name:         'v.png'
		data:         [u8(1), 2, 3]
		content_type: 'image/png'
	}, [], '')!
	assert rec.requests.last().body == '{"name":"v","image":"data:image/png;base64,AQID","roles":[]}'
	c.threads.create(sf(40), 'talk', auto_archive_duration: 60)!
	assert rec.requests.last().body == '{"auto_archive_duration":60,"name":"talk"}'
	assert c.threads.list_active(sf(30))!.len == 1
	c.users.write(sf(8), content: 'dm')!
	assert rec.requests[rec.requests.len - 2].body == '{"recipient_id":"8"}'
	assert rec.requests.last().url.ends_with('/channels/101/messages')
	c.channels.set_permission(sf(40), discord.Overwrite{
		id:    sf(31)
		kind:  0
		allow: discord.Permissions.from_names('send_messages')!.wire()
		deny:  '0'
	}, '')!
	assert rec.requests.last().body == '{"type":0,"allow":"2048","deny":"0"}'
}

fn test_shorters_keep_what_discord_returns_in_the_cache() ! {
	mut c := new_client(token: 'test', cache: cache.Options{ messages: 10 })
	rec := &Recorder{}
	c.rest.transport = rec
	c.dispatch(0, 'RAW_GUILD_CREATE', '{"id":"30","name":"Test","owner_id":"1","roles":[{"id":"30","name":"@everyone","permissions":"0"}],"channels":[{"id":"40","type":0}],"members":[{"user":{"id":"7","username":"ana"},"roles":[]}]}')
	// REST, then cache, then the result: a message the bot sent is cached at once.
	msg := c.messages.write(sf(40), content: 'hi')!
	assert (c.cache.message(sf(40), msg.id) or { discord.Message{} }).id == msg.id
	// The MESSAGE_CREATE that follows does not add it twice.
	c.dispatch(0, 'MESSAGE_CREATE', '{"id":"101","channel_id":"40","guild_id":"30","author":{"id":"7","username":"ana"},"content":"hi","timestamp":""}')
	assert c.cache.messages(sf(40)).len == 1
	c.messages.delete(sf(40), msg.id, '')!
	assert c.cache.messages(sf(40)).len == 0
	// A forced fetch refreshes the cache.
	bob := c.members.fetch(sf(30), sf(8), force: true)!
	assert c.cache.member(sf(30), sf(8)) != none
	assert (bob.guild_id or { sf(0) }) == sf(30)
	c.members.kick(sf(30), sf(8), '')!
	assert c.cache.member(sf(30), sf(8)) == none
	c.members.ban(sf(30), sf(7), 0, '')!
	assert c.cache.banned(sf(30), sf(7)) && c.cache.member(sf(30), sf(7)) == none
	c.members.unban(sf(30), sf(7), '')!
	assert !c.cache.banned(sf(30), sf(7))
	c.channels.delete(sf(40), '')!
	assert c.cache.channel(sf(40)) == none
}
