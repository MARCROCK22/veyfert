module veyfert

import json2
import log
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
// Consumed is what a collector did with an event. An interaction that a collector took is not
// handled again.
enum Consumed {
	ignored // not for this collector
	taken   // taken, and the collector wants more
	done    // taken, and the collector is finished
}

interface Collector {
	consume(raw string, mut c Client) Consumed
}

struct WaitCollector[T] {
	filter fn (T) bool @[required]
	ch     chan T
}

fn (w WaitCollector[T]) consume(raw string, mut _ Client) Consumed {
	value := json2.decode[T](raw) or { return .ignored }
	if !w.filter(value) {
		return .ignored
	}
	return if w.ch.try_push(value) == .success { .done } else { .ignored }
}

// StreamCollector hands every matching event to a collection, until it is removed.
struct StreamCollector[T] {
	filter fn (T) bool @[required]
	ch     chan T
}

fn (s StreamCollector[T]) consume(raw string, mut _ Client) Consumed {
	value := json2.decode[T](raw) or { return .ignored }
	if !s.filter(value) {
		return .ignored
	}
	// A full buffer leaves the event to the listeners.
	return if s.ch.try_push(value) == .success { .taken } else { .ignored }
}

struct OnceCollector[T] {
	f fn (T, mut Client) ! @[required]
}

fn (o OnceCollector[T]) consume(raw string, mut c Client) Consumed {
	value := json2.decode[T](raw) or { return .ignored }
	spawn run_listener(o.f, value, mut c)
	return .done
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
	many   bool // a collection, which stays until it is removed
}

fn (w InteractionWait) consume(raw string, mut _ Client) Consumed {
	value := json2.decode[discord.Interaction](raw) or { return .ignored }
	if w.filter(value) && w.ch.try_push(value) == .success {
		return if w.many { .taken } else { .done }
	}
	return .ignored
}

@[params]
pub struct Collect {
pub:
	timeout time.Duration = time.minute // ends the collection this long after it starts; 0 never
	idle    time.Duration // ends it after this long without an item; 0 never
	max     int           // ends it after this many items; 0 has no limit
}

// CollectStop is why a collection ended.
pub enum CollectStop {
	timeout
	idle
	max
	stopped // the callback returned veyfert.stop()
}

// collect runs `each` for every event of type T that passes `filter`, one at a time, until the
// collection ends, and returns why: Seyfert's collectors, blocking like `wait_for`. `each` may
// return `veyfert.stop()` to end it; other errors are logged.
pub fn (mut c Client) collect[T](filter fn (T) bool, each fn (T, mut Client) !, opts Collect) CollectStop {
	ch := chan T{cap: 64}
	name := event_name[T]()
	id := c.add_collector(name, Collector(StreamCollector[T]{
		filter: filter
		ch:     ch
	}))
	defer {
		c.remove_collector(name, id)
	}
	return drain(ch, opts, fn [each, mut c] [T](value T) ! {
		each(value, mut c)!
	}, c.logger)
}

// drain hands what arrives on `ch` to `each` until `opts` ends the collection.
// ponytail: polls every 10 ms, as recv_until does (PLAN.md, risk 14).
fn drain[T](ch chan T, opts Collect, each fn (T) !, logger &log.ThreadSafeLog) CollectStop {
	started := time.now()
	mut last := started
	mut count := 0
	for {
		now := time.now()
		if opts.timeout > 0 && now - started >= opts.timeout {
			return .timeout
		}
		if opts.idle > 0 && now - last >= opts.idle {
			return .idle
		}
		mut value := T{}
		if ch.try_pop(mut value) != .success {
			time.sleep(10 * time.millisecond)
			continue
		}
		last = time.now()
		count++
		each(value) or {
			if err is GuardStop {
				return .stopped
			}
			logger.error('collector: ${err}')
		}
		if opts.max > 0 && count >= opts.max {
			return .max
		}
	}
	return .timeout
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
	mut taken := false
	for id, col in c.collectors[name] {
		match col.consume(raw, mut c) {
			.ignored {}
			.taken {
				taken = true
			}
			.done {
				taken = true
				done << id
			}
		}
	}
	for id in done {
		c.collectors[name].delete(id)
	}
	return taken
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
			c.queue(c.interaction_jobs, job)
		}
	} else if name == 'MESSAGE_CREATE' && c.commands.prefix != none {
		// Prefix commands run on the command pool; listeners still get the message.
		c.queue(c.interaction_jobs, Job{
			...job
			command: true
		})
		if c.raw_listeners.len > 0 || c.listeners[name].len > 0 {
			c.queue(c.jobs, job)
		}
	} else if c.raw_listeners.len > 0 || (!duplicate && c.listeners[name].len > 0) {
		c.queue(c.jobs, job)
	}
}

// queue hands a job to a pool; it counts as pending until a worker has run it.
fn (mut c Client) queue(jobs chan Job, job Job) {
	c.pending.add(1)
	jobs <- job
}

// drain waits, for up to `limit`, until the pools have run every queued job.
fn (mut c Client) drain(limit time.Duration) {
	deadline := time.now().add(limit)
	for c.pending.load() > 0 {
		if time.now() > deadline {
			c.logger.warn('handlers still busy after ${limit}; going on without them')
			return
		}
		time.sleep(5 * time.millisecond)
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
		c.pending.sub(1)
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
