module veyfert

import net.http
import time
import veyfert.discord
import veyfert.rest

// Script answers each request with `next` and keeps the requests.
@[heap]
struct Script {
mut:
	requests []rest.HttpRequest
	next     string = '{}'
}

fn (mut s Script) send(req rest.HttpRequest) !rest.HttpResponse {
	s.requests << req
	return rest.HttpResponse{
		status: 200
		body:   s.next
	}
}

fn sf(v u64) discord.Snowflake {
	return discord.Snowflake{v}
}

fn scripted_client() (&Client, &Script) {
	mut c := new_client(token: 'test')
	mut s := &Script{}
	c.rest.transport = s
	c.user = discord.User{
		id: discord.Snowflake{1}
	}
	c.app_id = discord.Snowflake{99}
	c.dispatch(0, 'RAW_GUILD_CREATE', '{"id":"30","name":"Test","owner_id":"1","roles":[{"id":"30","name":"@everyone","permissions":"1024","position":0},{"id":"50","name":"mod","permissions":"2048","position":2},{"id":"51","name":"helper","permissions":"0","position":1}],"channels":[{"id":"40","type":0,"permission_overwrites":[{"id":"30","type":0,"allow":"0","deny":"1024"},{"id":"50","type":0,"allow":"1024","deny":"0"},{"id":"7","type":1,"allow":"8192","deny":"0"}]}],"members":[{"user":{"id":"7","username":"ana"},"roles":["50","51"]}],"stickers":[],"stage_instances":[]}')
	return c, s
}

// hit checks the last request.
fn hit(s &Script, method http.Method, path string) {
	req := s.requests.last()
	assert req.method == method, '${req.method} ${req.url}'
	assert req.url.all_before('?') == rest.api_base + path, req.url
}

fn query_of(s &Script) string {
	return s.requests.last().url.all_after('?')
}

fn test_guild_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '{"id":"30","name":"Renamed"}'
	assert c.guilds.edit(sf(30), name: 'Renamed', reason: 'why')!.name == 'Renamed'
	hit(s, .patch, '/guilds/30')
	assert s.requests.last().body == '{"name":"Renamed"}'
	assert s.requests.last().headers['X-Audit-Log-Reason'] == 'why'
	assert c.guilds.fetch_self(sf(30))!.guild_id or { sf(0) } == sf(30)
	hit(s, .get, '/guilds/30/members/1')
	assert c.guilds.widget_url(sf(30), 'banner2') == '${rest.api_base}/guilds/30/widget.png?style=banner2'
	if _ := c.guilds.incidents(sf(30)) {
		assert false, 'incidents needs one measure'
	}
	c.guilds.incidents(sf(30),
		invites_disabled_until: discord.Nullable[string]{
			is_null: true
		}
	)!
	hit(s, .put, '/guilds/30/incident-actions')
	assert s.requests.last().body == '{"invites_disabled_until":null}'
	s.next = '{"messages":[[{"id":"5","channel_id":"40","content":"hi"}]],"total_results":1}'
	found := c.guilds.search_messages(sf(30),
		content:   'hi there'
		author_id: [sf(7), sf(8)]
		has:       ['link']
	)!
	assert found.total_results == 1 && found.messages[0][0].content == 'hi'
	hit(s, .get, '/guilds/30/messages/search')
	assert query_of(s) == 'limit=25&content=hi+there&author_id=7&author_id=8&has=link'
}

fn test_guild_sub_shorters() ! {
	mut c, mut s := scripted_client()
	if _ := c.guilds.audit.fetch(sf(30), limit: 0) {
		assert false, 'a page of 0 entries'
	}
	s.next = '{"audit_log_entries":[{"id":"1","action_type":22,"changes":[{"key":"name","new_value":"a","old_value":"b"}]}],"users":[]}'
	log := c.guilds.audit.fetch(sf(30), action_type: 22, before: sf(9))!
	assert log.audit_log_entries[0].action_type == 22
	assert (log.audit_log_entries[0].changes or { [] })[0].key == 'name'
	hit(s, .get, '/guilds/30/audit-logs')
	assert query_of(s) == 'limit=50&action_type=22&before=9'

	s.next = '{"guild_id":"30","prompts":[],"default_channel_ids":["40"],"enabled":true,"mode":0}'
	assert c.guilds.onboarding.fetch(sf(30))!.default_channel_ids == [sf(40)]
	hit(s, .get, '/guilds/30/onboarding')
	c.guilds.onboarding.edit(sf(30), enabled: false)!
	hit(s, .put, '/guilds/30/onboarding')
	assert s.requests.last().body == '{"enabled":false}'

	c.guilds.welcome.fetch(sf(30))!
	hit(s, .get, '/guilds/30/welcome-screen')
	c.guilds.welcome.edit(sf(30),
		welcome_channels: [
			discord.WelcomeChannel{
				channel_id:  sf(40)
				description: 'rules'
			},
		]
	)!
	hit(s, .patch, '/guilds/30/welcome-screen')
	assert s.requests.last().body == '{"welcome_channels":[{"channel_id":"40","description":"rules"}]}'

	c.guilds.widget.settings(sf(30))!
	hit(s, .get, '/guilds/30/widget')
	c.guilds.widget.edit(sf(30), enabled: true)!
	hit(s, .patch, '/guilds/30/widget')
	c.guilds.widget.fetch(sf(30))!
	hit(s, .get, '/guilds/30/widget.json')
	s.next = 'PNG'
	assert c.guilds.widget.image(sf(30), 'shield')! == 'PNG'.bytes()
	hit(s, .get, '/guilds/30/widget.png')

	s.next = '[]'
	c.guilds.moderation.list(sf(30))!
	hit(s, .get, '/guilds/30/auto-moderation/rules')
	s.next = '{"id":"3","guild_id":"30","name":"spam","trigger_metadata":{},"actions":[]}'
	rule := c.guilds.moderation.create(sf(30),
		name:             'spam'
		event_type:       1
		trigger_type:     1
		trigger_metadata: discord.AutoModerationTrigger{
			keyword_filter: ['bad']
		}
		actions:          [discord.AutoModerationAction{
			kind: 1
		}]
	)!
	assert rule.name == 'spam'
	hit(s, .post, '/guilds/30/auto-moderation/rules')
	assert s.requests.last().body == '{"name":"spam","event_type":1,"trigger_type":1,"trigger_metadata":{"keyword_filter":["bad"]},"actions":[{"type":1}]}'
	c.guilds.moderation.fetch(sf(30), sf(3))!
	hit(s, .get, '/guilds/30/auto-moderation/rules/3')
	c.guilds.moderation.edit(sf(30), sf(3), enabled: false)!
	hit(s, .patch, '/guilds/30/auto-moderation/rules/3')
	c.guilds.moderation.delete(sf(30), sf(3), '')!
	hit(s, .delete, '/guilds/30/auto-moderation/rules/3')

	s.next = '[]'
	c.guilds.events.list(sf(30), true)!
	hit(s, .get, '/guilds/30/scheduled-events')
	assert query_of(s) == 'with_user_count=true'
	s.next = '{"id":"6","guild_id":"30","name":"Party","scheduled_start_time":"2026-12-01T20:00:00Z"}'
	c.guilds.events.create(sf(30),
		name:                 'Party'
		entity_type:          3
		scheduled_start_time: '2026-12-01T20:00:00Z'
		scheduled_end_time:   '2026-12-01T22:00:00Z'
		entity_metadata:      discord.ScheduledEventMetadata{
			location: 'Park'
		}
	)!
	hit(s, .post, '/guilds/30/scheduled-events')
	assert s.requests.last().body == '{"name":"Party","entity_metadata":{"location":"Park"},"privacy_level":2,"scheduled_start_time":"2026-12-01T20:00:00Z","scheduled_end_time":"2026-12-01T22:00:00Z","entity_type":3}'
	c.guilds.events.fetch(sf(30), sf(6), false)!
	hit(s, .get, '/guilds/30/scheduled-events/6')
	c.guilds.events.edit(sf(30), sf(6), status: 4)!
	hit(s, .patch, '/guilds/30/scheduled-events/6')
	c.guilds.events.delete(sf(30), sf(6), '')!
	hit(s, .delete, '/guilds/30/scheduled-events/6')
	s.next = '[{"guild_scheduled_event_id":"6","user":{"id":"12","username":"eve"}}]'
	assert c.guilds.events.subscribers(sf(30), sf(6), with_member: true)![0].user.username == 'eve'
	hit(s, .get, '/guilds/30/scheduled-events/6/users')
	assert (c.cache.user(sf(12)) or { discord.User{} }).username == 'eve'
}

fn test_stickers_go_through_the_cache_and_upload_as_a_form() ! {
	mut c, mut s := scripted_client()
	assert c.guilds.stickers.list(sf(30))!.len == 0 // from the cache: the guild had none
	assert s.requests.len == 0
	s.next = '{"id":"70","name":"wave","tags":"👋","type":2,"format_type":1}'
	png := discord.File{
		name:         'wave.png'
		data:         [u8(1), 2, 3]
		content_type: 'image/png'
	}
	c.guilds.stickers.create(sf(30), png, name: 'wave', tags: '👋')!
	hit(s, .post, '/guilds/30/stickers')
	req := s.requests.last()
	assert req.headers['Content-Type'].starts_with('multipart/form-data; boundary=')
	assert req.body.contains('name="name"\r\n\r\nwave\r\n')
	assert req.body.contains('name="tags"\r\n\r\n👋\r\n')
	assert req.body.contains('name="file"; filename="wave.png"\r\nContent-Type: image/png')
	assert c.guilds.stickers.fetch(sf(30), sf(70))!.name == 'wave' // cached by create
	assert s.requests.len == 1
	s.next = '{"id":"70","name":"hello","tags":"👋"}'
	c.guilds.stickers.edit(sf(30), sf(70), name: 'hello')!
	hit(s, .patch, '/guilds/30/stickers/70')
	assert c.guilds.stickers.fetch(sf(30), sf(70))!.name == 'hello'
	c.guilds.stickers.delete(sf(30), sf(70), '')!
	hit(s, .delete, '/guilds/30/stickers/70')
	assert c.cache.sticker(sf(30), sf(70)) == none
	c.guilds.stickers.fetch(sf(30), sf(71), force: true)!
	hit(s, .get, '/guilds/30/stickers/71')
}

fn test_channel_shorters_and_permissions_from_the_cache() ! {
	mut c, mut s := scripted_client()
	c.channels.edit_positions(sf(30), [
		ChannelPosition{
			id:       sf(40)
			position: discord.Nullable[int]{
				value: 2
			}
		},
	], '')!
	hit(s, .patch, '/guilds/30/channels')
	assert s.requests.last().body == '[{"id":"40","position":2}]'
	s.next = '{"channel_id":"40","webhook_id":"5"}'
	assert c.channels.add_follower(sf(41), sf(40), '')!.webhook_id == sf(5)
	hit(s, .post, '/channels/41/followers')
	assert s.requests.last().body == '{"webhook_channel_id":"40"}'
	member := c.members.fetch(sf(30), sf(7))!
	// @everyone has VIEW_CHANNEL (1024), denied in the channel; role 50 (SEND_MESSAGES, 2048)
	// gets it back there, and the member's own overwrite adds MANAGE_MESSAGES (8192).
	perms := c.channels.member_permissions(sf(40), member)!
	assert u64(perms) == 1024 | 2048 | 8192
	assert u64(c.channels.role_permissions(sf(40), sf(50))!) == 1024 | 2048
	assert u64(c.channels.role_permissions(sf(40), sf(51))!) == 0
	o := c.channels.overwrites_for(sf(40), member)!
	assert (o.everyone or { discord.Overwrite{} }).deny == '1024'
	assert o.roles.len == 1 && o.roles[0].id == sf(50)
	assert (o.member or { discord.Overwrite{} }).allow == '8192'
	if _ := c.channels.member_permissions(sf(99), member) {
		assert false, 'channel 99 is not cached'
	}
	s.next = '{"permissions":"3072"}'
	assert u64(c.channels.fetch_member_permissions(sf(40), sf(7))!) == 3072
	hit(s, .get, '/channels/40/permissions/member/7')
	assert u64(c.channels.fetch_role_permissions(sf(40), sf(50))!) == 3072
	hit(s, .get, '/channels/40/permissions/role/50')
	c.channels.set_voice_status(sf(42), 'chilling', '')!
	hit(s, .put, '/channels/42/voice-status')
	assert s.requests.last().body == '{"status":"chilling"}'
}

fn test_member_and_role_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '{"user":{"id":"8","username":"bob"},"roles":[]}'
	c.members.resolve(sf(30), '<@!8>')!
	hit(s, .get, '/guilds/30/members/8')
	c.members.resolve(sf(30), '80351110224678912')!
	hit(s, .get, '/guilds/30/members/80351110224678912')
	s.next = '[{"user":{"id":"8","username":"bob"},"roles":[]}]'
	assert (c.members.resolve(sf(30), 'bob')!.user or { discord.User{} }).username == 'bob'
	hit(s, .get, '/guilds/30/members/search')
	assert query_of(s) == 'query=bob&limit=1'
	s.next = '[]'
	if _ := c.members.resolve(sf(30), 'nobody') {
		assert false, 'nobody matches'
	}
	s.next = '{"user":{"id":"9","username":"cy"},"roles":[]}'
	c.members.add(sf(30), sf(9), access_token: 'oauth')!
	hit(s, .put, '/guilds/30/members/9')
	assert s.requests.last().body == '{"access_token":"oauth"}'
	s.next = ''
	c.members.add(sf(30), sf(9), access_token: 'oauth')! // already a member: 204
	hit(s, .put, '/guilds/30/members/9')
	assert c.members.roles(sf(30), sf(7))!.map(it.id) == [sf(50), sf(51)]
	assert c.members.sort_roles(sf(30), sf(7))!.map(it.position) == [2, 1]
	assert u64(c.members.permissions(sf(30), sf(7))!) == 1024 | 2048
	s.next = '{"user":{"id":"1","username":"owner"},"roles":[]}'
	assert u64(c.members.permissions(sf(30), sf(1))!) == u64(discord.all_permissions()) // the owner
	s.next = '{"permissions":"8"}'
	assert u64(c.members.fetch_permissions(sf(30), sf(7))!) == 8
	hit(s, .get, '/guilds/30/permissions/member/7')
	assert c.members.presence(sf(30), sf(7)) == none
	s.next = '{"guild_id":"30","channel_id":"45","user_id":"7","session_id":"x"}'
	assert c.members.voice(sf(30), sf(7))!.channel_id or { sf(0) } == sf(45)
	hit(s, .get, '/guilds/30/voice-states/7')
	timed_out := discord.Member{
		communication_disabled_until: time.now().add(time.hour).format_rfc3339()
	}
	assert c.members.has_timeout(timed_out)
	assert !c.members.has_timeout(discord.Member{})

	s.next = '{"50":3,"51":1}'
	assert c.roles.member_counts(sf(30))!['50'] == 3
	hit(s, .get, '/guilds/30/roles/member-counts')
	s.next = '{"permissions":"2048"}'
	assert u64(c.roles.fetch_permissions(sf(30), sf(50))!) == 2048
	hit(s, .get, '/guilds/30/permissions/role/50')
	s.next = '[{"id":"50","name":"mod","permissions":"0","position":1}]'
	c.roles.edit_positions(sf(30), [
		RolePosition{
			id:       sf(50)
			position: discord.Nullable[int]{
				value: 1
			}
		},
	], '')!
	hit(s, .patch, '/guilds/30/roles')
	assert s.requests.last().body == '[{"id":"50","position":1}]'
	assert (c.cache.role(sf(30), sf(50)) or { discord.Role{} }).position == 1
}

fn test_ban_and_emoji_shorters() ! {
	mut c, mut s := scripted_client()
	c.bans.create(sf(30), sf(7), 0, '')!
	hit(s, .put, '/guilds/30/bans/7')
	c.bans.remove(sf(30), sf(7), '')!
	hit(s, .delete, '/guilds/30/bans/7')
	if _ := c.bans.bulk_create(sf(30), [], 0, '') {
		assert false, 'no users'
	}
	s.next = '{"banned_users":["7"],"failed_users":["8"]}'
	result := c.bans.bulk_create(sf(30), [sf(7), sf(8)], time.hour, 'raid')!
	assert result.failed_users == [sf(8)]
	hit(s, .post, '/guilds/30/bulk-ban')
	assert s.requests.last().body == '{"user_ids":["7","8"],"delete_message_seconds":3600}'
	assert c.cache.banned(sf(30), sf(7)) && c.cache.member(sf(30), sf(7)) == none

	s.next = '{"id":"60","name":"blob"}'
	c.emojis.fetch(sf(30), sf(60))!
	hit(s, .get, '/guilds/30/emojis/60')
	before := s.requests.len
	c.emojis.fetch(sf(30), sf(60))! // now cached
	assert s.requests.len == before
	s.next = '{"id":"60","name":"blobby"}'
	assert c.emojis.edit(sf(30), sf(60), name: 'blobby')!.name or { '' } == 'blobby'
	hit(s, .patch, '/guilds/30/emojis/60')
	assert s.requests.last().body == '{"name":"blobby"}'
}

fn test_application_and_monetization_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '{"items":[{"id":"61","name":"app"}]}'
	assert c.application.list_emojis()![0].name or { '' } == 'app'
	hit(s, .get, '/applications/99/emojis')
	s.next = '{"id":"61","name":"app"}'
	c.application.fetch_emoji(sf(61))!
	hit(s, .get, '/applications/99/emojis/61')
	c.application.create_emoji('app', discord.File{
		name:         'a.png'
		data:         'hi'.bytes()
		content_type: 'image/png'
	})!
	hit(s, .post, '/applications/99/emojis')
	assert s.requests.last().body == '{"name":"app","image":"data:image/png;base64,aGk="}'
	c.application.edit_emoji(sf(61), 'renamed')!
	hit(s, .patch, '/applications/99/emojis/61')
	c.application.delete_emoji(sf(61))!
	hit(s, .delete, '/applications/99/emojis/61')
	s.next = '[]'
	c.application.list_entitlements(user_id: sf(7), sku_ids: [sf(1), sf(2)])!
	hit(s, .get, '/applications/99/entitlements')
	assert query_of(s) == 'limit=100&exclude_ended=false&exclude_deleted=true&user_id=7&sku_ids=1,2'
	s.next = '{"id":"80","sku_id":"1","application_id":"99","type":4}'
	assert c.application.fetch_entitlement(sf(80))!.kind == 4
	hit(s, .get, '/applications/99/entitlements/80')
	c.application.consume_entitlement(sf(80))!
	hit(s, .post, '/applications/99/entitlements/80/consume')
	c.application.create_test_entitlement(sf(1), sf(7), 2)!
	hit(s, .post, '/applications/99/entitlements')
	assert s.requests.last().body == '{"sku_id":"1","owner_id":"7","owner_type":2}'
	c.application.delete_test_entitlement(sf(80))!
	hit(s, .delete, '/applications/99/entitlements/80')
	s.next = '[{"id":"1","type":5,"name":"Premium"},{"id":"2","type":2,"name":"Pack"}]'
	assert c.application.list_skus()!.len == 2
	hit(s, .get, '/applications/99/skus')
	assert c.monetization.list_skus()!.len == 2
	assert c.monetization.fetch_sku(sf(2))!.name == 'Pack'
	if _ := c.monetization.fetch_sku(sf(3)) {
		assert false, 'no SKU 3'
	}
	s.next = '{"id":"99","name":"Bot","verify_key":"k"}'
	assert c.application.fetch()!.verify_key == 'k'
	hit(s, .get, '/applications/@me')
	c.application.edit(description: 'A bot')!
	hit(s, .patch, '/applications/@me')
	assert s.requests.last().body == '{"description":"A bot"}'
	s.next = '{"application_id":"99","instance_id":"i-1","launch_id":"l","location":{},"users":["7"]}'
	assert c.application.activity_instance('i-1')!.users == [sf(7)]
	hit(s, .get, '/applications/99/activity-instances/i-1')
	s.next = '[]'
	c.monetization.subscriptions(sf(1), user_id: sf(7))!
	hit(s, .get, '/skus/1/subscriptions')
	assert query_of(s) == 'limit=50&user_id=7'
	s.next = '{"id":"90","user_id":"7","sku_ids":["1"],"entitlement_ids":[],"current_period_start":"","current_period_end":"","status":0}'
	c.monetization.fetch_subscription(sf(1), sf(90))!
	hit(s, .get, '/skus/1/subscriptions/90')
}

fn test_the_application_id_comes_from_discord_when_ready_did_not_give_it() ! {
	mut c := new_client(token: 'test')
	mut s := &Script{
		next: '{"id":"77","name":"Bot"}'
	}
	c.rest.transport = s
	assert c.application_id()! == sf(77)
	assert c.application_id()! == sf(77)
	assert s.requests.len == 1 // asked once
	hit(s, .get, '/applications/@me')
	s.next = '{"id":"5","username":"me"}'
	assert c.bot_id()! == sf(5)
	hit(s, .get, '/users/@me')
}

fn test_interaction_shorters() ! {
	mut c, mut s := scripted_client()
	c.interactions.reply(sf(3), 'tok', 4, content: 'hi', ephemeral: true)!
	hit(s, .post, '/interactions/3/tok/callback')
	assert s.requests.last().body == '{"type":4,"data":{"content":"hi","flags":64}}'
	s.next = '{"id":"5","channel_id":"40","content":"hi"}'
	c.interactions.fetch_response('tok', sf(5))!
	hit(s, .get, '/webhooks/99/tok/messages/5')
	c.interactions.fetch_original('tok')!
	hit(s, .get, '/webhooks/99/tok/messages/@original')
	c.interactions.edit_message('tok', sf(5), content: 'edited')!
	hit(s, .patch, '/webhooks/99/tok/messages/5')
	c.interactions.edit_original('tok', content: 'edited')!
	hit(s, .patch, '/webhooks/99/tok/messages/@original')
	c.interactions.delete_response('tok', sf(5))!
	hit(s, .delete, '/webhooks/99/tok/messages/5')
	c.interactions.delete_original('tok')!
	hit(s, .delete, '/webhooks/99/tok/messages/@original')
	c.interactions.followup('tok', content: 'more')!
	hit(s, .post, '/webhooks/99/tok')
	assert query_of(s) == 'wait=true'
}

fn test_invite_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '{"type":0,"code":"abc","guild":{"id":"30","name":"Test"},"approximate_member_count":4}'
	invite := c.invites.fetch('abc')!
	assert invite.code == 'abc' && invite.approximate_member_count or { 0 } == 4
	assert (invite.guild or { discord.Guild{} }).name == 'Test'
	hit(s, .get, '/invites/abc')
	assert query_of(s) == 'with_counts=true'
	c.invites.delete('abc', 'spam')!
	hit(s, .delete, '/invites/abc')
	c.invites.create(sf(40), max_age: 3600, unique: true)!
	hit(s, .post, '/channels/40/invites')
	assert s.requests.last().body == '{"max_age":3600,"unique":true}'
	s.next = '[]'
	c.invites.list_channel(sf(40))!
	hit(s, .get, '/channels/40/invites')
	c.invites.list_guild(sf(30))!
	hit(s, .get, '/guilds/30/invites')
	s.next = 'user_id\n7\n8\n'
	assert c.invites.target_users('abc')! == [sf(7), sf(8)]
	hit(s, .get, '/invites/abc/target-users')
	c.invites.update_target_users('abc', [sf(7), sf(8)])!
	hit(s, .put, '/invites/abc/target-users')
	body := s.requests.last().body
	assert body.contains('name="target_users_file"; filename="users.csv"\r\nContent-Type: text/csv\r\n\r\nusers\n7\n8\r\n')
	s.next = '{"status":2,"total_users":2,"processed_users":2}'
	assert c.invites.job_status('abc')!.status == 2
	hit(s, .get, '/invites/abc/target-users/job-status')
	c.invites.add_target_user('abc', sf(9))!
	hit(s, .put, '/invites/abc/target-users/9')
	c.invites.remove_target_user('abc', sf(9))!
	hit(s, .delete, '/invites/abc/target-users/9')
	c.invites.bulk_add_target_users('abc', [sf(9)])!
	hit(s, .post, '/invites/abc/target-users/bulk-add')
	assert s.requests.last().body == '{"user_ids":["9"]}'
	c.invites.bulk_remove_target_users('abc', [sf(9)])!
	hit(s, .post, '/invites/abc/target-users/bulk-delete')
}

fn test_soundboard_stage_template_and_voice_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '[{"name":"quack","sound_id":"1","volume":1.0,"available":true}]'
	assert c.soundboard.defaults()![0].name == 'quack'
	hit(s, .get, '/soundboard-default-sounds')
	c.soundboard.send(sf(45), sf(1))!
	hit(s, .post, '/channels/45/send-soundboard-sound')
	assert s.requests.last().body == '{"sound_id":"1"}'
	s.next = '{"items":[]}'
	c.soundboard.list(sf(30))!
	hit(s, .get, '/guilds/30/soundboard-sounds')
	s.next = '{"name":"boom","sound_id":"2","volume":0.5,"available":true}'
	c.soundboard.fetch(sf(30), sf(2))!
	hit(s, .get, '/guilds/30/soundboard-sounds/2')
	c.soundboard.create(sf(30), discord.File{
		name:         'boom.ogg'
		data:         'ok'.bytes()
		content_type: 'audio/ogg'
	}, name: 'boom', volume: 0.5)!
	hit(s, .post, '/guilds/30/soundboard-sounds')
	assert s.requests.last().body == '{"name":"boom","sound":"data:audio/ogg;base64,b2s=","volume":0.5}'
	c.soundboard.edit(sf(30), sf(2), name: 'bang')!
	hit(s, .patch, '/guilds/30/soundboard-sounds/2')
	c.soundboard.delete(sf(30), sf(2), '')!
	hit(s, .delete, '/guilds/30/soundboard-sounds/2')

	s.next = '{"id":"8","guild_id":"30","channel_id":"46","topic":"Q&A","privacy_level":2}'
	c.stages.create(sf(46), topic: 'Q&A')!
	hit(s, .post, '/stage-instances')
	assert s.requests.last().body == '{"channel_id":"46","topic":"Q&A","privacy_level":2,"send_start_notification":false}'
	before := s.requests.len
	assert c.stages.fetch(sf(46))!.topic == 'Q&A' // cached by create
	assert s.requests.len == before
	c.stages.edit(sf(46), topic: 'AMA')!
	hit(s, .patch, '/stage-instances/46')
	c.stages.delete(sf(46), '')!
	hit(s, .delete, '/stage-instances/46')
	assert c.cache.stage_instance(sf(46)) == none
	c.stages.fetch(sf(46))!
	hit(s, .get, '/stage-instances/46')

	s.next = '{"code":"tpl","name":"T","usage_count":0,"creator_id":"1","created_at":"","updated_at":"","source_guild_id":"30","serialized_source_guild":{}}'
	c.templates.fetch('tpl')!
	hit(s, .get, '/guilds/templates/tpl')
	if _ := c.templates.create(sf(30)) {
		assert false, 'a template needs a name'
	}
	c.templates.create(sf(30), name: 'T')!
	hit(s, .post, '/guilds/30/templates')
	assert s.requests.last().body == '{"name":"T"}'
	c.templates.sync(sf(30), 'tpl')!
	hit(s, .put, '/guilds/30/templates/tpl')
	c.templates.edit(sf(30), 'tpl', name: 'U')!
	hit(s, .patch, '/guilds/30/templates/tpl')
	c.templates.delete(sf(30), 'tpl')!
	hit(s, .delete, '/guilds/30/templates/tpl')
	s.next = '[]'
	c.templates.list(sf(30))!
	hit(s, .get, '/guilds/30/templates')

	c.voice_states.request_speak(sf(30), sf(46), false)!
	hit(s, .patch, '/guilds/30/voice-states/@me')
	assert s.requests.last().body == '{"channel_id":"46","request_to_speak_timestamp":null}'
	c.voice_states.request_speak(sf(30), sf(46), true)!
	assert s.requests.last().body.starts_with('{"channel_id":"46","request_to_speak_timestamp":"20')
	c.voice_states.set_suppress(sf(30), sf(46), false)!
	hit(s, .patch, '/guilds/30/voice-states/@me')
	assert s.requests.last().body == '{"channel_id":"46","suppress":false}'
	c.voice_states.set_suppress(sf(30), sf(46), true, user_id: sf(7))!
	hit(s, .patch, '/guilds/30/voice-states/7')
}

fn test_message_thread_user_and_webhook_shorters() ! {
	mut c, mut s := scripted_client()
	s.next = '{"id":"5","channel_id":"40","content":"poll"}'
	assert c.messages.end_poll(sf(40), sf(5))!.content == 'poll'
	hit(s, .post, '/channels/40/polls/5/expire')
	s.next = '{"users":[{"id":"12","username":"eve"}]}'
	assert c.messages.answer_voters(sf(40), sf(5), 1, limit: 10)![0].username == 'eve'
	hit(s, .get, '/channels/40/polls/5/answers/1')
	assert query_of(s) == 'limit=10'

	s.next = '{"id":"42","type":11,"name":"t"}'
	c.threads.edit(sf(42), name: 't', archived: true)!
	hit(s, .patch, '/channels/42')
	assert s.requests.last().body == '{"name":"t","archived":true}'
	c.threads.lock(sf(42), true, '')!
	assert s.requests.last().body == '{"locked":true}'
	assert c.cache.channel(sf(42)) != none
	s.next = '{"id":"42","user_id":"7","join_timestamp":"","flags":0}'
	c.threads.fetch_member(sf(42), sf(7), true)!
	hit(s, .get, '/channels/42/thread-members/7')
	assert query_of(s) == 'with_member=true'
	s.next = '[]'
	c.threads.list_members(sf(42), after: sf(3))!
	hit(s, .get, '/channels/42/thread-members')
	assert query_of(s) == 'with_member=false&limit=100&after=3'
	s.next = '{"threads":[{"id":"43","type":12}],"members":[],"has_more":false}'
	assert c.threads.list_archived(sf(40), private: true)!.threads.len == 1
	hit(s, .get, '/channels/40/threads/archived/private')
	assert c.cache.channel(sf(43)) != none
	c.threads.list_archived(sf(40))!
	hit(s, .get, '/channels/40/threads/archived/public')
	c.threads.list_joined_archived_private(sf(40), before: sf(9))!
	hit(s, .get, '/channels/40/users/@me/threads/archived/private')
	assert query_of(s) == 'limit=50&before=9'

	c.users.delete_dm(sf(47))!
	hit(s, .delete, '/channels/47')

	s.next = '{"id":"20","name":"hook"}'
	c.webhooks.edit(sf(20), name: 'hook')!
	hit(s, .patch, '/webhooks/20')
	assert s.requests.last().headers['Authorization'] == 'Bot test'
	c.webhooks.edit(sf(20), name: 'hook', token: 'wt')!
	hit(s, .patch, '/webhooks/20/wt')
	assert 'Authorization' !in s.requests.last().headers
	c.webhooks.fetch(sf(20))!
	hit(s, .get, '/webhooks/20')
	c.webhooks.fetch(sf(20), token: 'wt')!
	hit(s, .get, '/webhooks/20/wt')
	s.next = '{"id":"5","channel_id":"40","content":"hook"}'
	c.webhooks.fetch_message(sf(20), 'wt', sf(5), thread_id: sf(42))!
	hit(s, .get, '/webhooks/20/wt/messages/5')
	assert query_of(s) == 'thread_id=42'
	c.webhooks.edit_message(sf(20), 'wt', sf(5), content: 'edited')!
	hit(s, .patch, '/webhooks/20/wt/messages/5')
	assert s.requests.last().body == '{"content":"edited"}'
	c.webhooks.delete_message(sf(20), 'wt', sf(5))!
	hit(s, .delete, '/webhooks/20/wt/messages/5')
	s.next = '[]'
	c.webhooks.list_guild(sf(30))!
	hit(s, .get, '/guilds/30/webhooks')
}
