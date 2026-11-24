module main

import json2
import time
import veyfert.discord

// Decoding cost of large gateway payloads: the envelope, then the typed payload.
// Build with -prod from the repo root:
//   v -prod -path "@vlib|@vmodules|<parent of veyfert>" run benchmarks/decode

struct Envelope {
	op int
	s  ?int
	t  ?string
	d  string @[raw]
}

// Stands in for the message model, which arrives in a later phase.
struct MessageLite {
	id         discord.Snowflake
	channel_id discord.Snowflake
	author     discord.User
	content    string
}

fn ready_payload(guilds int) string {
	ids := []string{len: guilds, init: '{"id":"${u64(1000000000000000000) + u64(index)}","unavailable":true}'}
	return '{"op":0,"s":1,"t":"READY","d":{"v":10,"session_id":"abc","resume_gateway_url":"wss://x","user":{"id":"1","username":"bot","bot":true},"application":{"id":"1"},"guilds":[${ids.join(',')}]}}'
}

fn guild_create_payload(members int, channels int, roles int) string {
	m := []string{len: members, init: '{"user":{"id":"${u64(2000000000000000000) + u64(index)}","username":"user${index}","global_name":null,"avatar":"a_${index}","bot":false},"nick":null,"roles":["1","2"],"joined_at":"2024-01-01T00:00:00.000000+00:00","deaf":false,"mute":false,"flags":0}'}
	ch := []string{len: channels, init: '{"id":"${u64(3000000000000000000) + u64(index)}","type":0,"name":"channel-${index}","position":${index},"permission_overwrites":[],"parent_id":null,"topic":"topic ${index}"}'}
	r := []string{len: roles, init: '{"id":"${u64(4000000000000000000) + u64(index)}","name":"role${index}","color":0,"hoist":false,"position":${index},"permissions":"8","managed":false,"mentionable":false}'}
	return '{"op":0,"s":2,"t":"GUILD_CREATE","d":{"id":"5","name":"big guild","member_count":${members},"members":[${m.join(',')}],"channels":[${ch.join(',')}],"roles":[${r.join(',')}]}}'
}

const message_create = '{"op":0,"s":3,"t":"MESSAGE_CREATE","d":{"id":"10","channel_id":"11","guild_id":"5","author":{"id":"12","username":"someone","bot":false},"content":"hola desde V","timestamp":"2026-11-24T00:00:00.000000+00:00","embeds":[],"attachments":[],"mentions":[],"mention_roles":[],"pinned":false,"tts":false,"type":0}}'

fn bench[T](label string, payload string, rounds int) ! {
	sw := time.new_stopwatch()
	for _ in 0 .. rounds {
		env := json2.decode[Envelope](payload)!
		_ = json2.decode[T](env.d)!
	}
	total := sw.elapsed()
	mib_s := f64(payload.len) * f64(rounds) / total.seconds() / 1048576.0
	println('${label:-34} ${payload.len / 1024:6} KiB ${total.microseconds() / rounds:9} µs/op ${mib_s:8.1f} MiB/s')
}

fn main() {
	bench[discord.Ready]('READY, 2500 guilds', ready_payload(2500), 50)!
	bench[discord.GuildCreate]('GUILD_CREATE, 1000 members', guild_create_payload(1000,
		300, 200), 20)!
	bench[MessageLite]('MESSAGE_CREATE', message_create, 20000)!
}
