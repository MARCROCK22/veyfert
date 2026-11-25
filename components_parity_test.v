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
		body:   '{"id":"900","channel_id":"40","author":{"id":"1","username":"bot"},"content":"","timestamp":""}'
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test')
	rec := &Recorder{}
	c.rest.transport = rec
	return c, rec
}

fn interaction(kind int, user string, data string) string {
	return '{"id":"10","application_id":"20","type":${kind},"token":"tok","guild_id":"30","channel_id":"40","member":{"user":{"id":"${user}","username":"u${user}"},"roles":[],"permissions":"0"},"message":{"id":"55","channel_id":"40","content":""},"data":${data}}'
}

fn click(user string, custom_id string) string {
	return interaction(3, user, '{"custom_id":"${custom_id}","component_type":2}')
}

@[heap]
struct Log {
mut:
	steps []string
}

fn (mut l Log) add(step string) {
	l.steps << step
}

@[CustomIdRegex('^vote:[0-9]+$')]
struct Vote {
	log &Log
}

fn (v Vote) run(mut ctx ComponentContext) ! {
	mut l := v.log
	l.add('vote ${ctx.custom_id}')
}

// VoteAdmin takes the same IDs first, but only for user 99.
@[CustomIdPrefix('vote:')]
struct VoteAdmin {
	log &Log
}

fn (v VoteAdmin) filter(mut ctx ComponentContext) bool {
	return ctx.author().id == discord.Snowflake{99}
}

fn (v VoteAdmin) run(mut ctx ComponentContext) ! {
	mut l := v.log
	l.add('admin ${ctx.custom_id}')
}

fn test_regex_routes_and_filters_pick_the_handler() {
	mut c, _ := recording_client()
	mut log := &Log{}
	c.components.add(Vote{log})
	c.components.add(VoteAdmin{log})
	c.handle_interaction(click('7', 'vote:12')) // the prefix's filter passes; the regex takes it
	c.handle_interaction(click('99', 'vote:12'))
	c.handle_interaction(click('7', 'vote:x')) // neither: the filter refuses, the regex misses
	assert log.steps == ['vote vote:12', 'admin vote:12']
}

@[CustomIdRegex('^ban:')]
@[Modal(custom_id: 'ban', title: 'Ban')]
struct BanForm {
mut:
	reason string @[Label: 'Reason']
}

fn (b BanForm) submit(mut ctx ModalContext) ! {
	ctx.write(content: '${ctx.custom_id}: ${b.reason}')!
}

@[Declare(name: 'ask', description: 'Opens the ban form')]
struct Ask {}

fn (a Ask) run(mut ctx CommandContext) ! {
	ctx.modal(BanForm{}, custom_id: 'ban:42')!
}

fn test_a_modal_opens_with_a_dynamic_id_and_a_regex_routes_its_submission() {
	mut c, rec := recording_client()
	c.commands.add(Ask{})
	c.modals.add(BanForm{})
	c.handle_interaction(interaction(2, '7', '{"id":"1","name":"ask","type":1}'))
	assert rec.requests.last().body.contains('"custom_id":"ban:42"')
	c.handle_interaction(interaction(5, '7', '{"custom_id":"ban:42","components":[{"type":1,"components":[{"type":4,"custom_id":"reason","value":"spam"}]}]}'))
	assert rec.requests.last().body.contains('"content":"ban:42: spam"')
}

@[discord.Event('TEST_TICK')]
struct Tick {
	n int
}

fn collectors_of(mut c Client, name string) int {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return (c.collectors[name] or { map[int]Collector{} }).len
}

fn wait_collector(mut c Client, name string) {
	for _ in 0 .. 500 {
		if collectors_of(mut c, name) > 0 {
			return
		}
		time.sleep(2 * time.millisecond)
	}
	assert false, 'the collector never started'
}

fn test_collect_gathers_events_until_max_and_cleans_up() {
	mut c := new_client(token: 'test')
	mut log := &Log{}
	t := spawn fn [mut c, mut log] () CollectStop {
		return c.collect[Tick](fn (t Tick) bool {
			return t.n > 0
		}, fn [mut log] (t Tick, mut _ Client) ! {
			log.add('tick ${t.n}')
		}, max: 2, timeout: 5 * time.second)
	}()
	wait_collector(mut c, 'TEST_TICK')
	c.dispatch(0, 'TEST_TICK', '{"n":0}') // filtered out
	c.dispatch(0, 'TEST_TICK', '{"n":1}')
	c.dispatch(0, 'TEST_TICK', '{"n":2}')
	assert t.wait() == .max
	assert log.steps == ['tick 1', 'tick 2']
	assert collectors_of(mut c, 'TEST_TICK') == 0
}

fn test_collect_ends_when_idle_or_when_the_callback_stops_it() {
	mut c := new_client(token: 'test')
	assert c.collect[Tick](fn (_ Tick) bool {
		return true
	}, fn (_ Tick, mut _ Client) ! {}, idle: 30 * time.millisecond) == .idle
	t := spawn fn [mut c] () CollectStop {
		return c.collect[Tick](fn (_ Tick) bool {
			return true
		}, fn (_ Tick, mut _ Client) ! {
			return stop()
		}, timeout: 5 * time.second)
	}()
	wait_collector(mut c, 'TEST_TICK')
	c.dispatch(0, 'TEST_TICK', '{"n":1}')
	assert t.wait() == .stopped
}

fn test_collect_components_takes_the_authors_clicks_from_the_handlers() ! {
	mut c, _ := recording_client()
	mut log := &Log{}
	mut ctx := &InteractionContext{
		interaction: json2.decode[discord.Interaction](interaction(2, '7', '{"id":"1","name":"page","type":1}'))!
		client:      c
	}
	t := spawn fn [mut ctx, mut log] () CollectStop {
		return ctx.collect_components(fn [mut log] (mut cc ComponentContext) ! {
			log.add('clicked ${cc.custom_id}')
			if cc.custom_id == 'page:stop' {
				return stop()
			}
		},
			message_id: discord.Snowflake{55}
			timeout:    5 * time.second
		)
	}()
	wait_collector(mut c, 'INTERACTION_CREATE')
	c.dispatch(0, 'INTERACTION_CREATE', click('8', 'page:2')) // another user: left to the handlers
	c.dispatch(0, 'INTERACTION_CREATE', click('7', 'page:1'))
	c.dispatch(0, 'INTERACTION_CREATE', click('7', 'page:stop'))
	assert t.wait() == .stopped
	assert log.steps == ['clicked page:1', 'clicked page:stop']
	assert c.interaction_jobs.len == 1
}

fn test_files_come_from_base64() ! {
	png := discord.file_from_base64('a.png', 'data:image/png;base64,aGk=', 'text/plain')!
	assert png.data == 'hi'.bytes() && png.content_type == 'image/png'
	plain := discord.file_from_base64('b.txt', 'aGk=', 'text/plain')!
	assert plain.data == 'hi'.bytes() && plain.content_type == 'text/plain'
	if _ := discord.file_from_base64('c', 'data:text/plain,hi', '') {
		assert false, 'not base64'
	}
}
