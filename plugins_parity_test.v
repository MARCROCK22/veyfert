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
		body:   if req.method == .put { '[]' } else { '{"id":"42","name":"app"}' }
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test')
	rec := &Recorder{}
	c.rest.transport = rec
	return c, rec
}

fn interaction(kind int, data string) string {
	return '{"id":"10","application_id":"20","type":${kind},"token":"tok","guild_id":"30","channel_id":"40","member":{"user":{"id":"7","username":"ana"},"roles":[],"permissions":"0"},"message":{"id":"55","channel_id":"40","content":""},"data":${data}}'
}

fn slash(name string) string {
	return interaction(2, '{"id":"1","name":"${name}","type":1}')
}

fn click(custom_id string) string {
	return interaction(3, '{"custom_id":"${custom_id}","component_type":2}')
}

@[heap]
struct Log {
mut:
	mu    &sync.Mutex = sync.new_mutex()
	steps []string
}

fn (mut l Log) add(step string) {
	l.mu.lock()
	l.steps << step
	l.mu.unlock()
}

// Probe is a plugin that declares what a test gives it, and registers in `setup` what its
// `register` function does.
struct Probe {
	name_         string
	version       string
	requires      []Requirement
	intents       discord.Intents
	fail          bool
	fail_teardown bool
mut:
	imports  []Plugin
	log      &Log = unsafe { nil }
	register ?fn (mut c Client) !
}

fn (p Probe) name() string {
	return p.name_
}

fn (p Probe) info() PluginInfo {
	return PluginInfo{
		version:  p.version
		imports:  p.imports
		requires: p.requires
		intents:  p.intents
	}
}

fn (mut p Probe) setup(mut c Client) ! {
	p.log.add('setup ${p.name_}')
	if f := p.register {
		f(mut c)!
	}
	if p.fail {
		return error('no database')
	}
}

fn (mut p Probe) teardown(mut _ Client) ! {
	p.log.add('teardown ${p.name_}')
	if p.fail_teardown {
		return error('stuck')
	}
}

fn test_imports_install_first_once_and_tear_down_in_reverse() ! {
	mut c, _ := recording_client()
	mut log := &Log{}
	mut clock := &Probe{
		name_:   'clock'
		version: '1.4.0'
		log:     log
	}
	mut stats := &Probe{
		name_:    'stats'
		imports:  [Plugin(clock)]
		requires: [Requirement{
			plugin:  'clock'
			version: '^1.2.0'
		}]
		log:      log
	}
	mut alerts := &Probe{
		name_:   'alerts'
		imports: [Plugin(clock)]
		log:     log
	}
	c.install(mut stats)!
	c.install(mut alerts)! // clock is installed already, so this import is skipped
	assert c.plugins.map(it.name) == ['clock', 'stats', 'alerts']
	mut failure := ''
	mut second := &Probe{
		name_: 'clock'
		log:   log
	}
	c.install(mut second) or { failure = err.msg() }
	assert failure == 'veyfert: plugin `clock` failed during install: a plugin named `clock` is already installed'
	c.teardown_plugins()!
	assert log.steps == ['setup clock', 'setup stats', 'setup alerts', 'teardown alerts',
		'teardown stats', 'teardown clock']
	assert c.plugins.len == 0
}

fn test_cycles_and_unmet_requirements_fail_naming_the_plugin() ! {
	mut c, _ := recording_client()
	mut log := &Log{}
	mut a := &Probe{
		name_: 'a'
		log:   log
	}
	mut b := &Probe{
		name_:   'b'
		imports: [Plugin(a)]
		log:     log
	}
	a.imports = [Plugin(b)]
	mut failure := ''
	c.install(mut a) or { failure = err.msg() }
	assert failure == 'veyfert: plugin `a` failed during imports: circular import: a -> b -> a'

	mut needs := &Probe{
		name_:    'needs'
		requires: [Requirement{
			plugin: 'db'
		}]
		log:      log
	}
	c.install(mut needs) or { failure = err.msg() }
	assert failure == 'veyfert: plugin `needs` failed during requires: it requires the plugin `db`, which is not installed'
	mut db := &Probe{
		name_:   'db'
		version: '1.0.0'
		log:     log
	}
	c.install(mut db)!
	mut newer := &Probe{
		name_:    'newer'
		requires: [Requirement{
			plugin:  'db'
			version: '^2.0.0'
		}]
		log:      log
	}
	c.install(mut newer) or { failure = err.msg() }
	assert failure == 'veyfert: plugin `newer` failed during requires: it requires `db` ^2.0.0, and the installed one is 1.0.0'
	// An optional requirement only warns.
	mut relaxed := &Probe{
		name_:    'relaxed'
		requires: [Requirement{
			plugin:   'db'
			version:  '>=3.0.0'
			optional: true
		}, Requirement{
			plugin:   'cache'
			optional: true
		}]
		log:      log
	}
	c.install(mut relaxed)!
	// Plugins are installed by the bot or as imports, never from a setup.
	mut nested := &Probe{
		name_:    'nested'
		log:      log
		register: fn [log] (mut c Client) ! {
			mut other := &Probe{
				name_: 'other'
				log:   log
			}
			c.install(mut other)!
		}
	}
	c.install(mut nested) or { failure = err.msg() }
	assert failure == 'veyfert: plugin `nested` failed during setup: veyfert: install plugins from PluginInfo.imports, not from a setup'
	assert c.plugins.map(it.name) == ['db', 'relaxed']
}

const connection = SharedKey[string]{'connection'}

@[Declare(name: 'ping', description: 'Ping')]
@[Aliases('p')]
@[Perms('manage_messages')]
struct Ping {}

fn (p Ping) run(mut _ CommandContext) ! {}

fn test_a_failed_setup_leaves_nothing_behind() {
	mut c, _ := recording_client()
	mut log := &Log{}
	c.on_raw(fn (e RawEvent, mut c Client) ! {})
	mut dep := &Probe{
		name_:         'dep'
		fail_teardown: true
		log:           log
	}
	mut broken := &Probe{
		name_:    'broken'
		imports:  [Plugin(dep)]
		fail:     true
		log:      log
		register: fn [log] (mut c Client) ! {
			c.on_raw(fn (e RawEvent, mut c Client) ! {})
			c.commands.add(Ping{})
			connection.set(mut c, 'conn-1', fn [log] (value string) ! {
				mut l := log
				l.add('dispose ${value}')
			})!
		}
	}
	mut failures := []string{}
	c.install(mut broken) or {
		if err is PluginErrors {
			failures = err.errors.map(it.msg())
		}
	}
	// The setup failed, and so did the teardown of its import; both come back, each naming
	// its plugin.
	assert failures == ['veyfert: plugin `broken` failed during setup: no database',
		'veyfert: plugin `dep` failed during teardown: stuck']
	assert log.steps == ['setup dep', 'setup broken', 'dispose conn-1', 'teardown dep']
	assert c.plugins.len == 0
	assert c.raw_listeners.len == 1 // the bot's own
	assert c.commands.entries.len == 0 && c.commands.prefix_names.len == 0
	assert c.commands.member_perms.len == 0 && c.commands.invokers.len == 0
	assert connection.get(c) == none
}

@[discord.Event('TEST_PING')]
struct TestPing {
	n int
}

@[discord.Event('TEST_OTHER')]
struct TestOther {}

@[Declare(name: 'before', description: 'Before')]
struct Before {}

fn (b Before) run(mut _ CommandContext) ! {}

@[Declare(name: 'after', description: 'After')]
struct After {}

fn (a After) run(mut ctx CommandContext) ! {
	ctx.write(content: 'after ran')!
}

@[CustomId('exact')]
struct Exact {}

fn (e Exact) run(mut _ ComponentContext) ! {}

@[CustomIdPrefix('page:')]
struct Page {
	log &Log
}

fn (p Page) run(mut _ ComponentContext) ! {
	mut l := p.log
	l.add('plugin page')
}

@[CustomIdPrefix('page:')]
struct BotPage {
	log &Log
}

fn (p BotPage) run(mut _ ComponentContext) ! {
	mut l := p.log
	l.add('bot page')
}

@[CustomIdRegex('^re:')]
struct Re {}

fn (r Re) run(mut _ ComponentContext) ! {}

@[CustomIdRegex('^note:')]
@[Modal(custom_id: 'note', title: 'Note')]
struct Note {
mut:
	text string @[Label: 'Text']
}

fn (n Note) submit(mut _ ModalContext) ! {}

struct Open {}

fn (mut o Open) check_handler(mut _ InteractionContext) ! {}

struct Stamp {
	log  &Log
	name string
}

fn (mut s Stamp) check(mut _ CommandContext) ! {
	mut l := s.log
	l.add('guard ${s.name}')
}

// bot_registrations is what the bot registers by itself, before or after the plugin.
fn bot_registrations(mut c Client, log &Log, after bool) {
	if !after {
		c.on[TestPing](fn (p TestPing, mut c Client) ! {})
		c.commands.add(Before{})
		return
	}
	c.commands.add(After{})
	c.components.add(BotPage{log})
}

fn test_teardown_takes_back_what_a_plugin_registered() ! {
	mut c, rec := recording_client()
	mut log := &Log{}
	bot_registrations(mut c, log, false)
	mut kitchen := &Probe{
		name_:    'kitchen'
		log:      log
		register: fn [log] (mut c Client) ! {
			c.on[TestPing](fn (p TestPing, mut c Client) ! {})
			c.on[TestOther](fn (p TestOther, mut c Client) ! {})
			c.on_raw(fn (e RawEvent, mut c Client) ! {})
			c.intercept(fn (name string, raw string) ?string {
				return raw
			})
			c.intercept_send(fn (shard int, payload string) ?string {
				return payload
			})
			c.rest.observe(fn (e rest.RestEvent) {})
			c.commands.add(Ping{})
			c.commands.use(Stamp{log, 'kitchen'})
			c.commands.observe(fn (e CommandEvent) {})
			c.components.add(Exact{})
			c.components.add(Page{log})
			c.components.add(Re{})
			c.components.use(Open{})
			c.modals.add(Note{})
			c.modals.use(Open{})
			c.hook(.plugins_ready, fn (mut c Client) ! {})
			c.wrap_guards(fn (mut ctx InteractionContext, guard string, next fn () !) ! {
				next()!
			})
			c.wrap_autocomplete(fn (mut ctx AutocompleteContext, next fn () !) ! {
				next()!
			})
			connection.set(mut c, 'conn-2', none)!
		}
	}
	c.install(mut kitchen)!
	bot_registrations(mut c, log, true)
	assert c.commands.prefix_names['after'] or { -1 } == 2
	c.teardown_plugins()!

	// What is left is what the bot registered by itself. prefix_seq only counts up.
	mut alone, _ := recording_client()
	bot_registrations(mut alone, log, false)
	bot_registrations(mut alone, log, true)
	assert Marks{
		...c.marks()
		prefix_seq: 0
	} == Marks{
		...alone.marks()
		prefix_seq: 0
	}
	assert c.commands.prefix_names == alone.commands.prefix_names
	assert c.listeners.keys() == ['TEST_PING']
	assert c.components.prefixes.len == 1
	// The bot's command moved down a place and still runs; its page button outlived the
	// plugin's, which had the same prefix.
	c.handle_interaction(slash('after'))
	assert rec.requests.last().body.contains('after ran')
	c.handle_interaction(click('page:1'))
	assert log.steps.last() == 'bot page'
}

fn test_hooks_run_in_order_and_a_failing_one_does_not_stop_the_rest() ! {
	mut c, rec := recording_client()
	mut log := &Log{}
	mut helper := &Probe{
		name_:    'helper'
		log:      log
		register: fn [log] (mut c Client) ! {
			c.hook(.plugins_ready, fn (mut c Client) ! {
				return error('not ready')
			})
			c.hook(.before_upload, fn [log] (mut c Client) ! {
				mut l := log
				l.add('before upload')
				c.commands.add(Ping{}) // a hook may still add commands
			})
		}
	}
	c.install(mut helper)!
	c.hook(.plugins_ready, fn [log] (mut c Client) ! {
		mut l := log
		l.add('bot ready')
	})
	c.run_hooks(.plugins_ready)
	c.upload_commands()!
	assert log.steps == ['setup helper', 'bot ready', 'before upload']
	assert rec.requests.last().method == .put
	assert rec.requests.last().body.contains('"name":"ping"')
}

fn test_closing_waits_for_queued_events_then_runs_hooks_and_teardown() ! {
	mut c, _ := recording_client()
	mut log := &Log{}
	c.on[TestPing](fn [log] (p TestPing, mut c Client) ! {
		time.sleep(50 * time.millisecond)
		mut l := log
		l.add('handled ${p.n}')
	})
	mut closer := &Probe{
		name_:    'closer'
		intents:  .guild_members
		log:      log
		register: fn [log] (mut c Client) ! {
			c.hook(.client_close, fn [log] (mut c Client) ! {
				mut l := log
				l.add('close')
			})
		}
	}
	c.install(mut closer)!
	assert c.intents.has(.guilds) && c.intents.has(.guild_members) // the plugin's intents are added
	c.start_workers()
	c.dispatch(0, 'TEST_PING', '{"n":1}')
	c.close_plugins()!
	assert log.steps == ['setup closer', 'handled 1', 'close', 'teardown closer']
	assert c.pending.load() == 0
}

fn test_teardown_failures_come_back_together() {
	mut c, _ := recording_client()
	mut log := &Log{}
	for name in ['x', 'y'] {
		mut p := &Probe{
			name_:         name
			fail_teardown: true
			log:           log
		}
		c.install(mut p) or { panic(err) }
	}
	mut failure := ''
	c.teardown_plugins() or { failure = err.msg() }
	assert failure == 'veyfert: 2 plugin failures: veyfert: plugin `y` failed during teardown: stuck; veyfert: plugin `x` failed during teardown: stuck'
}

@[heap]
struct Counter {
mut:
	n int
}

const counter = SharedKey[&Counter]{'counter'}

fn test_shared_values_are_typed_and_disposed_with_their_plugin() ! {
	mut c, _ := recording_client()
	mut log := &Log{}
	mut db := &Probe{
		name_:    'db'
		log:      log
		register: fn [log] (mut c Client) ! {
			counter.set(mut c, &Counter{}, fn [log] (k &Counter) ! {
				mut l := log
				l.add('dispose ${k.n}')
			})!
			connection.set(mut c, 'postgres://db', none)!
		}
	}
	c.install(mut db)!
	mut k := counter.get(c) or { return error('the counter is missing') }
	k.n += 2
	// A reference is shared: everyone sees the same counter.
	assert (counter.get(c) or { &Counter{} }).n == 2
	assert connection.get(c) or { '' } == 'postgres://db'
	mut failure := ''
	connection.set(mut c, 'again', none) or { failure = err.msg() }
	assert failure == 'veyfert: the shared value `connection` is already set'
	missing := SharedKey[int]{'missing'}
	assert missing.get(c) == none
	c.teardown_plugins()!
	assert connection.get(c) == none && counter.get(c) == none
	assert log.steps == ['setup db', 'teardown db', 'dispose 2']
}

fn test_a_failed_disposal_names_the_plugin_and_the_value() {
	mut c, _ := recording_client()
	mut leaky := &Probe{
		name_:    'leaky'
		log:      &Log{}
		register: fn (mut c Client) ! {
			connection.set(mut c, 'conn-3', fn (value string) ! {
				return error('still open')
			})!
		}
	}
	c.install(mut leaky) or { panic(err) }
	mut failure := ''
	c.teardown_plugins() or { failure = err.msg() }
	assert failure == 'veyfert: plugin `leaky` failed during the disposal of `connection`: still open'
}

// Counted remembers that it ran, for `run` to see.
struct Counted {
mut:
	runs int
}

fn (mut g Counted) check(mut _ CommandContext) ! {
	g.runs++
}

// Skipped would deny, but a wrapper skips it.
struct Skipped {}

fn (mut g Skipped) check(mut _ CommandContext) ! {
	return deny('never')
}

struct Refuse {}

fn (mut g Refuse) check(mut _ CommandContext) ! {
	return deny('nope')
}

@[Declare(name: 'guarded', description: 'Guarded')]
struct Guarded {
	log &Log
mut:
	counted Counted
	skipped Skipped
}

fn (g Guarded) run(mut _ CommandContext) ! {
	mut l := g.log
	l.add('run after ${g.counted.runs} check')
}

@[Declare(name: 'refused', description: 'Refused')]
struct Refused {
mut:
	refuse Refuse
}

fn (r Refused) run(mut _ CommandContext) ! {}

struct Gate {
	log &Log
}

fn (mut g Gate) check_handler(mut _ InteractionContext) ! {
	mut l := g.log
	l.add('gate')
}

@[CustomId('door')]
struct Door {
	log &Log
mut:
	gate Gate
}

fn (d Door) run(mut _ ComponentContext) ! {
	mut l := d.log
	l.add('door')
}

fn test_guard_wrappers_run_around_every_guard() ! {
	mut c, rec := recording_client()
	mut log := &Log{}
	c.wrap_guards(fn [log] (mut ctx InteractionContext, guard string, next fn () !) ! {
		mut l := log
		l.add('outer ${guard.all_after_last('.')}')
		next()!
		l.add('outer done')
	})
	c.wrap_guards(fn [log] (mut ctx InteractionContext, guard string, next fn () !) ! {
		if guard.ends_with('Skipped') {
			mut l := log
			l.add('skip')
			return
		}
		next() or {
			if err is GuardStop {
				return deny('wrapped: ${err.reason}')
			}
			return err
		}
	})
	c.commands.use(Stamp{log, 'global'})
	c.commands.add(Guarded{
		log: log
	})
	c.commands.add(Refused{})
	c.components.add(Door{
		log:  log
		gate: Gate{log}
	})
	c.handle_interaction(slash('guarded'))
	assert log.steps == ['outer Stamp', 'guard global', 'outer done', 'outer Counted', 'outer done',
		'outer Skipped', 'skip', 'outer done', 'run after 1 check']
	c.handle_interaction(slash('refused'))
	assert rec.requests.last().body.contains('wrapped: nope')
	log.steps.clear()
	c.handle_interaction(click('door'))
	assert log.steps == ['outer Gate', 'gate', 'outer done', 'door']
}

@[Declare(name: 'find', description: 'Find')]
struct Find {
mut:
	topic ?string @[Autocomplete; Desc: 'A topic']
}

fn (f Find) run(mut _ CommandContext) ! {}

fn (f Find) autocomplete(mut ctx AutocompleteContext) ! {
	ctx.respond([Choice{
		name:  'handler'
		value: ctx.value
	}])!
}

fn typing(value string) string {
	return interaction(4, '{"id":"1","name":"find","type":1,"options":[{"name":"topic","type":3,"value":"${value}","focused":true}]}')
}

fn test_autocomplete_wrappers_run_around_the_handler_or_answer_instead() {
	mut c, rec := recording_client()
	mut log := &Log{}
	c.commands.add(Find{})
	c.wrap_autocomplete(fn [log] (mut ctx AutocompleteContext, next fn () !) ! {
		mut l := log
		l.add('wrap ${ctx.focused}=${ctx.value}')
		if ctx.value == 'cached' {
			ctx.respond([Choice{
				name:  'from cache'
				value: 'cached'
			}])!
			return
		}
		next()!
	})
	c.handle_interaction(typing('ga'))
	assert rec.requests.last().body == '{"type":8,"data":{"choices":[{"name":"handler","value":"ga"}]}}'
	c.handle_interaction(typing('cached'))
	assert rec.requests.last().body == '{"type":8,"data":{"choices":[{"name":"from cache","value":"cached"}]}}'
	assert log.steps == ['wrap topic=ga', 'wrap topic=cached']
}
