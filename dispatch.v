module veyfert

import json2
import sync
import time
import veyfert.discord

struct Job {
	shard     int
	name      string
	raw       string
	duplicate bool // a repeated member or presence update: only raw listeners see it
	command   bool // a message that may run a prefix command
}

interface Listener {
	call(raw string, mut c Client) !
}

struct TypedListener[T] {
	f fn (T, mut Client) ! @[required]
}

fn (l TypedListener[T]) call(raw string, mut c Client) ! {
	value := json2.decode[T](raw)!
	l.f(value, mut c)!
}

// A collector sees an event on the shard's reader thread, before the handler pool, and returns
// true once it is done with it, which removes it. It runs under the client's lock.
interface Collector {
	consume(raw string, mut c Client) bool
}

struct WaitCollector[T] {
	filter fn (T) bool @[required]
	ch     chan T
}

fn (w WaitCollector[T]) consume(raw string, mut _ Client) bool {
	value := json2.decode[T](raw) or { return false }
	if !w.filter(value) {
		return false
	}
	return w.ch.try_push(value) == .success
}

struct OnceCollector[T] {
	f fn (T, mut Client) ! @[required]
}

fn (o OnceCollector[T]) consume(raw string, mut c Client) bool {
	value := json2.decode[T](raw) or { return false }
	spawn run_listener(o.f, value, mut c)
	return true
}

fn run_listener[T](f fn (T, mut Client) !, value T, mut c Client) {
	f(value, mut c) or { c.logger.error('listener: ${err}') }
}

@[markused]
fn event_name[T]() string {
	$for a in T.attributes {
		$if a is discord.Event {
			return a.name
		}
	}
	panic('veyfert: ${T.name} has no @[veyfert.Event(...)] attribute')
}

// on registers `f` for the event whose payload type is T. The event name comes from the
// @[Event('...')] attribute on T, so every listener is typed. Listeners run on the handler
// pool, so they may block, and state they share needs `shared` or `sync`.
// Register listeners before `run`: the pool reads them without a lock. To wait for an event
// at run time, use `wait_for` or `once`, which are safe from any thread.
pub fn (mut c Client) on[T](f fn (T, mut Client) !) {
	name := event_name[T]()
	if name !in c.listeners {
		c.listeners[name] = []Listener{}
	}
	c.listeners[name] << Listener(TypedListener[T]{
		f: f
	})
}

// once runs `f` for the next event of type T only.
pub fn (mut c Client) once[T](f fn (T, mut Client) !) {
	c.add_collector(event_name[T](), Collector(OnceCollector[T]{
		f: f
	}))
}

// on_raw registers `f` for every dispatch, before decoding. Like `on`, call it before `run`.
pub fn (mut c Client) on_raw(f fn (RawEvent, mut Client) !) {
	c.raw_listeners << f
}

// emit sends a value to the listeners of its type, as if it came from the gateway. A custom
// event type needs an @[veyfert.Event('...')] attribute.
pub fn (mut c Client) emit[T](value T) {
	c.dispatch(-1, event_name[T](), json2.encode(value))
}

// wait_for blocks until an event of type T passes `filter`, or returns none after `timeout`.
// Events are matched on the shard's reader thread, so waiting inside a listener or a command
// cannot starve the pool. `filter` runs under the client's lock: keep it to comparisons.
pub fn (mut c Client) wait_for[T](filter fn (T) bool, timeout time.Duration) ?T {
	ch := chan T{cap: 1}
	name := event_name[T]()
	id := c.add_collector(name, Collector(WaitCollector[T]{
		filter: filter
		ch:     ch
	}))
	defer {
		c.remove_collector(name, id)
	}
	return recv_until(ch, timeout)
}

// wait_interaction is `wait_for[Interaction]` for the library's own calls: under the default
// -skip-unused, V skips that instance when only the library uses it (PLAN.md, risk 16).
fn (mut c Client) wait_interaction(filter fn (discord.Interaction) bool, timeout time.Duration) ?discord.Interaction {
	ch := chan discord.Interaction{cap: 1}
	id := c.add_collector('INTERACTION_CREATE', Collector(InteractionWait{
		filter: filter
		ch:     ch
	}))
	defer {
		c.remove_collector('INTERACTION_CREATE', id)
	}
	return recv_until(ch, timeout)
}

struct InteractionWait {
	filter fn (discord.Interaction) bool @[required]
	ch     chan discord.Interaction
}

fn (w InteractionWait) consume(raw string, mut _ Client) bool {
	value := json2.decode[discord.Interaction](raw) or { return false }
	return w.filter(value) && w.ch.try_push(value) == .success
}

// recv_until pops a value from `ch`, or returns none once `timeout` has passed.
// ponytail: polls every 10 ms because `select` inside a library fails to link under V's
// default -skip-unused (PLAN.md, risk 14); go back to `select` once V fixes that.
fn recv_until[T](ch chan T, timeout time.Duration) ?T {
	deadline := time.now().add(timeout)
	mut value := T{}
	for {
		if ch.try_pop(mut value) == .success {
			return value
		}
		if time.now() >= deadline {
			return none
		}
		time.sleep(10 * time.millisecond)
	}
	return none
}

fn (mut c Client) add_collector(name string, col Collector) int {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	c.next_collector++
	if name !in c.collectors {
		c.collectors[name] = map[int]Collector{}
	}
	c.collectors[name][c.next_collector] = col
	return c.next_collector
}

fn (mut c Client) remove_collector(name string, id int) {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if name in c.collectors {
		c.collectors[name].delete(id)
	}
}

// run_collectors returns true when a collector took the event.
fn (mut c Client) run_collectors(name string, raw string) bool {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if name !in c.collectors {
		return false
	}
	mut done := []int{}
	for id, col in c.collectors[name] {
		if col.consume(raw, mut c) {
			done << id
		}
	}
	for id in done {
		c.collectors[name].delete(id)
	}
	return done.len > 0
}

// dispatch runs on a shard's reader thread: collectors first, then the event goes to the
// pool, unless nothing listens to it. An interaction a collector took is not handled again,
// since only one answer is allowed.
fn (mut c Client) dispatch(shard int, name string, raw_in string) {
	mut raw := raw_in
	for f in c.interceptors {
		raw = f(name, raw) or { return }
	}
	duplicate := name in ['GUILD_MEMBER_UPDATE', 'PRESENCE_UPDATE'] && !c.dedupe.fresh(name, raw)
	mut taken := false
	if !duplicate {
		c.cache.apply(name, raw)
		taken = c.run_collectors(name, raw)
	}
	job := Job{
		shard:     shard
		name:      name
		raw:       raw
		duplicate: duplicate
	}
	if name == 'INTERACTION_CREATE' {
		if !taken {
			c.interaction_jobs <- job
		}
	} else if name == 'MESSAGE_CREATE' && c.commands.prefix != none {
		// Prefix commands run on the command pool; listeners still get the message.
		c.interaction_jobs <- Job{
			...job
			command: true
		}
		if c.raw_listeners.len > 0 || c.listeners[name].len > 0 {
			c.jobs <- job
		}
	} else if c.raw_listeners.len > 0 || (!duplicate && c.listeners[name].len > 0) {
		c.jobs <- job
	}
}

fn (mut c Client) start_workers() {
	if c.workers_started {
		return
	}
	c.workers_started = true
	for _ in 0 .. c.workers {
		spawn c.worker(c.jobs)
	}
	for _ in 0 .. c.interaction_workers {
		spawn c.worker(c.interaction_jobs)
	}
}

fn (mut c Client) worker(jobs chan Job) {
	for {
		job := <-jobs or { return }
		c.run_job(job)
	}
}

fn (mut c Client) run_job(job Job) {
	if job.command {
		c.run_prefix(job.raw)
		return
	}
	if c.raw_listeners.len > 0 {
		event := RawEvent{
			shard: job.shard
			name:  job.name
			data:  job.raw
		}
		for f in c.raw_listeners {
			f(event, mut c) or { c.logger.error('raw listener: ${err}') }
		}
	}
	if job.name == 'INTERACTION_CREATE' {
		c.handle_interaction(job.raw)
	}
	if job.duplicate {
		return
	}
	for l in c.listeners[job.name] {
		l.call(job.raw, mut c) or { c.logger.error('listener for ${job.name}: ${err}') }
	}
}

// Deduper drops the copies of GUILD_MEMBER_UPDATE and PRESENCE_UPDATE that Discord repeats: an
// update equal to the last one of the same member within 1.5 s, as Seyfert does.
@[heap]
struct Deduper {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	seen map[string]Seen
}

struct Seen {
	value string
	at    time.Time
}

const dedupe_window = 1500 * time.millisecond

// fresh tells whether an update is new, and remembers it.
fn (mut d Deduper) fresh(name string, raw string) bool {
	mut key := ''
	mut value := ''
	if name == 'GUILD_MEMBER_UPDATE' {
		m := json2.decode[discord.Member](raw) or { return true }
		key = 'm${m.guild_id or { discord.Snowflake{} }}:${(m.user or { discord.User{} }).id}'
		value = json2.encode(m)
	} else {
		p := json2.decode[discord.PresenceUpdate](raw) or { return true }
		key = 'p${p.guild_id or { discord.Snowflake{} }}:${p.user.id}'
		value = '${p.status}|${json2.encode(p.activities)}|${json2.encode(p.client_status)}'
	}
	now := time.now()
	d.mu.lock()
	defer {
		d.mu.unlock()
	}
	if last := d.seen[key] {
		if last.value == value && now - last.at < dedupe_window {
			return false
		}
	}
	if d.seen.len > 10000 {
		mut expired := []string{}
		for k, s in d.seen {
			if now - s.at >= dedupe_window {
				expired << k
			}
		}
		for k in expired {
			d.seen.delete(k)
		}
	}
	d.seen[key] = Seen{value, now}
	return true
}
