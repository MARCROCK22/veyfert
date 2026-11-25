module api

import veyfert.discord
import veyfert.rest

// Replay answers requests in turn and keeps them.
@[heap]
struct Replay {
mut:
	bodies   []string
	requests []rest.HttpRequest
}

fn (mut r Replay) send(req rest.HttpRequest) !rest.HttpResponse {
	r.requests << req
	body := if r.bodies.len > 0 { r.bodies[0] } else { '{}' }
	if r.bodies.len > 0 {
		r.bodies.delete(0)
	}
	return rest.HttpResponse{
		status: 200
		body:   body
	}
}

fn replay_api(bodies []string) (Api, &Replay) {
	mut replay := &Replay{
		bodies: bodies
	}
	mut r := &rest.Rest{
		token:      'test-token'
		user_agent: 'test'
		transport:  replay
	}
	return new(mut r), replay
}

const message_json = '{"id":"1100","channel_id":"55","author":{"id":"80351110224678912","username":"nelly","global_name":null,"avatar":"8342729096ea3675442027381ff50dfe","discriminator":"0","public_flags":64,"flags":64},"content":"hello","timestamp":"2026-11-24T10:00:00.000000+00:00","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":0,"flags":0,"components":[{"type":1,"components":[{"type":2,"style":1,"label":"Yes","custom_id":"yes"}]}]}'

fn test_generated_endpoints_build_the_request() ! {
	mut a, replay := replay_api(['[${message_json}]', message_json])
	messages := a.list_messages(discord.Snowflake{55}, limit: 3, before: discord.Snowflake{1200})!
	assert replay.requests[0].method == .get
	assert replay.requests[0].url.ends_with('/channels/55/messages?before=1200&limit=3')
	assert messages.len == 1
	assert messages[0].content == 'hello'
	assert messages[0].author.username == 'nelly'
	assert messages[0].components.text.contains('"custom_id":"yes"')
	sent := a.create_message(discord.Snowflake{55}, MessageCreateRequest{ content: 'hello' },
		reason: 'test'
	)!
	assert sent.id == discord.Snowflake{1100}
	assert replay.requests[1].method == .post
	assert replay.requests[1].body == '{"content":"hello"}'
	assert replay.requests[1].headers['X-Audit-Log-Reason'] == 'test'
}

fn test_patch_bodies_tell_absent_from_null() ! {
	mut a, replay := replay_api(['{"id":"1","name":"g"}'])
	a.update_guild(discord.Snowflake{1}, GuildPatchRequestPartial{
		name:        'renamed'
		description: discord.Nullable[string]{
			is_null: true
		}
		afk_timeout: discord.Nullable[int]{
			value: 60
		}
	})!
	assert replay.requests[0].method == .patch
	assert replay.requests[0].body == '{"name":"renamed","description":null,"afk_timeout":60}'
}

fn test_array_query_parameters_repeat_and_string_enums_are_constants() ! {
	mut a, replay := replay_api(['{}', '[]'])
	_ := a.guild_search(discord.Snowflake{30},
		content:     'a b'
		author_id:   [discord.Snowflake{1}, discord.Snowflake{2}]
		author_type: [author_type_no_bot]
		has:         [has_option_link, has_option_image]
	)!
	assert replay.requests[0].url.ends_with('/guilds/30/messages/search?content=a+b&author_id=1&author_id=2&author_type=-bot&has=link&has=image')
	// A parameter that takes a string or a list is a list.
	_ := a.get_entitlements(discord.Snowflake{20}, sku_ids: [discord.Snowflake{5}])!
	assert replay.requests[1].url.ends_with('/applications/20/entitlements?sku_ids=5')
	assert oauth2_scopes_identify == 'identify' && available_locales_enum_en_us == 'en-US'
}

fn test_multipart_endpoints_send_their_fields_and_file() ! {
	mut a, replay := replay_api(['{"id":"7","name":"wave","tags":"hand","type":2}'])
	sticker := a.create_guild_sticker(discord.Snowflake{30}, CreateGuildStickerForm{
		name: 'wave'
		tags: 'hand'
	}, discord.File{
		name:         'wave.png'
		data:         [u8(1), 2, 3]
		content_type: 'image/png'
	}, reason: 'new sticker')!
	assert sticker.name == 'wave'
	req := replay.requests[0]
	assert req.method == .post && req.url.ends_with('/guilds/30/stickers')
	assert req.headers['Content-Type'].starts_with('multipart/form-data; boundary=')
	assert req.headers['X-Audit-Log-Reason'] == 'new%20sticker'
	assert req.body.contains('name="name"\r\n\r\nwave\r\n')
	assert req.body.contains('name="tags"\r\n\r\nhand\r\n')
	assert !req.body.contains('name="description"') // none leaves it out
	assert req.body.contains('name="file"; filename="wave.png"\r\nContent-Type: image/png\r\n\r\n\x01\x02\x03\r\n')
	a.update_invite_target_users('abc', discord.File{
		name:         'users.csv'
		data:         'user_id\n7\n'.bytes()
		content_type: 'text/csv'
	})!
	assert replay.requests[1].method == .put
	assert replay.requests[1].url.ends_with('/invites/abc/target-users')
	assert replay.requests[1].body.contains('name="target_users_file"; filename="users.csv"')
}
