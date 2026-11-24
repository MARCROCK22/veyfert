// Package testing runs a bot without Discord: a fake gateway, a fake REST API and payloads.
//
//   mut gw := testing.start_gateway(31999, ['30'])!
//   mut api := testing.new_transport()
//   mut bot := testing.client(gw, api)
//   bot.commands.add(Ping{})
//   spawn bot.run()
//   gw.wait_identified(time.second)
//   gw.dispatch('INTERACTION_CREATE', testing.command_interaction('ping', '[]'))!
//   reply := api.wait(1, time.second) or { panic('no reply') }
module testing

import json2
import sync
import time
import veyfert
import veyfert.testing.ws
import veyfert.rest

// Response is an answer of the fake REST API.
pub struct Response {
pub:
	status  int = 200
	headers map[string]string
	body    string = '{}'
}

// Transport stands in for Discord's REST API: it records each request and answers with the
// scripted responses in turn, repeating the last one.
@[heap]
pub struct Transport {
mut:
	mu        &sync.Mutex = sync.new_mutex()
	responses []Response
	requests  []rest.HttpRequest
}

pub fn new_transport(responses ...Response) &Transport {
	return &Transport{
		responses: responses
	}
}

pub fn (mut t Transport) send(req rest.HttpRequest) !rest.HttpResponse {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	t.requests << req
	r := if t.responses.len > 1 {
		t.responses[0]
	} else if t.responses.len == 1 {
		t.responses[0]
	} else {
		Response{}
	}
	if t.responses.len > 1 {
		t.responses.delete(0)
	}
	return rest.HttpResponse{
		status:  r.status
		headers: r.headers
		body:    r.body
	}
}

// requests returns the requests so far.
pub fn (mut t Transport) requests() []rest.HttpRequest {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	return t.requests.clone()
}

// wait returns the `count`-th request (from 1) once it arrives; none after `timeout`.
pub fn (mut t Transport) wait(count int, timeout time.Duration) ?rest.HttpRequest {
	deadline := time.now().add(timeout)
	for {
		seen := t.requests()
		if seen.len >= count {
			return seen[count - 1]
		}
		if time.now() >= deadline {
			return none
		}
		time.sleep(5 * time.millisecond)
	}
	return none
}

// client builds a quiet client on `gateway` (none for REST only) whose REST requests go to
// `transport`.
pub fn client(gateway ?&Gateway, transport &Transport) &veyfert.Client {
	mut url := ''
	if gw := gateway {
		url = gw.url()
	}
	mut c := veyfert.new_client(
		token:               'test-token'
		gateway_url:         url
		shards:              veyfert.ShardRange{
			start: 0
			end:   1
			total: 1
		}
		workers:             1
		interaction_workers: 1
	)
	c.rest.transport = transport
	c.logger.set_level(.disabled)
	return c
}

struct Op {
	op int
}

// Gateway plays Discord's side of the gateway on 127.0.0.1:port: it says HELLO, answers
// IDENTIFY with READY and a GUILD_CREATE per guild, acknowledges heartbeats and resumes, and
// sends whatever a test dispatches.
@[heap]
pub struct Gateway {
	port   int
	guilds []string
mut:
	mu   &sync.Mutex = sync.new_mutex()
	conn &ws.Conn    = unsafe { nil }
	ops  []int
	seq  int
}

pub fn start_gateway(port int, guilds []string) !&Gateway {
	mut gw := &Gateway{
		port:   port
		guilds: guilds
	}
	ws.listen(port, fn [mut gw] (mut c ws.Conn) ! {
		gw.mu.lock()
		gw.conn = &c
		gw.mu.unlock()
		c.write_string('{"op":10,"d":{"heartbeat_interval":1000}}')!
	}, fn [mut gw] (mut c ws.Conn, text string) ! {
		gw.answer(mut c, text)!
	})!
	return gw
}

pub fn (g &Gateway) url() string {
	return 'ws://127.0.0.1:${g.port}'
}

fn (mut g Gateway) answer(mut c ws.Conn, text string) ! {
	op := json2.decode[Op](text)!
	g.mu.lock()
	g.ops << op.op
	g.mu.unlock()
	match op.op {
		1 {
			c.write_string('{"op":11}')!
		}
		2 {
			ids := g.guilds.map('{"id":"${it}","unavailable":true}').join(',')
			g.send_dispatch(mut c, 'READY', '{"session_id":"s1","resume_gateway_url":"${g.url()}","user":{"id":"1","username":"bot","bot":true},"application":{"id":"1"},"guilds":[${ids}]}')!
			for id in g.guilds {
				g.send_dispatch(mut c, 'GUILD_CREATE', '{"id":"${id}","name":"Guild ${id}","owner_id":"2","member_count":1,"roles":[{"id":"${id}","name":"@everyone","permissions":"0"}],"members":[{"user":{"id":"1","username":"bot","bot":true},"roles":[]}],"channels":[{"id":"${id}0","type":0,"name":"general"}]}')!
			}
		}
		6 {
			g.send_dispatch(mut c, 'RESUMED', '{}')!
		}
		else {}
	}
}

fn (mut g Gateway) send_dispatch(mut c ws.Conn, name string, data string) ! {
	g.mu.lock()
	g.seq++
	seq := g.seq
	g.mu.unlock()
	c.write_string('{"op":0,"s":${seq},"t":"${name}","d":${data}}')!
}

// dispatch sends an event to the connected client.
pub fn (mut g Gateway) dispatch(name string, data string) ! {
	g.mu.lock()
	mut conn := g.conn
	g.mu.unlock()
	if isnil(conn) {
		return error('veyfert.testing: no client is connected')
	}
	g.send_dispatch(mut conn, name, data)!
}

// close ends the connection with a close code, or drops it when `code` is 0.
pub fn (mut g Gateway) close(code int) {
	g.mu.lock()
	mut conn := g.conn
	g.mu.unlock()
	if isnil(conn) {
		return
	}
	if code == 0 {
		conn.drop()
	} else {
		conn.close(code, 'veyfert.testing') or {}
	}
}

// received returns the op of every payload the client sent, in order.
pub fn (mut g Gateway) received() []int {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	return g.ops.clone()
}

// wait_identified waits for the client's IDENTIFY and for its guilds to be sent.
pub fn (mut g Gateway) wait_identified(timeout time.Duration) bool {
	deadline := time.now().add(timeout)
	for time.now() < deadline {
		if 2 in g.received() {
			time.sleep(100 * time.millisecond)
			return true
		}
		time.sleep(10 * time.millisecond)
	}
	return false
}
