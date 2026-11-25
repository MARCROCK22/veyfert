module veyfert

import json2
import os
import crypto.rand as crand
import sync
import time
import veyfert.discord

// ShardRange selects the shards this process runs, out of `total`; `end` is exclusive.
pub struct ShardRange {
pub:
	start int
	end   int
	total int
}

struct SessionStartLimit {
	total           int
	remaining       int
	reset_after     int
	max_concurrency int
}

struct GatewayBot {
	url                 string
	shards              int
	session_start_limit SessionStartLimit
}

// IdentifyQueue spaces identifies the way Discord requires: shards share a bucket when
// `id % max_concurrency` matches, and each bucket identifies once per `interval`.
@[heap]
struct IdentifyQueue {
mut:
	interval        time.Duration = 5 * time.second
	max_concurrency int           = 1
	mu              &sync.Mutex   = sync.new_mutex()
	next_at         map[int]time.Time
}

// wait blocks until shard `id` may identify. Each call reserves the next slot of its bucket,
// so shards of one bucket go out `interval` apart.
fn (mut q IdentifyQueue) wait(id int) {
	q.mu.lock()
	bucket := id % q.max_concurrency
	now := time.now()
	mut at := q.next_at[bucket] or { now }
	if at < now {
		at = now
	}
	q.next_at[bucket] = at.add(q.interval)
	q.mu.unlock()
	if at > now {
		time.sleep(at - now)
	}
}

// run connects every shard and blocks until all of them stop. It returns an error when
// Discord rejects a shard for good, such as for a bad token.
pub fn (mut c Client) run() ! {
	mut url := c.gateway_url
	mut range := ShardRange{}
	if r := c.shard_range {
		range = r
	}
	if url == '' || c.shard_range == none {
		info := c.rest.get[GatewayBot]('/gateway/bot')!
		if url == '' {
			url = info.url
		}
		if c.shard_range == none {
			range = ShardRange{
				start: 0
				end:   info.shards
				total: info.shards
			}
		}
		limit := info.session_start_limit
		c.identify_queue.max_concurrency = if limit.max_concurrency > 0 {
			limit.max_concurrency
		} else {
			1
		}
		if limit.remaining < range.end - range.start {
			c.logger.warn('only ${limit.remaining} identifies left until Discord resets them in ${limit.reset_after} ms')
		}
	}
	if range.total <= 0 || range.start < 0 || range.start >= range.end || range.end > range.total {
		return error('veyfert: invalid shard range ${range}')
	}
	c.total_shards = range.total
	c.shards = []&Shard{}
	for id in range.start .. range.end {
		saved := c.saved_sessions.filter(it.shard == id && it.session_id != '')
		c.shards << &Shard{
			id:          id
			total:       range.total
			client:      c
			gateway_url: url
			session_id:  if saved.len > 0 { saved[0].session_id } else { '' }
			resume_url:  if saved.len > 0 { saved[0].resume_url } else { '' }
			seq:         if saved.len > 0 { saved[0].seq } else { -1 }
		}
	}
	c.start_workers()
	mut threads := []thread !{}
	for mut s in c.shards {
		threads << spawn s.run()
	}
	threads.wait() or {
		c.teardown_plugins()
		return err
	}
	c.teardown_plugins()
}

// stop closes every shard; `run` returns once they have disconnected.
pub fn (mut c Client) stop() {
	for mut s in c.shards {
		s.stop()
	}
}

// reconnect drops the connection of `shard`, which then resumes its session.
pub fn (mut c Client) reconnect(shard int) ! {
	mut s := c.shard_by_id(shard) or { return error('veyfert: this process does not run shard ${shard}') }
	s.mu.lock()
	generation := s.generation
	s.mu.unlock()
	s.drop(generation, 'reconnect requested')
}

// shard_id_for returns the shard that receives the events of a guild.
pub fn (c &Client) shard_id_for(guild_id discord.Snowflake) int {
	return int((guild_id.value >> 22) % u64(if c.total_shards > 0 { c.total_shards } else { 1 }))
}

fn (c &Client) shard_by_id(id int) ?&Shard {
	for s in c.shards {
		if s.id == id {
			return s
		}
	}
	return none
}

fn (c &Client) shard_for(guild_id discord.Snowflake) !&Shard {
	id := c.shard_id_for(guild_id)
	return c.shard_by_id(id) or {
		return error('veyfert: guild ${guild_id} belongs to shard ${id}, which this process does not run')
	}
}

// latency is the mean time between a heartbeat and its acknowledgement, over every shard. It
// is 0 until a heartbeat has been acknowledged; the first one goes out within one interval.
pub fn (mut c Client) latency() time.Duration {
	if c.shards.len == 0 {
		return 0
	}
	mut total := time.Duration(0)
	for mut s in c.shards {
		total += s.get_latency()
	}
	return total / time.Duration(c.shards.len)
}

// set_presence updates the bot's presence on every shard. Shards that identify later use it too.
pub fn (mut c Client) set_presence(p discord.Presence) ! {
	c.mu.lock()
	c.presence = p
	c.mu.unlock()
	text := json2.encode(Payload[PresencePayload]{ op: 3, d: gateway_presence(p) })
	for mut s in c.shards {
		s.send(text)!
	}
}

fn (mut c Client) presence_payload() ?PresencePayload {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if p := c.presence {
		return gateway_presence(p)
	}
	return none
}

@[params]
pub struct VoiceStateUpdate {
pub:
	guild_id   discord.Snowflake @[required]
	channel_id ?discord.Snowflake // none leaves the voice channel
	self_mute  bool
	self_deaf  bool
}

struct VoiceStateData {
	guild_id   discord.Snowflake
	channel_id discord.Nullable[discord.Snowflake]
	self_mute  bool
	self_deaf  bool
}

// update_voice_state joins, moves between or leaves voice channels. Audio is out of scope.
pub fn (mut c Client) update_voice_state(v VoiceStateUpdate) ! {
	mut s := c.shard_for(v.guild_id)!
	channel := if id := v.channel_id {
		discord.Nullable[discord.Snowflake]{
			value: id
		}
	} else {
		discord.Nullable[discord.Snowflake]{
			is_null: true
		}
	}
	s.send(json2.encode(Payload[VoiceStateData]{
		op: 4
		d:  VoiceStateData{
			guild_id:   v.guild_id
			channel_id: channel
			self_mute:  v.self_mute
			self_deaf:  v.self_deaf
		}
	}))!
}

@[params]
pub struct RequestMembers {
pub:
	guild_id  discord.Snowflake @[required]
	user_ids  []discord.Snowflake // up to 100 members by ID; without them, `query` is used
	query     string              // a username prefix; '' with limit 0 asks for every member
	limit     int
	presences bool
	timeout   time.Duration = 30 * time.second
}

struct RequestMembersData {
	guild_id  discord.Snowflake
	query     ?string
	limit     int
	presences bool
	user_ids  ?[]discord.Snowflake
	nonce     string
}

@[heap]
struct MemberWait {
	payload string // the request, sent again after a RATE_LIMITED
	shard   int
	ch      chan MemberBatch
mut:
	members []discord.Member
}

struct MemberBatch {
	members []discord.Member
}

// request_members asks the gateway for guild members and waits for every chunk of the answer.
// Asking for every member, or by query, needs the privileged GUILD_MEMBERS intent.
pub fn (mut c Client) request_members(opts RequestMembers) ![]discord.Member {
	mut s := c.shard_for(opts.guild_id)!
	nonce := crand.bytes(8)!.hex()
	payload := json2.encode(Payload[RequestMembersData]{
		op: 8
		d:  RequestMembersData{
			guild_id:  opts.guild_id
			query:     if opts.user_ids.len > 0 { none } else { opts.query }
			limit:     opts.limit
			presences: opts.presences
			user_ids:  if opts.user_ids.len > 0 { opts.user_ids } else { none }
			nonce:     nonce
		}
	})
	ch := chan MemberBatch{cap: 1}
	c.mu.lock()
	c.member_waits[nonce] = &MemberWait{
		payload: payload
		shard:   s.id
		ch:      ch
	}
	c.mu.unlock()
	defer {
		c.mu.lock()
		c.member_waits.delete(nonce)
		c.mu.unlock()
	}
	s.send(payload)!
	batch := recv_until(ch, opts.timeout) or {
		return error('veyfert: no answer to the guild members request within ${opts.timeout}')
	}
	return batch.members
}

fn (mut c Client) members_chunk(raw string) {
	chunk := json2.decode[discord.MembersChunk](raw) or { return }
	nonce := chunk.nonce or { return }
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	mut wait := c.member_waits[nonce] or { return }
	wait.members << chunk.members
	if chunk.chunk_index + 1 >= chunk.chunk_count {
		_ = wait.ch.try_push(MemberBatch{ members: wait.members })
	}
}

// rate_limited sends a guild members request again once Discord's wait is over.
fn (mut c Client) rate_limited(raw string) {
	info := json2.decode[discord.RateLimited](raw) or { return }
	nonce := info.meta.nonce or { return }
	if info.opcode != 8 {
		return
	}
	c.mu.lock()
	wait := c.member_waits[nonce] or {
		c.mu.unlock()
		return
	}
	c.mu.unlock()
	spawn fn [mut c, wait, info] () {
		time.sleep(time.Duration(i64((info.retry_after + 0.5) * f64(time.second))))
		mut s := c.shard_by_id(wait.shard) or { return }
		s.send(wait.payload) or {}
	}()
}

fn (mut c Client) shard_ready(shard int, ready discord.Ready) {
	c.mu.lock()
	c.user = ready.user
	c.app_id = ready.application.id
	c.mu.unlock()
	c.logger.info('shard ${shard}: ready as ${ready.user.username}')
}

fn (mut c Client) shard_guilds_ready(shard int, guilds int) {
	c.emit(GuildsReady{
		shard:  shard
		guilds: guilds
	})
	c.mu.lock()
	c.ready_shards[shard] = true
	all := c.ready_shards.len == c.shards.len && !c.bot_ready_sent
	if all {
		c.bot_ready_sent = true
	}
	user := c.user
	c.mu.unlock()
	if all {
		c.emit(BotReady{
			user:   user
			shards: c.shards.len
		})
	}
}

// ShardSession is what a shard needs to resume after a restart.
pub struct ShardSession {
pub:
	shard      int
	session_id string
	resume_url string
	seq        int
}

// sessions returns the session of every shard. Save them when stopping and pass them back in
// ClientOptions.sessions: the shards then resume and Discord replays the events they missed.
// Discord keeps a session only for a few minutes, and guilds are not sent again, so the cache
// starts empty.
pub fn (mut c Client) sessions() []ShardSession {
	mut out := []ShardSession{}
	for mut s in c.shards {
		s.mu.lock()
		out << ShardSession{
			shard:      s.id
			session_id: s.session_id
			resume_url: s.resume_url
			seq:        s.seq
		}
		s.mu.unlock()
	}
	return out
}

// save_sessions writes `sessions()` to a file, for `load_sessions` on the next start.
pub fn (mut c Client) save_sessions(path string) ! {
	os.mkdir_all(os.dir(path))!
	os.write_file(path, json2.encode(c.sessions()))!
}

// load_sessions reads the sessions `save_sessions` wrote; none when the file is missing.
pub fn load_sessions(path string) []ShardSession {
	text := os.read_file(path) or { return [] }
	return json2.decode[[]ShardSession](text) or { [] }
}
