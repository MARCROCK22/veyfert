module veyfert

import sync
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
		body:   '{}'
	}
}

@[heap]
struct Trail {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	lines []string
}

fn (mut t Trail) add(line string) {
	t.mu.lock()
	t.lines << line
	t.mu.unlock()
}

struct Named {
	name_ string
mut:
	trail &Trail = unsafe { nil }
}

fn (n Named) name() string {
	return n.name_
}

fn (mut n Named) setup(mut _ Client) ! {
	n.trail.add('setup ${n.name_}')
}

fn (mut n Named) teardown(mut _ Client) ! {
	n.trail.add('teardown ${n.name_}')
}

fn test_plugins_set_up_in_order_and_tear_down_in_reverse() ! {
	mut c := new_client(token: 'test')
	trail := &Trail{}
	mut a := &Named{'a', trail}
	mut b := &Named{'b', trail}
	c.install(mut a)!
	c.install(mut b)!
	c.teardown_plugins()
	assert trail.lines == ['setup a', 'setup b', 'teardown b', 'teardown a']
}

fn test_interceptors_change_or_drop_events() {
	mut c := new_client(token: 'test')
	c.intercept(fn (name string, raw string) ?string {
		if name == 'TYPING_START' {
			return none
		}
		return raw.replace('"general"', '"renamed"')
	})
	c.on_raw(fn (e RawEvent, mut c Client) ! {})
	c.dispatch(0, 'CHANNEL_CREATE', '{"id":"40","type":0,"guild_id":"30","name":"general"}')
	assert (c.cache.channel(discord.Snowflake{40}) or { discord.Channel{} }).name or { '' } == 'renamed'
	c.dispatch(0, 'TYPING_START', '{}')
	assert c.jobs.len == 1 // only CHANNEL_CREATE reached the pool
}

@[Declare(name: 'ok', description: 'Works')]
struct Works {}

fn (w Works) run(mut ctx CommandContext) ! {
	ctx.write(content: 'ok')!
}

@[Declare(name: 'boom', description: 'Fails')]
struct Boom {}

fn (b Boom) run(mut _ CommandContext) ! {
	return error('kaboom')
}

fn test_command_observers_see_every_outcome() {
	mut c := new_client(token: 'test')
	c.rest.transport = &Recorder{}
	trail := &Trail{}
	c.commands.observe(fn [trail] (e CommandEvent) {
		mut t := trail
		t.add('${e.path} ${e.outcome} ${e.failure} ${e.user_id}')
	})
	c.commands.add(Works{})
	c.commands.add(Boom{})
	for name in ['ok', 'boom'] {
		c.handle_interaction('{"id":"10","application_id":"20","type":2,"token":"t","user":{"id":"7","username":"ana"},"data":{"id":"1","name":"${name}","type":1}}')
	}
	assert trail.lines == ['ok ok  7', 'boom error kaboom 7']
}
