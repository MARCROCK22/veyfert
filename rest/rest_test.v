module rest

import sync
import time
import veyfert.discord

struct Scripted {
	status  int = 200
	headers map[string]string
	body    string = '{}'
}

@[heap]
struct MockTransport {
mut:
	mu        &sync.Mutex = sync.new_mutex()
	responses []Scripted
	requests  []HttpRequest
	times     []time.Time
}

fn (mut m MockTransport) send(req HttpRequest) !HttpResponse {
	m.mu.lock()
	defer {
		m.mu.unlock()
	}
	m.requests << req
	m.times << time.now()
	r := if m.responses.len > 0 { m.responses[0] } else { Scripted{} }
	if m.responses.len > 0 {
		m.responses.delete(0)
	}
	return HttpResponse{
		status:  r.status
		headers: r.headers
		body:    r.body
	}
}

fn mock_rest(responses []Scripted) (Rest, &MockTransport) {
	mut mock := &MockTransport{
		responses: responses
	}
	rc := Rest{
		token:       'test-token'
		user_agent:  'test'
		transport:   mock
		retry_delay: 10 * time.millisecond
	}
	return rc, mock
}

fn test_a_429_waits_and_sends_the_request_again() {
	mut rc, mock := mock_rest([
		Scripted{
			status: 429
			body:   '{"retry_after":0.1,"global":false}'
		},
		Scripted{
			body: '{"id":"1"}'
		},
	])
	body := rc.request(.get, '/users/@me') or { panic(err) }
	assert body == '{"id":"1"}'
	assert mock.requests.len == 2
	assert mock.times[1] - mock.times[0] >= 90 * time.millisecond
	assert mock.requests[0].headers['Authorization'] == 'Bot test-token'
}

fn test_a_global_429_blocks_other_routes_but_not_interactions() {
	mut rc, mock := mock_rest([
		Scripted{
			status:  429
			headers: {
				'x-ratelimit-global': 'true'
			}
			body:    '{"retry_after":0.2,"global":true}'
		},
		Scripted{},
		Scripted{},
		Scripted{},
	])
	spawn fn [mut rc] () {
		rc.request(.get, '/users/@me') or {}
	}()
	time.sleep(50 * time.millisecond) // the 429 is in, the global block is set
	started := time.now()
	rc.request(.post, '/interactions/1/token/callback', body: '{}') or { panic(err) }
	assert time.now() - started < 100 * time.millisecond, 'an interaction waited for the global block'
	rc.request(.get, '/guilds/5') or { panic(err) }
	assert time.now() - started >= 100 * time.millisecond, 'another route ignored the global block'
	assert mock.requests.len >= 3
}

fn test_routes_that_share_a_bucket_wait_for_each_other() {
	shared_headers := {
		'x-ratelimit-bucket':      'abc'
		'x-ratelimit-remaining':   '0'
		'x-ratelimit-reset-after': '0.2'
	}
	mut rc, mock := mock_rest([Scripted{
		headers: shared_headers
	}, Scripted{
		headers: shared_headers
	}, Scripted{}])
	rc.request(.get, '/channels/1/messages') or { panic(err) }
	rc.request(.get, '/channels/1/pins') or { panic(err) }
	// Both routes now map to bucket abc of channel 1, which has nothing left until it resets.
	rc.request(.get, '/channels/1/messages') or { panic(err) }
	assert mock.times[2] - mock.times[1] >= 150 * time.millisecond
}

fn test_502_and_503_are_retried_three_times() {
	mut rc, mock := mock_rest([Scripted{
		status: 502
	}, Scripted{
		status: 503
	}, Scripted{
		status: 502
	}, Scripted{
		body: 'ok'
	}])
	assert rc.request(.get, '/gateway') or { panic(err) } == 'ok'
	assert mock.requests.len == 4
	mut failing, _ := mock_rest([]Scripted{len: 4, init: Scripted{
		status: 502
	}})
	failing.request(.get, '/gateway') or {
		assert err is DiscordError
		assert (err as DiscordError).status == 502
		return
	}
	assert false, 'four 502s should fail'
}

fn test_errors_carry_the_discord_code_and_hide_tokens() {
	mut rc, _ := mock_rest([Scripted{
		status: 404
		body:   '{"code":10008,"message":"Unknown Message"}'
	}])
	rc.request(.delete, '/webhooks/1/secret-token/messages/2') or {
		e := err as DiscordError
		assert e.error_code == 10008
		assert e.message == 'Unknown Message'
		assert !e.msg().contains('secret-token')
		assert e.route == '/webhooks/1/:token/messages/2'
		return
	}
	assert false, 'a 404 should fail'
}

fn test_files_go_as_multipart_with_the_audit_reason() {
	mut rc, mock := mock_rest([Scripted{}])
	rc.request(.post, '/channels/1/messages',
		body:   '{"content":"hi"}'
		reason: 'hello world/1'
		files:  [discord.File{
			name: 'a.txt'
			data: 'abc'.bytes()
		}]
	) or { panic(err) }
	req := mock.requests[0]
	assert req.headers['Content-Type'].starts_with('multipart/form-data; boundary=')
	assert req.headers['X-Audit-Log-Reason'] == 'hello%20world%2F1'
	assert req.body.contains('name="payload_json"\r\nContent-Type: application/json\r\n\r\n{"content":"hi"}')
	assert req.body.contains('name="files[0]"; filename="a.txt"\r\nContent-Type: application/octet-stream\r\n\r\nabc\r\n')
}

fn test_route_keys_keep_the_major_parameter() {
	assert route_key(.get, '/channels/123/messages/456').ends_with(' /channels/123/messages/:id')
	assert route_key(.put, '/channels/1/messages/2/reactions/%F0%9F%91%8D/@me').ends_with(' /channels/1/messages/:id/reactions/:reaction')
	assert route_key(.post, '/interactions/9/abc/callback').ends_with(' /interactions/9/:token/callback')
	assert major_param('/webhooks/7/tok/messages/1') == '7/tok'
	assert major_param('/users/@me') == 'global'
}

fn test_redact_hides_interaction_tokens() {
	assert redact('/interactions/1/secret/callback') == '/interactions/1/:token/callback'
	assert redact('/applications/1/commands') == '/applications/1/commands'
}
