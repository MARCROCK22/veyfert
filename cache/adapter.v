module cache

import sync
import time

// Adapter is where the cache can also keep what it holds, as JSON under keys such as
// `guild:30`, `member:30:7` or `role:30:50`: a Redis that several processes share, for example.
// Set it in Options.adapter. The cache writes every resource it keeps to it, and reads from it
// what its memory lacks. Implementations must be safe to call from several threads.
pub interface Adapter {
mut:
	get(key string) ?string
	set(key string, value string)
	remove(key string)
	// scan returns the keys that start with `prefix`.
	scan(prefix string) []string
	flush()
}

// MemoryAdapter keeps everything in this process; it is the reference Adapter.
@[heap]
pub struct MemoryAdapter {
mut:
	mu     &sync.RwMutex = sync.new_rwmutex()
	values map[string]string
}

pub fn (mut a MemoryAdapter) get(key string) ?string {
	a.mu.rlock()
	defer {
		a.mu.runlock()
	}
	return a.values[key] or { return none }
}

pub fn (mut a MemoryAdapter) set(key string, value string) {
	a.mu.lock()
	a.values[key] = value
	a.mu.unlock()
}

pub fn (mut a MemoryAdapter) remove(key string) {
	a.mu.lock()
	a.values.delete(key)
	a.mu.unlock()
}

pub fn (mut a MemoryAdapter) scan(prefix string) []string {
	a.mu.rlock()
	defer {
		a.mu.runlock()
	}
	return a.values.keys().filter(it.starts_with(prefix))
}

pub fn (mut a MemoryAdapter) flush() {
	a.mu.lock()
	a.values.clear()
	a.mu.unlock()
}

// Limit bounds one resource of a LimitedMemoryAdapter: the resource is the start of a key,
// before its first `:` (guild, channel, user, member, role, presence, voice, stage, ban,
// emojis, stickers).
pub struct Limit {
pub:
	max    int           // keys kept; past it, the oldest written goes. 0 has no limit
	expire time.Duration // how long a key lives after it is written; 0 forever
}

struct LimitedEntry {
	value string
	at    time.Time
	seq   u64
}

struct QueuedKey {
	key string
	seq u64
}

// LimitedMemoryAdapter is a MemoryAdapter with a limit and an expiry per resource, as Seyfert's
// LimitedMemoryAdapter: `cache.new_limited_adapter({'member': cache.Limit{max: 10_000}})`.
@[heap]
pub struct LimitedMemoryAdapter {
pub:
	limits        map[string]Limit
	default_limit Limit
mut:
	mu     &sync.Mutex = sync.new_mutex()
	values map[string]LimitedEntry
	counts map[string]int
	order  map[string][]QueuedKey // per resource, in the order keys were written
	next   u64
}

pub fn new_limited_adapter(limits map[string]Limit) &LimitedMemoryAdapter {
	return &LimitedMemoryAdapter{
		limits: limits
	}
}

fn resource_of(key string) string {
	return key.all_before(':')
}

fn (a &LimitedMemoryAdapter) limit_of(resource string) Limit {
	return a.limits[resource] or { a.default_limit }
}

// alive tells whether an entry has not expired; the lock is held.
fn (a &LimitedMemoryAdapter) alive(key string, e LimitedEntry) bool {
	limit := a.limit_of(resource_of(key))
	return limit.expire == 0 || time.since(e.at) < limit.expire
}

pub fn (mut a LimitedMemoryAdapter) get(key string) ?string {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	e := a.values[key] or { return none }
	if !a.alive(key, e) {
		a.drop(key)
		return none
	}
	return e.value
}

pub fn (mut a LimitedMemoryAdapter) set(key string, value string) {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	resource := resource_of(key)
	if key !in a.values {
		a.counts[resource]++
	}
	a.next++
	a.values[key] = LimitedEntry{value, time.now(), a.next}
	limit := a.limit_of(resource)
	if limit.max <= 0 {
		return
	}
	mut queue := a.order[resource] or { []QueuedKey{} }
	queue << QueuedKey{key, a.next}
	// Evict the oldest written keys; a queued key written again since is stale and skipped.
	for a.counts[resource] > limit.max && queue.len > 0 {
		oldest := queue[0]
		queue.delete(0)
		if e := a.values[oldest.key] {
			if e.seq == oldest.seq {
				a.drop(oldest.key)
			}
		}
	}
	// Keys written again leave stale entries behind; rebuild the queue before it grows.
	if queue.len > 2 * limit.max + 16 {
		queue = queue.filter(fn [a] (q QueuedKey) bool {
			e := a.values[q.key] or { return false }
			return e.seq == q.seq
		})
	}
	a.order[resource] = queue
}

// drop forgets a key; the lock is held.
fn (mut a LimitedMemoryAdapter) drop(key string) {
	if key in a.values {
		a.values.delete(key)
		a.counts[resource_of(key)]--
	}
}

pub fn (mut a LimitedMemoryAdapter) remove(key string) {
	a.mu.lock()
	a.drop(key)
	a.mu.unlock()
}

pub fn (mut a LimitedMemoryAdapter) scan(prefix string) []string {
	a.mu.lock()
	defer {
		a.mu.unlock()
	}
	mut keys := []string{}
	mut expired := []string{}
	for key, e in a.values {
		if !key.starts_with(prefix) {
			continue
		}
		if a.alive(key, e) {
			keys << key
		} else {
			expired << key
		}
	}
	for key in expired {
		a.drop(key)
	}
	return keys
}

pub fn (mut a LimitedMemoryAdapter) flush() {
	a.mu.lock()
	a.values.clear()
	a.counts.clear()
	a.order.clear()
	a.mu.unlock()
}

// check_adapter is a conformance suite for adapters, as Seyfert's testCacheAdapter: it fails
// when `a` does not keep, replace, remove, scan and flush keys as the cache needs. It flushes
// `a` first.
pub fn check_adapter(mut a Adapter) ! {
	a.flush()
	if _ := a.get('guild:1') {
		return error('a flushed adapter still had guild:1')
	}
	a.set('guild:1', '{"id":"1"}')
	a.set('member:1:7', '{"nick":"ana"}')
	a.set('member:1:8', '{"nick":"ñandú 🦤"}')
	a.set('member:10:7', '{}')
	if (a.get('guild:1') or { '' }) != '{"id":"1"}' {
		return error('get does not return what set stored')
	}
	a.set('guild:1', '{"id":"1","name":"g"}')
	if (a.get('guild:1') or { '' }) != '{"id":"1","name":"g"}' {
		return error('set does not replace a value')
	}
	if (a.get('member:1:8') or { '' }) != '{"nick":"ñandú 🦤"}' {
		return error('a value with UTF-8 changed')
	}
	mut members := a.scan('member:1:')
	members.sort()
	if members != ['member:1:7', 'member:1:8'] {
		return error('scan of `member:1:` returned ${members}')
	}
	a.remove('member:1:7')
	if _ := a.get('member:1:7') {
		return error('remove does not remove')
	}
	a.remove('member:1:7') // removing a missing key is fine
	if a.scan('member:1:') != ['member:1:8'] {
		return error('scan still lists a removed key')
	}
	a.flush()
	if a.scan('').len != 0 {
		return error('flush leaves keys')
	}
}
