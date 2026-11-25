module veyfert

import compress.zlib
import compress.zstd
import json2
import os
import veyfert.testing.ws
import sync
import time
import veyfert.discord
import veyfert.rest

struct FakeOp {
	op int
	d  string @[raw]
}

struct FakeMemberRequest {
	nonce string
}

// FakeGateway plays Discord's side of the gateway on a local port.
@[heap]
struct FakeGateway {
	port   int
	guilds []string // IDs that READY announces and that then arrive as GUILD_CREATE
mut:
	mu           &sync.Mutex = sync.new_mutex()
	conn         &ws.Conn    = unsafe { nil } // the server side of the latest connection
	received     []int // the op of every payload the client sent, in order
	payloads     []string
	seq          int
	ack          bool = true // acknowledge heartbeats
	hold_resumed bool // answer RESUME only on release_resumed()
	zstd         bool // compress the whole connection with zstd-stream
	cctx         &zstd.CCtx = unsafe { nil }
	path         string // what the latest connection asked for
}

fn start_fake_gateway(port int, guilds []string) &FakeGateway {
	mut fg := &FakeGateway{
		port:   port
		guilds: guilds
	}
	ws.listen(port, fn [mut fg] (mut c ws.Conn) ! {
		fg.mu.lock()
		fg.conn = &c
		fg.path = c.path
		if fg.zstd {
			fg.cctx = zstd.new_cctx()! // each connection is a new stream
		}
		fg.mu.unlock()
		fg.write(mut c, '{"op":10,"d":{"heartbeat_interval":150}}')!
	}, fn [mut fg] (mut c ws.Conn, text string) ! {
		fg.reply(mut c, text)!
	}) or { panic(err) }
	return fg
}

fn (mut fg FakeGateway) reply(mut c ws.Conn, text string) ! {
	op := json2.decode[FakeOp](text)!
	fg.mu.lock()
	fg.received << op.op
	fg.payloads << text
	ack := fg.ack
	hold := fg.hold_resumed
	fg.mu.unlock()
	match op.op {
		1 {
			if ack {
				fg.write(mut c, '{"op":11}')!
			}
		}
		2 {
			ids := fg.guilds.map('{"id":"${it}","unavailable":true}').join(',')
			fg.dispatch(mut c, 'READY', '{"session_id":"s1","resume_gateway_url":"ws://127.0.0.1:${fg.port}","user":{"id":"1","username":"fake","bot":true},"application":{"id":"1"},"guilds":[${ids}]}')!
			for id in fg.guilds {
				fg.dispatch(mut c, 'GUILD_CREATE', '{"id":"${id}","name":"g${id}","member_count":1}')!
			}
		}
		6 {
			if !hold {
				fg.dispatch(mut c, 'RESUMED', '{}')!
			}
		}
		8 {
			req := json2.decode[FakeMemberRequest](op.d)!
			fg.dispatch(mut c, 'GUILD_MEMBERS_CHUNK', '{"guild_id":"5","chunk_index":0,"chunk_count":2,"nonce":"${req.nonce}","members":[{"user":{"id":"10","username":"a"},"roles":[]}]}')!
			fg.dispatch(mut c, 'GUILD_MEMBERS_CHUNK', '{"guild_id":"5","chunk_index":1,"chunk_count":2,"nonce":"${req.nonce}","members":[{"user":{"id":"11","username":"b"},"roles":[]}]}')!
		}
		else {}
	}
}

fn (mut fg FakeGateway) dispatch(mut c ws.Conn, name string, data string) ! {
	fg.mu.lock()
	fg.seq++
	seq := fg.seq
	fg.mu.unlock()
	fg.write(mut c, '{"op":0,"s":${seq},"t":"${name}","d":${data}}')!
}

// write sends a payload, as a zstd-stream chunk in zstd mode.
fn (mut fg FakeGateway) write(mut c ws.Conn, text string) ! {
	if !fg.zstd {
		c.write_string(text)!
		return
	}
	fg.mu.lock()
	chunk := zstd_chunk(mut fg.cctx, text)
	fg.mu.unlock()
	c.write_binary(chunk)!
}

// zstd_chunk compresses `text` as the next part of the stream, flushed so it decodes alone.
fn zstd_chunk(mut c zstd.CCtx, text string) []u8 {
	mut input := zstd.InBuffer{
		src:  text.str
		size: uint(text.len)
	}
	mut buf := []u8{len: 64 * 1024}
	mut out := []u8{}
	for {
		mut output := zstd.OutBuffer{
			dst:  buf.data
			size: uint(buf.len)
		}
		left := c.compress_stream2(&output, &input, .flush) or { panic(err) }
		out << buf[..int(output.pos)]
		if left == 0 && input.pos >= input.size {
			break
		}
	}
	return out
}

fn (mut fg FakeGateway) count(op int) int {
	fg.mu.lock()
	defer {
		fg.mu.unlock()
	}
	return fg.received.filter(it == op).len
}

fn (mut fg FakeGateway) ops() []int {
	fg.mu.lock()
	defer {
		fg.mu.unlock()
	}
	return fg.received.clone()
}

fn (mut fg FakeGateway) last(op int) string {
	fg.mu.lock()
	defer {
		fg.mu.unlock()
	}
	for i := fg.received.len - 1; i >= 0; i-- {
		if fg.received[i] == op {
			return fg.payloads[i]
		}
	}
	return ''
}

fn (mut fg FakeGateway) set(ack bool, hold_resumed bool) {
	fg.mu.lock()
	fg.ack = ack
	fg.hold_resumed = hold_resumed
	fg.mu.unlock()
}

// close ends the latest connection with `code`, or drops the TCP connection when `code` is 0.
fn (mut fg FakeGateway) close(code int) {
	fg.mu.lock()
	mut conn := fg.conn
	fg.mu.unlock()
	if code == 0 {
		conn.drop()
	} else {
		conn.close(code, 'test') or {}
	}
}

fn (mut fg FakeGateway) send(text string) {
	fg.mu.lock()
	mut conn := fg.conn
	fg.mu.unlock()
	fg.write(mut conn, text) or {}
}

fn (mut fg FakeGateway) release_resumed() {
	fg.mu.lock()
	fg.hold_resumed = false
	mut conn := fg.conn
	fg.mu.unlock()
	fg.dispatch(mut conn, 'RESUMED', '{}') or {}
}

fn wait_until(cond fn () bool, timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		if cond() {
			return true
		}
		time.sleep(20 * time.millisecond)
	}
	return cond()
}

fn fake_client(port int) &Client {
	mut c := new_client(
		token:               'test-token'
		gateway_url:         'ws://127.0.0.1:${port}'
		shards:              ShardRange{
			start: 0
			end:   1
			total: 1
		}
		workers:             1
		interaction_workers: 1
	)
	c.logger.set_level(.disabled)
	c.identify_queue.interval = 10 * time.millisecond
	c.reconnect_backoff = 10 * time.millisecond
	c.invalid_session_wait = 10 * time.millisecond
	return c
}

fn run_detached(mut c Client) {
	c.run() or {}
}

// connect starts `c` and waits for its first IDENTIFY and heartbeat.
fn connect(mut fg FakeGateway, mut c Client) {
	spawn run_detached(mut c)
	assert wait_until(fn [mut fg] () bool {
		return fg.count(2) == 1 && fg.count(1) >= 1
	}, 5 * time.second), 'the client never identified'
}

fn resumed_once(mut fg FakeGateway) bool {
	return wait_until(fn [mut fg] () bool {
		return fg.count(6) == 1
	}, 5 * time.second)
}

fn test_resumes_after_the_connection_drops() {
	mut fg := start_fake_gateway(31901, [])
	mut c := fake_client(31901)
	connect(mut fg, mut c)
	fg.close(0) // no close frame: the client sees 1006
	assert resumed_once(mut fg), 'no RESUME after a dropped connection'
	assert fg.last(6).contains('"session_id":"s1"')
	assert fg.count(2) == 1, 'it identified again instead of resuming'
	c.stop()
}

fn test_resumes_after_close_4000() {
	mut fg := start_fake_gateway(31902, [])
	mut c := fake_client(31902)
	connect(mut fg, mut c)
	fg.close(4000)
	assert resumed_once(mut fg), 'no RESUME after 4000'
	assert fg.count(2) == 1
	c.stop()
}

fn test_identifies_again_after_close_4009() {
	mut fg := start_fake_gateway(31903, [])
	mut c := fake_client(31903)
	connect(mut fg, mut c)
	fg.close(4009) // session timed out
	assert wait_until(fn [mut fg] () bool {
		return fg.count(2) == 2
	}, 5 * time.second), 'no new IDENTIFY after 4009'
	assert fg.count(6) == 0, 'it tried to resume a dead session'
	c.stop()
}

fn test_stops_after_close_4004() {
	mut fg := start_fake_gateway(31904, [])
	mut c := fake_client(31904)
	result := chan string{cap: 1}
	spawn fn [mut c, result] () {
		c.run() or {
			result <- err.msg()
			return
		}
		result <- 'run returned without an error'
	}()
	assert wait_until(fn [mut fg] () bool {
		return fg.count(2) == 1
	}, 5 * time.second)
	fg.close(4004) // authentication failed
	select {
		msg := <-result {
			assert msg.contains('4004'), msg
		}
		5000 * time.millisecond {
			assert false, 'run kept going after 4004'
		}
	}
	assert fg.count(2) == 1, 'it reconnected after a fatal close'
}

fn test_reconnect_opcode_resumes() {
	mut fg := start_fake_gateway(31905, [])
	mut c := fake_client(31905)
	connect(mut fg, mut c)
	fg.send('{"op":7,"d":null}')
	assert resumed_once(mut fg), 'no RESUME after op 7'
	c.stop()
}

fn test_invalid_session_identifies_again() {
	mut fg := start_fake_gateway(31906, [])
	mut c := fake_client(31906)
	connect(mut fg, mut c)
	fg.send('{"op":9,"d":false}')
	assert wait_until(fn [mut fg] () bool {
		return fg.count(2) == 2
	}, 5 * time.second), 'no new IDENTIFY after op 9 false'
	assert fg.count(6) == 0
	c.stop()
}

fn test_resumable_invalid_session_resumes() {
	mut fg := start_fake_gateway(31907, [])
	mut c := fake_client(31907)
	connect(mut fg, mut c)
	fg.send('{"op":9,"d":true}')
	assert resumed_once(mut fg), 'no RESUME after op 9 true'
	assert fg.count(2) == 1
	c.stop()
}

fn test_zombie_connection_resumes() {
	mut fg := start_fake_gateway(31908, [])
	mut c := fake_client(31908)
	connect(mut fg, mut c)
	fg.set(false, false) // stop acknowledging heartbeats
	assert resumed_once(mut fg), 'an unacknowledged heartbeat did not reconnect'
	c.stop()
}

fn test_sends_wait_for_a_ready_connection() {
	mut fg := start_fake_gateway(31909, [])
	mut c := fake_client(31909)
	connect(mut fg, mut c)
	fg.set(true, true) // hold RESUMED back
	fg.close(0)
	assert resumed_once(mut fg)
	c.set_presence(status: .idle) or { assert false, err.msg() }
	time.sleep(300 * time.millisecond)
	assert fg.count(3) == 0, 'the presence went out before the session resumed'
	fg.release_resumed()
	assert wait_until(fn [mut fg] () bool {
		return fg.count(3) == 1
	}, 5 * time.second), 'the queued presence was never sent'
	ops := fg.ops()
	assert ops.index(6) < ops.index(3)
	assert fg.last(3).contains('"status":"idle"')
	c.stop()
}

fn test_member_requests_collect_every_chunk() {
	mut fg := start_fake_gateway(31910, [])
	mut c := fake_client(31910)
	connect(mut fg, mut c)
	members := c.request_members(
		guild_id: discord.Snowflake{5}
		user_ids: [discord.Snowflake{10}, discord.Snowflake{11}]
		timeout:  3 * time.second
	) or {
		assert false, err.msg()
		return
	}
	mut names := []string{}
	for m in members {
		user := m.user or { discord.User{} }
		names << user.username
	}
	assert names == ['a', 'b']
	assert fg.last(8).contains('"user_ids":["10","11"]')
	c.stop()
}

fn test_guilds_load_before_guilds_ready_and_bot_ready() {
	mut fg := start_fake_gateway(31911, ['100', '200'])
	mut c := fake_client(31911)
	events := chan string{cap: 16}
	c.on[discord.GuildCreate](fn [events] (g discord.GuildCreate, mut _ Client) ! {
		events <- 'create ${g.id}'
	})
	c.on[RawGuildCreate](fn [events] (g RawGuildCreate, mut _ Client) ! {
		events <- 'raw ${g.id}'
	})
	c.on[GuildsReady](fn [events] (e GuildsReady, mut _ Client) ! {
		events <- 'guilds ready ${e.guilds}'
	})
	c.on[BotReady](fn [events] (e BotReady, mut _ Client) ! {
		events <- 'bot ready ${e.user.username}'
	})
	connect(mut fg, mut c)
	mut got := []string{}
	for _ in 0 .. 4 {
		select {
			e := <-events {
				got << e
			}
			3000 * time.millisecond {
			}
		}
	}
	assert got == ['raw 100', 'raw 200', 'guilds ready 2', 'bot ready fake']
	c.stop()
}

fn test_reads_zlib_compressed_payloads() {
	mut fg := start_fake_gateway(31912, [])
	mut c := fake_client(31912)
	names := chan string{cap: 1}
	c.on[discord.GuildCreate](fn [names] (g discord.GuildCreate, mut _ Client) ! {
		names <- g.name
	})
	connect(mut fg, mut c)
	packed := zlib.compress('{"op":0,"s":50,"t":"GUILD_CREATE","d":{"id":"9","name":"zipped","member_count":1}}'.bytes()) or {
		assert false, err.msg()
		return
	}
	fg.mu.lock()
	mut conn := fg.conn
	fg.mu.unlock()
	conn.write_binary(packed) or {
		assert false, err.msg()
		return
	}
	select {
		name := <-names {
			assert name == 'zipped'
		}
		3000 * time.millisecond {
			assert false, 'the compressed GUILD_CREATE never reached the listener'
		}
	}
	c.stop()
}

fn test_a_saved_session_resumes_at_startup() {
	mut fg := start_fake_gateway(31913, [])
	mut first := fake_client(31913)
	connect(mut fg, mut first)
	saved := first.sessions()
	first.stop()
	assert saved.len == 1 && saved[0].session_id == 's1' && saved[0].resume_url != ''
	path := os.join_path(os.temp_dir(), 'veyfert_sessions_test.json')
	defer {
		os.rm(path) or {}
	}
	first.save_sessions(path) or { panic(err) }
	mut c := new_client(
		token:       'test-token'
		gateway_url: 'ws://127.0.0.1:31913'
		shards:      ShardRange{
			start: 0
			end:   1
			total: 1
		}
		sessions:    load_sessions(path)
	)
	c.logger.set_level(.disabled)
	ready := chan bool{cap: 1}
	c.on[BotReady](fn [ready] (_ BotReady, mut _ Client) ! {
		ready <- true
	})
	spawn run_detached(mut c)
	assert resumed_once(mut fg), 'it did not resume the saved session'
	assert fg.count(2) == 1, 'it identified instead of resuming'
	assert recv_until(ready, 2 * time.second) or { false }, 'BOT_READY did not fire'
	c.stop()
	assert load_sessions(path + '.missing') == []
}

fn test_zstd_stream_connections_decode_every_message() {
	mut fg := start_fake_gateway(31914, [])
	mut c := new_client(
		token:       'test-token'
		gateway_url: 'ws://127.0.0.1:31914'
		shards:      ShardRange{
			start: 0
			end:   1
			total: 1
		}
		zstd:        true
	)
	c.logger.set_level(.disabled)
	$if !veyfert_zstd ? {
		// Without -d veyfert_zstd, asking for zstd is an error, not a silent fallback.
		mut s := &Shard{
			client: c
		}
		s.reset_zstd() or {
			assert err.msg().contains('-d veyfert_zstd')
			return
		}
		assert false, 'zstd worked without -d veyfert_zstd'
		return
	}
	names := chan string{cap: 4}
	c.on[discord.GuildCreate](fn [names] (g discord.GuildCreate, mut _ Client) ! {
		names <- g.name
	})
	fg.zstd = true
	connect(mut fg, mut c)
	assert fg.path.contains('compress=zstd-stream')
	for name in ['one', 'two'] {
		fg.send('{"op":0,"s":9,"t":"GUILD_CREATE","d":{"id":"7","name":"' + name + '","owner_id":"1"}}')
		assert recv_until(names, 2 * time.second) or { '' } == name
	}
	c.stop()
}

fn test_send_interceptors_change_or_drop_payloads() {
	mut fg := start_fake_gateway(31915, [])
	mut c := fake_client(31915)
	c.intercept_send(fn (_ int, payload string) ?string {
		return payload.replace('"test-token"', '"changed-token"')
	})
	c.intercept_send(fn (_ int, payload string) ?string {
		if payload.starts_with('{"op":8,') {
			return none // no member requests
		}
		return payload
	})
	connect(mut fg, mut c)
	assert fg.last(2).contains('"changed-token"')
	mut s := c.shards[0]
	s.send('{"op":8,"d":{"guild_id":"5","query":"","limit":0,"nonce":"x"}}') or {}
	s.send('{"op":3,"d":{"since":null,"activities":[],"status":"idle","afk":false}}') or {}
	assert wait_until(fn [mut fg] () bool {
		return fg.count(3) == 1
	}, 2 * time.second)
	assert fg.count(8) == 0
	c.stop()
}

fn test_request_soundboard_sounds_sends_op_31_to_the_shard_of_the_guilds() {
	mut fg := start_fake_gateway(31916, [])
	mut c := fake_client(31916)
	connect(mut fg, mut c)
	c.request_soundboard_sounds([discord.Snowflake{5}, discord.Snowflake{6}]) or { panic(err) }
	assert wait_until(fn [mut fg] () bool {
		return fg.count(31) == 1
	}, 5 * time.second), 'no op 31 arrived'
	assert fg.last(31).contains('"d":{"guild_ids":["5","6"]}')
	c.stop()
}

// GatewayInfo answers /gateway/bot as Discord does once the bot needs more shards.
@[heap]
struct GatewayInfo {
	port   int
	shards int
}

fn (mut g GatewayInfo) send(req rest.HttpRequest) !rest.HttpResponse {
	return rest.HttpResponse{
		status: 200
		body:   '{"url":"ws://127.0.0.1:${g.port}","shards":${g.shards},"session_start_limit":{"total":1000,"remaining":1000,"reset_after":0,"max_concurrency":1}}'
	}
}

fn test_resharding_waits_until_the_shards_are_full_enough() {
	assert !reshard_needed(4, 4, 80) // the same count
	assert !reshard_needed(4, 3, 80)
	assert !reshard_needed(4, 7, 80) // about 7000 guilds where 4 shards hold 10000: 70%
	assert reshard_needed(4, 8, 80) // 80%
	assert reshard_needed(1, 3, 80)
	assert !reshard_needed(0, 3, 80)
}

fn test_resharding_moves_to_the_new_shards_once_they_load_their_guilds() {
	mut fg := start_fake_gateway(31917, ['100'])
	mut c := fake_client(31917)
	c.rest.transport = &GatewayInfo{31917, 3}
	raw := chan string{cap: 16}
	c.on[RawGuildCreate](fn [raw] (g RawGuildCreate, mut _ Client) ! {
		raw <- 'raw ${g.id}'
	})
	done := chan bool{cap: 1}
	spawn fn [mut c, done] () {
		c.run() or {}
		done <- true
	}()
	select {
		e := <-raw {
			assert e == 'raw 100'
		}
		5 * time.second {
			assert false, 'the first shard never loaded its guild'
		}
	}
	mut old := c.current_shards()[0]
	c.reshard_if_needed() or { assert false, err.msg() }
	// Three shards identified with the new total and took over; the old one closed.
	fg.mu.lock()
	identifies := fg.payloads.filter(it.contains('"op":2'))
	fg.mu.unlock()
	assert identifies.len == 4 && identifies[0].contains('"shard":[0,1]')
	for want in ['[0,3]', '[1,3]', '[2,3]'] {
		assert identifies[1..].any(it.contains('"shard":${want}')), want
	}
	assert c.current_shards().map('${it.id}/${it.total}') == ['0/3', '1/3', '2/3']
	assert c.shard_id_for(discord.Snowflake{u64(2) << 22}) == 2
	assert old.is_stopping()
	// The new shards loaded the guild too, without passing it on.
	select {
		e := <-raw {
			assert false, 'a loading shard passed on ${e}'
		}
		200 * time.millisecond {
		}
	}
	// `run` goes on with the new shards until the bot stops.
	select {
		_ := <-done {
			assert false, 'run returned when the old shard closed'
		}
		300 * time.millisecond {
		}
	}
	c.stop()
	select {
		_ := <-done {
		}
		5 * time.second {
			assert false, 'run did not return after stop'
		}
	}
}
