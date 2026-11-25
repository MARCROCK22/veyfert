module veyfert

import compress.zlib
import json2
import log
import net.websocket
import os
import crypto.rand as crand
import sync
import time
import veyfert.discord

// Close codes after which reconnecting cannot succeed: bad token, shard, API version or intents.
const fatal_close_codes = [4004, 4010, 4011, 4012, 4013, 4014]
// Close codes after which the session cannot be resumed, so the shard identifies again.
const reset_close_codes = [1000, 4001, 4007, 4009]
// A shard closes its own connection with this code to keep the session resumable.
const close_resumable = 4000
const hello_timeout = 30 * time.second
// Discord allows 120 sends per minute and connection; 4 stay free for heartbeats.
const sends_per_minute = 116

struct GatewayEnvelope {
	op int
	s  ?int
	t  ?string
	d  string @[raw]
}

struct Hello {
	heartbeat_interval int
}

struct IdentifyProperties {
	os      string
	browser string
	device  string
}

struct IdentifyData {
	token      string
	intents    int
	shard      []int
	compress   bool
	presence   ?PresencePayload
	properties IdentifyProperties
}

struct ResumeData {
	token      string
	session_id string
	seq        int
}

struct Payload[T] {
	op int
	d  T
}

struct GuildId {
	id discord.Snowflake
}

// SendLimiter keeps a connection under Discord's send limit. Only the shard's writer
// thread uses it.
struct SendLimiter {
	limit  int           = sends_per_minute
	window time.Duration = time.minute
mut:
	count     int
	window_at time.Time
}

fn (mut l SendLimiter) wait() {
	now := time.now()
	if now - l.window_at >= l.window {
		l.window_at = now
		l.count = 0
	}
	if l.count >= l.limit {
		time.sleep(l.window - (now - l.window_at))
		l.window_at = time.now()
		l.count = 0
	}
	l.count++
}

// Shard is one gateway connection. It resumes its session after a dropped connection and
// identifies again, through the identify queue, when the session is gone.
@[heap]
struct Shard {
	id    int
	total int
mut:
	client &Client           = unsafe { nil }
	ws     &websocket.Client = unsafe { nil }
	mu     &sync.Mutex       = sync.new_mutex()
	outbox chan string       = chan string{cap: 256}
	// The session survives reconnections; `seq` is the last sequence number received.
	gateway_url string
	resume_url  string
	session_id  string
	seq         int = -1
	// The current connection.
	generation     int
	resuming       bool
	got_hello      bool
	ready          bool
	acked          bool
	sent_at        time.Time
	latency        time.Duration
	close_code     int
	close_reason   string
	close_reported bool
	read_failed    bool
	// Lifecycle.
	invalid_wait   bool // a non-resumable INVALID_SESSION asks for a pause before identifying
	stopping       bool
	connected_once bool
	pending_guilds map[u64]bool // guilds announced by READY that have not arrived yet
	loading_guilds int
	// Connected by resharding: it loads its guilds, but passes on no event until it takes over.
	standby bool
	limiter SendLimiter
	zctx    voidptr // the zstd-stream decompressor of the connection (gateway_zstd_d_veyfert_zstd.v)
}

// run keeps the shard connected until it is stopped or Discord rejects it for good.
fn (mut s Shard) run() ! {
	spawn s.writer()
	mut backoff := s.client.reconnect_backoff
	for !s.is_stopping() {
		resuming := s.can_resume()
		if !resuming {
			if s.take_invalid_wait() {
				time.sleep(s.client.invalid_session_wait)
			}
			s.client.identify_queue.wait(s.id)
			if s.is_stopping() {
				break
			}
		}
		started := time.now()
		s.session(resuming) or { s.client.logger.warn('shard ${s.id}: ${err}') }
		code, reason := s.disconnected()
		if s.is_stopping() {
			s.client.logger.info('shard ${s.id}: stopped')
			break
		}
		if code in fatal_close_codes {
			if !s.is_standby() {
				s.client.emit(ShardDisconnect{
					shard:  s.id
					code:   code
					reason: reason
				})
			}
			return error('shard ${s.id}: Discord closed the connection with ${code} (${reason}); check the token, the shard count and the intents')
		}
		if code in reset_close_codes {
			s.reset_session()
		}
		resumable := s.can_resume()
		s.client.logger.warn('shard ${s.id}: disconnected with ${code} ${reason}; ${if resumable {
			'resuming'
		} else {
			'identifying again'
		}}')
		if !s.is_standby() {
			s.client.emit(ShardDisconnect{
				shard:     s.id
				code:      code
				reason:    reason
				resumable: resumable
			})
		}
		if s.is_stopping() {
			break
		}
		// A connection that fails quickly backs off; a long-lived one reconnects at once.
		if time.now() - started < 10 * time.second {
			time.sleep(backoff)
			backoff = if backoff * 2 > 30 * time.second { 30 * time.second } else { backoff * 2 }
		} else {
			backoff = s.client.reconnect_backoff
		}
	}
}

// session holds one websocket connection open until it closes.
fn (mut s Shard) session(resuming bool) ! {
	base := if resuming { s.resume_url } else { s.gateway_url }
	url := '${base.trim_right('/')}/?v=10&encoding=json${if s.client.zstd {
		'&compress=zstd-stream'
	} else {
		''
	}}'
	s.reset_zstd()!
	mut quiet := &log.Log{}
	quiet.set_level(.warn)
	mut ws := websocket.new_client(url,
		logger:            quiet
		max_message_bytes: s.client.max_message_bytes
	)!
	s.mu.lock()
	s.generation++
	generation := s.generation
	s.ws = ws
	s.resuming = resuming
	s.got_hello = false
	s.ready = false
	s.acked = true
	// Stays as is when the connection drops without a close frame.
	s.close_code = 1006
	s.close_reason = 'connection lost'
	s.close_reported = false
	s.read_failed = false
	s.mu.unlock()

	ws.on_message(fn [mut s, generation] (mut c websocket.Client, msg &websocket.Message) ! {
		s.handle(generation, msg) or { s.client.logger.error('shard ${s.id}: ${err}') }
	})
	ws.on_error(fn [mut s, generation] (mut c websocket.Client, err string) ! {
		s.mu.lock()
		if s.generation == generation && !s.close_reported {
			s.read_failed = true
			s.close_reason = err
		}
		s.mu.unlock()
	})
	// net.websocket reports a close frame twice, with its code and then with 1000, and a broken
	// connection as 1000 after an error. The first report counts; after an error it is a 1006.
	ws.on_close(fn [mut s, generation] (mut c websocket.Client, code int, reason string) ! {
		s.mu.lock()
		if s.generation == generation && !s.close_reported {
			s.close_reported = true
			if !s.read_failed {
				s.close_code = code
				s.close_reason = reason
			}
		}
		s.mu.unlock()
	})
	ws.connect()!
	spawn s.hello_watchdog(generation)
	ws.listen()!
}

fn (mut s Shard) handle(generation int, msg &websocket.Message) ! {
	text := match msg.opcode {
		.text_frame { msg.payload.bytestr() }
		.binary_frame {
			if s.client.zstd {
				s.unzstd(msg.payload)!
			} else {
				zlib.decompress(msg.payload)!.bytestr()
			}
		}
		else { return }
	}
	env := json2.decode[GatewayEnvelope](text)!
	match env.op {
		0 { // DISPATCH
			s.on_dispatch(env)!
		}
		1 { // HEARTBEAT, requested by Discord
			s.beat(generation)!
		}
		7 { // RECONNECT
			s.drop(generation, 'Discord requested a reconnect')
		}
		9 { // INVALID_SESSION; `d` tells whether the session can be resumed
			if env.d.trim_space() != 'true' {
				s.reset_session()
				s.mu.lock()
				s.invalid_wait = true
				s.mu.unlock()
			}
			s.drop(generation, 'invalid session')
		}
		10 { // HELLO
			hello := json2.decode[Hello](env.d)!
			s.mu.lock()
			s.got_hello = true
			resuming := s.resuming
			s.mu.unlock()
			spawn s.heartbeat_loop(generation, hello.heartbeat_interval)
			if resuming {
				s.send_resume(generation)!
			} else {
				s.send_identify(generation)!
			}
		}
		11 { // HEARTBEAT_ACK
			s.mu.lock()
			s.acked = true
			s.latency = time.now() - s.sent_at
			s.mu.unlock()
		}
		else {}
	}
}

fn (mut s Shard) on_dispatch(env GatewayEnvelope) ! {
	if seq := env.s {
		s.mu.lock()
		s.seq = seq
		s.mu.unlock()
	}
	mut name := env.t or { return }
	if s.is_standby() {
		s.standby_dispatch(name, env.d)!
		return
	}
	mut guilds_done := false
	mut loaded := 0
	match name {
		'READY' {
			ready := json2.decode[discord.Ready](env.d)!
			count, reconnected := s.begin_session(ready)
			loaded = count
			guilds_done = count == 0
			s.client.shard_ready(s.id, ready)
			if reconnected {
				s.client.emit(ShardReconnect{
					shard: s.id
				})
			}
		}
		'RESUMED' {
			s.mu.lock()
			s.ready = true
			first := !s.connected_once
			s.connected_once = true
			s.mu.unlock()
			s.client.logger.info('shard ${s.id}: resumed')
			if first {
				// A session saved by a previous run: there is no READY, and no guilds arrive.
				s.client.logger.warn('shard ${s.id}: resumed a saved session; the cache starts empty')
				s.client.shard_guilds_ready(s.id, 0)
			} else {
				s.client.emit(ShardReconnect{
					shard:   s.id
					resumed: true
				})
			}
		}
		'GUILD_CREATE', 'GUILD_DELETE' {
			guild := json2.decode[GuildId](env.d)!
			pending, last, count := s.guild_arrived(guild.id.value)
			if pending {
				name = 'RAW_${name}'
				guilds_done = last
				loaded = count
			}
		}
		'GUILD_MEMBERS_CHUNK' {
			s.client.members_chunk(env.d)
		}
		'RATE_LIMITED' {
			s.client.rate_limited(env.d)
		}
		else {}
	}
	s.client.dispatch(s.id, name, env.d)
	if guilds_done {
		s.client.shard_guilds_ready(s.id, loaded)
	}
}

// begin_session keeps READY's session and the guilds that must arrive before the shard is
// loaded. It returns how many those are, and whether the shard had connected before.
fn (mut s Shard) begin_session(ready discord.Ready) (int, bool) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.session_id = ready.session_id
	s.resume_url = ready.resume_gateway_url
	s.pending_guilds = map[u64]bool{}
	if s.client.intents.has(.guilds) {
		for g in ready.guilds {
			s.pending_guilds[g.id.value] = true
		}
	}
	s.loading_guilds = s.pending_guilds.len
	s.ready = true
	reconnected := s.connected_once
	s.connected_once = true
	return s.loading_guilds, reconnected
}

// guild_arrived crosses off a guild that READY announced. It tells whether the guild was one of
// those, whether it was the last, and how many READY announced.
fn (mut s Shard) guild_arrived(id u64) (bool, bool, int) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	if id !in s.pending_guilds {
		return false, false, s.loading_guilds
	}
	s.pending_guilds.delete(id)
	return true, s.pending_guilds.len == 0, s.loading_guilds
}

// standby_dispatch follows the READY and the guilds of a shard that resharding connected, to
// tell the client once it is loaded. The events are dropped: the old shards deliver them until
// this one takes over.
fn (mut s Shard) standby_dispatch(name string, data string) ! {
	mut loaded := false
	match name {
		'READY' {
			count, _ := s.begin_session(json2.decode[discord.Ready](data)!)
			loaded = count == 0
		}
		'GUILD_CREATE', 'GUILD_DELETE' {
			pending, last, _ := s.guild_arrived(json2.decode[GuildId](data)!.id.value)
			loaded = pending && last
		}
		else {}
	}
	if loaded {
		s.client.standby_shard_loaded(s.id)
	}
}

fn (mut s Shard) is_standby() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.standby
}

// take_over makes a shard that resharding connected pass on its events.
fn (mut s Shard) take_over() {
	s.mu.lock()
	s.standby = false
	s.mu.unlock()
}

fn (mut s Shard) send_identify(generation int) ! {
	c := s.client
	s.write(generation, json2.encode(Payload[IdentifyData]{
		op: 2
		d:  IdentifyData{
			token:      c.rest.token
			intents:    int(c.intents)
			shard:      [s.id, s.total]
			compress:   c.compress
			presence:   c.presence_payload()
			properties: IdentifyProperties{
				os:      os.user_os()
				browser: 'veyfert'
				device:  'veyfert'
			}
		}
	}))!
}

fn (mut s Shard) send_resume(generation int) ! {
	s.mu.lock()
	data := ResumeData{
		token:      s.client.rest.token
		session_id: s.session_id
		seq:        s.seq
	}
	s.mu.unlock()
	s.write(generation, json2.encode(Payload[ResumeData]{ op: 6, d: data }))!
}

fn (mut s Shard) beat(generation int) ! {
	s.mu.lock()
	seq := s.seq
	s.acked = false
	s.sent_at = time.now()
	s.mu.unlock()
	d := if seq >= 0 { seq.str() } else { 'null' }
	s.write(generation, '{"op":1,"d":${d}}')!
}

// heartbeat_loop beats every `interval_ms` and drops a connection whose last beat was not
// acknowledged. It exits when its connection is replaced.
fn (mut s Shard) heartbeat_loop(generation int, interval_ms int) {
	time.sleep(time.Duration(crand.int_u64(u64(interval_ms)) or { 0 }) * time.millisecond)
	for {
		s.mu.lock()
		current := s.generation == generation
		acked := s.acked
		s.mu.unlock()
		if !current {
			return
		}
		if !acked {
			s.client.logger.warn('shard ${s.id}: heartbeat not acknowledged, reconnecting')
			s.drop(generation, 'zombie connection')
			return
		}
		s.beat(generation) or { return }
		time.sleep(time.Duration(interval_ms) * time.millisecond)
	}
}

fn (mut s Shard) hello_watchdog(generation int) {
	time.sleep(hello_timeout)
	s.mu.lock()
	waiting := s.generation == generation && !s.got_hello
	s.mu.unlock()
	if waiting {
		s.drop(generation, 'no HELLO within ${hello_timeout}')
	}
}

// write sends `text` on the connection `generation`, bypassing the outbox. Identify, resume
// and heartbeats use it; they must not wait behind the send limit.
// write sends a payload on the current connection, after the send interceptors.
fn (mut s Shard) write(generation int, text string) ! {
	mut payload := text
	for f in s.client.send_interceptors {
		payload = f(s.id, payload) or { return } // vetoed
	}
	s.mu.lock()
	if s.generation != generation {
		s.mu.unlock()
		return error('connection replaced')
	}
	mut ws := s.ws
	s.mu.unlock()
	ws.write_string(payload)!
}

// send queues `text` until the shard is ready, then writes it within the send limit.
fn (mut s Shard) send(text string) ! {
	if s.is_stopping() {
		return error('veyfert: shard ${s.id} is stopped')
	}
	s.outbox <- text
}

fn (mut s Shard) writer() {
	for {
		text := <-s.outbox or { return }
		if text == '' {
			return // stop() wakes the writer with an empty payload
		}
		for {
			generation := s.wait_ready() or { return }
			s.limiter.wait()
			s.write(generation, text) or {
				time.sleep(100 * time.millisecond)
				continue
			}
			break
		}
	}
}

fn (mut s Shard) wait_ready() !int {
	for {
		s.mu.lock()
		ready := s.ready
		stopping := s.stopping
		generation := s.generation
		s.mu.unlock()
		if stopping {
			return error('stopping')
		}
		if ready {
			return generation
		}
		// ponytail: polls every 50 ms; a condition variable if this ever shows up in a profile
		time.sleep(50 * time.millisecond)
	}
	return error('unreachable')
}

// drop closes the connection `generation` with a resumable code.
fn (mut s Shard) drop(generation int, reason string) {
	s.mu.lock()
	if s.generation != generation {
		s.mu.unlock()
		return
	}
	mut ws := s.ws
	s.mu.unlock()
	ws.close(close_resumable, reason) or {}
}

// stop closes the connection for good. It does not close with 1000, which would end the
// session for Discord: as Seyfert does, it keeps the session resumable for `save_sessions`.
fn (mut s Shard) stop() {
	s.mu.lock()
	s.stopping = true
	mut ws := s.ws
	s.mu.unlock()
	_ = s.outbox.try_push('')
	if !isnil(ws) {
		ws.close(close_resumable, 'client stopping') or {}
	}
}

fn (mut s Shard) disconnected() (int, string) {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	s.ready = false
	return s.close_code, s.close_reason
}

fn (mut s Shard) can_resume() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.session_id != '' && s.resume_url != '' && s.seq >= 0
}

fn (mut s Shard) reset_session() {
	s.mu.lock()
	s.session_id = ''
	s.resume_url = ''
	s.seq = -1
	s.mu.unlock()
}

fn (mut s Shard) take_invalid_wait() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	wait := s.invalid_wait
	s.invalid_wait = false
	return wait
}

fn (mut s Shard) is_stopping() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.stopping
}

fn (mut s Shard) get_latency() time.Duration {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.latency
}
