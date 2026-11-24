module veyfert

import json2
import time
import veyfert.discord
import veyfert.rest

@[heap]
struct Recorder {
mut:
	requests []rest.HttpRequest
}

fn (mut r Recorder) send(req rest.HttpRequest) !rest.HttpResponse {
	r.requests << req
	return rest.HttpResponse{
		status: 200
		body:   '{"id":"99","channel_id":"40","author":{"id":"1","username":"bot"},"content":"","timestamp":""}'
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test')
	rec := &Recorder{}
	c.rest.transport = rec
	return c, rec
}

fn interaction(kind int, data string) string {
	return '{"id":"10","application_id":"20","type":${kind},"token":"tok","guild_id":"30","channel_id":"40","member":{"user":{"id":"7","username":"ana"},"roles":[]},"message":{"id":"55","channel_id":"40","author":{"id":"1","username":"bot"},"content":"","timestamp":""},"data":${data}}'
}

fn last_body(rec &Recorder) string {
	return if rec.requests.len > 0 { rec.requests.last().body } else { '' }
}

fn test_v1_components_match_discords_json() {
	row := discord.action_row(discord.button(style: .primary, label: 'Yes', custom_id: 'yes'), discord.button(
		label: 'Docs'
		url:   'https://discord.com'
	), discord.button(
		label:     'No'
		custom_id: 'no'
		disabled:  true
		emoji:     discord.Emoji{
			name: '🛑'
		}
	))
	assert json2.encode(row) == '{"type":1,"components":[{"type":2,"custom_id":"yes","style":1,"label":"Yes"},{"type":2,"style":5,"label":"Docs","url":"https://discord.com"},{"type":2,"custom_id":"no","style":2,"label":"No","emoji":{"name":"🛑"},"disabled":true}]}'
	pick := discord.string_select(
		custom_id:   'class'
		placeholder: 'Choose a class'
		max_values:  2
		options:     [discord.SelectOption{
			label: 'Rogue'
			value: 'rogue'
		}, discord.SelectOption{
			label:       'Mage'
			value:       'mage'
			description: 'Turns things into frogs'
		}]
	)
	assert json2.encode(pick) == '{"type":3,"custom_id":"class","placeholder":"Choose a class","max_values":2,"options":[{"label":"Rogue","value":"rogue"},{"label":"Mage","value":"mage","description":"Turns things into frogs"}]}'
	assert json2.encode(discord.channel_select(custom_id: 'where', channel_types: [0])) == '{"type":8,"custom_id":"where","channel_types":[0]}'
}

fn test_v2_components_nest_their_single_children_as_objects() {
	card := discord.container([
		discord.section(['**Veyfert**', 'A V library'], discord.thumbnail('https://x.dev/a.png',
			description: 'logo'
		)),
		discord.separator(spacing: .large),
		discord.media_gallery(discord.MediaItem{
			media: discord.Media{'https://x.dev/b.png'}
		}),
		discord.file_component('attachment://notes.txt'),
		discord.action_row(discord.button(label: 'Ok', custom_id: 'ok')),
	], accent_color: 0x5865F2)
	assert json2.encode(card) == '{"type":17,"accent_color":5793266,"components":[{"type":9,"components":[{"type":10,"content":"**Veyfert**"},{"type":10,"content":"A V library"}],"accessory":{"type":11,"media":{"url":"https://x.dev/a.png"},"description":"logo"}},{"type":14,"divider":true,"spacing":2},{"type":12,"items":[{"media":{"url":"https://x.dev/b.png"}}]},{"type":13,"file":{"url":"attachment://notes.txt"}},{"type":1,"components":[{"type":2,"custom_id":"ok","style":2,"label":"Ok"}]}]}'
	input := discord.label('Your name', discord.text_input(custom_id: 'name', max_length: 32), 'As shown')
	assert json2.encode(input) == '{"type":18,"label":"Your name","description":"As shown","component":{"type":4,"custom_id":"name","style":1,"max_length":32}}'
}

fn test_the_payload_sets_flags_and_validates_embeds() ! {
	v2 := message_payload(components: [discord.text_display('hi')], ephemeral: true)!
	assert (v2.flags or { 0 }) == discord.message_flag_components_v2 | discord.message_flag_ephemeral
	v1 := message_payload(
		components: [discord.action_row(discord.button(label: 'a', custom_id: 'a'))]
	)!
	assert v1.flags == none
	with_poll := message_payload(
		poll: discord.poll('Tabs or spaces?', ['Tabs', 'Spaces'], 24, false)
	)!
	assert json2.encode(with_poll) == '{"poll":{"question":{"text":"Tabs or spaces?"},"answers":[{"poll_media":{"text":"Tabs"}},{"poll_media":{"text":"Spaces"}}],"allow_multiselect":false,"duration":24}}'
	mut failed := ''
	message_payload(
		embeds: [discord.Embed{
			title: 'x'.repeat(257)
		}]
	) or { failed = err.msg() }
	assert failed.contains('title has 257 characters')
	failed = ''
	discord.Embed{
		fields: []discord.EmbedField{len: 26, init: discord.EmbedField{'a', 'b', false}}
	}.validate() or { failed = err.msg() }
	assert failed.contains('26 fields')
	failed = ''
	discord.Embed{
		fields: []discord.EmbedField{len: 7, init: discord.EmbedField{'n', 'v'.repeat(1000), false}}
	}.validate() or { failed = err.msg() }
	assert failed.contains('6000')
}

@[CustomId('confirm')]
struct Confirm {}

fn (h Confirm) run(mut ctx ComponentContext) ! {
	ctx.update(content: 'confirmed', components: [])!
}

@[CustomIdPrefix('vote:')]
struct Vote {}

fn (h Vote) run(mut ctx ComponentContext) ! {
	ctx.write(content: 'vote ${ctx.custom_id.all_after(':')} ${ctx.values}', ephemeral: true)!
}

@[CustomIdPrefix('vote:extra:')]
struct VoteExtra {}

fn (h VoteExtra) run(mut ctx ComponentContext) ! {
	ctx.defer_update()!
}

fn test_components_route_by_exact_id_then_longest_prefix() {
	mut c, rec := recording_client()
	c.components.add(Vote{})
	c.components.add(VoteExtra{})
	c.components.add(Confirm{})
	c.handle_interaction(interaction(3, '{"custom_id":"confirm","component_type":2}'))
	assert last_body(rec) == '{"type":7,"data":{"content":"confirmed","components":[]}}'
	c.handle_interaction(interaction(3, '{"custom_id":"vote:3","component_type":3,"values":["a","b"]}'))
	assert last_body(rec) == '{"type":4,"data":{"content":"vote 3 [\'a\', \'b\']","flags":64}}'
	c.handle_interaction(interaction(3, '{"custom_id":"vote:extra:1","component_type":2}'))
	assert last_body(rec) == '{"type":6,"data":{}}'
	assert rec.requests.len == 3
	c.handle_interaction(interaction(3, '{"custom_id":"unknown","component_type":2}'))
	assert rec.requests.len == 3
}

enum Mood {
	happy  @[Label: 'Happy']
	tired
}

@[Modal(custom_id: 'feedback', title: 'Your feedback')]
struct Feedback {
mut:
	text  string  @[Label: 'Tell us'; MaxLength: 500; Paragraph]
	email ?string @[Desc: 'We answer there'; Label: 'Email']
	mood  ?Mood   @[Label: 'Mood']
}

fn (f Feedback) submit(mut ctx ModalContext) ! {
	ctx.write(content: '${f.text}|${f.email or { '-' }}|${f.mood or { Mood.happy }}')!
}

fn test_a_modal_is_built_from_its_fields() ! {
	mut c, rec := recording_client()
	mut ctx := &InteractionContext{
		interaction: json2.decode[discord.Interaction](interaction(2, '{"id":"1","name":"x","type":1}'))!
		client:      c
	}
	ctx.modal(Feedback{
		email: 'ana@x.dev'
	})!
	assert last_body(rec) == '{"type":9,"data":{"custom_id":"feedback","title":"Your feedback","components":[{"type":18,"label":"Tell us","component":{"type":4,"custom_id":"text","style":2,"required":true,"max_length":500}},{"type":18,"label":"Email","description":"We answer there","component":{"type":4,"custom_id":"email","style":1,"required":false,"value":"ana@x.dev"}},{"type":18,"label":"Mood","component":{"type":3,"custom_id":"mood","required":false,"options":[{"label":"Happy","value":"happy"},{"label":"tired","value":"tired"}]}}]}}'
	ctx.modal(Feedback{}) or { assert err.msg().contains('first answer') }
}

fn test_a_submitted_modal_fills_the_form() {
	mut c, rec := recording_client()
	c.modals.add(Feedback{})
	c.handle_interaction(interaction(5, '{"custom_id":"feedback","components":[{"type":18,"id":1,"component":{"type":4,"id":2,"custom_id":"text","value":"great"}},{"type":18,"id":3,"component":{"type":4,"id":4,"custom_id":"email","value":""}},{"type":18,"id":5,"component":{"type":3,"id":6,"custom_id":"mood","values":["tired"]}}]}'))
	assert last_body(rec) == '{"type":4,"data":{"content":"great|-|tired"}}'
	// Older modals send their inputs inside action rows.
	c.handle_interaction(interaction(5, '{"custom_id":"feedback","components":[{"type":1,"components":[{"type":4,"custom_id":"text","value":"old"}]}]}'))
	assert last_body(rec) == '{"type":4,"data":{"content":"old|-|happy"}}'
}

// wait_collector blocks until a wait_for has registered, so a test dispatches after it.
fn wait_collector(mut c Client) {
	for _ in 0 .. 200 {
		c.mu.lock()
		n := c.collectors['INTERACTION_CREATE'].len
		c.mu.unlock()
		if n > 0 {
			return
		}
		time.sleep(5 * time.millisecond)
	}
	panic('no collector registered')
}

fn test_wait_for_component_takes_the_click_from_the_handlers() ! {
	mut c, rec := recording_client()
	c.components.add(Confirm{})
	mut ctx := &InteractionContext{
		interaction: json2.decode[discord.Interaction](interaction(2, '{"id":"1","name":"x","type":1}'))!
		client:      c
	}
	got := chan string{cap: 1}
	spawn fn (mut ctx InteractionContext, got chan string) {
		mut click := ctx.wait_for_component(
			message_id: discord.Snowflake{55}
			timeout:    2 * time.second
		) or {
			got <- 'timeout'
			return
		}
		click.update(content: 'clicked ${click.custom_id}') or {}
		got <- click.custom_id
	}(mut ctx, got)
	wait_collector(mut c)
	// A click by someone else is not for this wait; it goes to the handlers.
	c.dispatch(0, 'INTERACTION_CREATE', interaction(3, '{"custom_id":"confirm","component_type":2}').replace('"id":"7","username":"ana"',
		'"id":"8","username":"bob"'))
	assert c.interaction_jobs.len == 1
	c.dispatch(0, 'INTERACTION_CREATE', interaction(3, '{"custom_id":"confirm","component_type":2}'))
	assert <-got == 'confirm'
	assert c.interaction_jobs.len == 1
	assert last_body(rec) == '{"type":7,"data":{"content":"clicked confirm"}}'
}

fn test_wait_for_component_times_out() ! {
	mut c, _ := recording_client()
	mut ctx := &InteractionContext{
		interaction: json2.decode[discord.Interaction](interaction(2, '{"id":"1","name":"x","type":1}'))!
		client:      c
	}
	started := time.now()
	assert ctx.wait_for_component(message_id: discord.Snowflake{55}, timeout: 50 * time.millisecond) == none
	assert time.since(started) >= 50 * time.millisecond
}

fn test_wait_for_modal_returns_the_filled_form() ! {
	mut c, rec := recording_client()
	mut ctx := &InteractionContext{
		interaction: json2.decode[discord.Interaction](interaction(2, '{"id":"1","name":"x","type":1}'))!
		client:      c
	}
	got := chan string{cap: 1}
	spawn fn (mut ctx InteractionContext, got chan string) {
		form, mut sent := ctx.wait_for_modal(Feedback{}, 2 * time.second) or {
			got <- 'timeout'
			return
		}
		sent.write(content: 'thanks') or {}
		got <- form.text
	}(mut ctx, got)
	wait_collector(mut c)
	assert rec.requests[0].body.starts_with('{"type":9,')
	c.dispatch(0, 'INTERACTION_CREATE', interaction(5, '{"custom_id":"feedback","components":[{"type":18,"component":{"type":4,"custom_id":"text","value":"hello"}}]}'))
	assert <-got == 'hello'
	assert c.interaction_jobs.len == 0
	assert last_body(rec) == '{"type":4,"data":{"content":"thanks"}}'
}
