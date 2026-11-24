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

const message_json = '{"id":"1100","channel_id":"55","author":{"id":"80351110224678912","username":"nelly","global_name":null,"avatar":"8342729096ea3675442027381ff50dfe","discriminator":"0","public_flags":64,"flags":64},"content":"hola","timestamp":"2026-11-24T10:00:00.000000+00:00","edited_timestamp":null,"tts":false,"mention_everyone":false,"mentions":[],"mention_roles":[],"attachments":[],"embeds":[],"pinned":false,"type":0,"flags":0,"components":[{"type":1,"components":[{"type":2,"style":1,"label":"Sí","custom_id":"yes"}]}]}'

fn test_generated_endpoints_build_the_request() ! {
	mut a, replay := replay_api(['[${message_json}]', message_json])
	messages := a.list_messages(discord.Snowflake{55}, limit: 3, before: discord.Snowflake{1200})!
	assert replay.requests[0].method == .get
	assert replay.requests[0].url.ends_with('/channels/55/messages?before=1200&limit=3')
	assert messages.len == 1
	assert messages[0].content == 'hola'
	assert messages[0].author.username == 'nelly'
	assert messages[0].components.text.contains('"custom_id":"yes"')
	sent := a.create_message(discord.Snowflake{55}, MessageCreateRequest{ content: 'hola' },
		reason: 'test'
	)!
	assert sent.id == discord.Snowflake{1100}
	assert replay.requests[1].method == .post
	assert replay.requests[1].body == '{"content":"hola"}'
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
