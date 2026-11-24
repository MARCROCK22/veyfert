module veyfert

import json2
import sync
import time
import veyfert.discord
import veyfert.rest

// InlineAnswer is the HTTP response to an interaction received over HTTP.
pub struct InlineAnswer {
pub:
	status       int = 200
	content_type string
	body         string
}

// InlineReply hands the first answer of an HTTP interaction to its HTTP response.
@[heap]
pub struct InlineReply {
mut:
	mu   &sync.Mutex       = sync.new_mutex()
	ch   chan InlineAnswer = chan InlineAnswer{cap: 1}
	sent bool // the HTTP response took an answer, or a defer
}

// answer gives `body` to the HTTP response; false when the response already went out.
fn (mut r InlineReply) answer(body string, files []discord.File) bool {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.sent {
		return false
	}
	r.sent = true
	if files.len > 0 {
		content_type, form := rest.multipart(body, files)
		r.ch <- InlineAnswer{
			content_type: content_type
			body:         form
		}
	} else {
		r.ch <- InlineAnswer{
			content_type: 'application/json'
			body:         body
		}
	}
	return true
}

// handle_http handles an interaction received over HTTP, whose signature the caller checked
// (veyfert.server does). It returns the handler's first answer within `wait` for the HTTP
// response, or a defer; then the handler goes on, and its answer edits the deferred one.
// wait_for_component and wait_for_modal need the gateway: HTTP interactions do not reach them.
pub fn (mut c Client) handle_http(raw string, wait time.Duration) InlineAnswer {
	i := json2.decode[discord.Interaction](raw) or {
		return InlineAnswer{
			status:       400
			content_type: 'text/plain'
			body:         'invalid interaction'
		}
	}
	if i.kind == 1 {
		return InlineAnswer{
			content_type: 'application/json'
			body:         '{"type":1}'
		}
	}
	mut reply := &InlineReply{}
	spawn c.route_interaction(i, reply)
	if answer := recv_until(reply.ch, wait) {
		return answer
	}
	reply.mu.lock()
	if reply.sent {
		reply.mu.unlock()
		return <-reply.ch // answered between the timeout and the lock
	}
	reply.sent = true
	reply.mu.unlock()
	body := match i.kind {
		3 { '{"type":6}' } // a component: acknowledge without changing its message
		4 { '{"type":8,"data":{"choices":[]}}' } // autocomplete cannot be deferred
		else { '{"type":5}' }
	}
	return InlineAnswer{
		content_type: 'application/json'
		body:         body
	}
}
