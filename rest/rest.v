module rest

import json2
import net.http
import net.urllib
import rand
import ratelimit
import strings
import sync
import time
import veyfert.discord

pub const api_base = 'https://discord.com/api/v10'

// DiscordError is a non-2xx answer from the REST API.
pub struct DiscordError {
	Error
pub:
	method     string
	route      string // the request path, with interaction and webhook tokens redacted
	status     int
	error_code int // Discord's JSON error code; 0 when the body had none
	message    string
	body       string // the raw body, which holds per-field validation errors
}

pub fn (e DiscordError) msg() string {
	return 'discord: ${e.method} ${e.route} -> ${e.status} (code ${e.error_code}): ${e.message}'
}

pub fn (e DiscordError) code() int {
	return e.error_code
}

struct ApiErrorBody {
	code    int
	message string
}

struct RateLimitBody {
	retry_after f64
	global      bool
}

// HttpRequest and HttpResponse are what a Transport exchanges. Header names in a response
// are lowercase.
pub struct HttpRequest {
pub:
	method     http.Method
	url        string
	headers    map[string]string
	body       string
	user_agent string
}

pub struct HttpResponse {
pub:
	status  int
	headers map[string]string
	body    string
}

// Transport sends one HTTP request. `net.http` is the default; tests pass a fake.
pub interface Transport {
mut:
	send(req HttpRequest) !HttpResponse
}

struct NetTransport {}

fn (mut t NetTransport) send(req HttpRequest) !HttpResponse {
	mut header := http.new_header()
	for name, value in req.headers {
		header.add_custom(name, value)!
	}
	resp := http.fetch(
		method:     req.method
		url:        req.url
		header:     header
		data:       req.body
		user_agent: req.user_agent
	)!
	mut headers := map[string]string{}
	for name in resp.header.keys() {
		headers[name.to_lower()] = resp.header.get_custom(name) or { '' }
	}
	return HttpResponse{
		status:  resp.status_code
		headers: headers
		body:    resp.body
	}
}

// RequestOptions shape a raw request; generated endpoints take CallOptions instead.
@[params]
pub struct RequestOptions {
pub:
	body   string // JSON
	query  string // already encoded, without `?`
	reason string // written to the audit log
	files  []discord.File
	auth   bool = true
}

// CallOptions are the options every generated endpoint accepts.
@[params]
pub struct CallOptions {
pub:
	reason string         // written to the audit log
	files  []discord.File // sent as multipart, where the endpoint accepts files
}

// RestEvent describes one attempt of a request, for observers.
pub struct RestEvent {
pub:
	method   string
	route    string
	status   int // 0 when no response came back
	attempt  int
	duration time.Duration
}

@[heap]
struct Bucket {
mut:
	mu        &sync.Mutex = sync.new_mutex()
	remaining int         = 1
	reset_at  time.Time
}

// Limiter keeps requests within Discord's limits: one bucket per route until Discord names
// the shared bucket in `x-ratelimit-bucket`, a global budget per token, and a global block
// after a global 429.
@[heap]
struct Limiter {
mut:
	mu           &sync.Mutex = sync.new_mutex()
	buckets      map[string]&Bucket
	aliases      map[string]string
	global_until time.Time
	global       &ratelimit.TokenBucket = ratelimit.new_token_bucket(rate_per_sec: 50.0, burst: 50)
}

// Rest sends authenticated requests to the Discord API.
pub struct Rest {
pub:
	token      string
	user_agent string
pub mut:
	transport Transport = NetTransport{} // tests swap in a fake
mut:
	limiter   &Limiter = &Limiter{}
	observers []fn (RestEvent)
	// How long a 502 or 503 waits per attempt; tests shorten it.
	retry_delay time.Duration = 500 * time.millisecond
}

// observe calls `f` after every attempt of every request. Register observers before use.
pub fn (mut r Rest) observe(f fn (RestEvent)) {
	r.observers << f
}

// request sends a request within the rate limits and returns the response body, '' for 204.
// It waits out 429s and retries 502 and 503 three times.
pub fn (mut r Rest) request(method http.Method, path string, opts RequestOptions) !string {
	route := route_key(method, path)
	exempt := path.starts_with('/interactions/') // interactions skip the global limit
	mut attempt := 0
	for {
		attempt++
		mut bucket := r.limiter.bucket(route)
		bucket.mu.lock()
		bucket.wait_turn()
		if !exempt {
			r.limiter.wait_global()
		}
		started := time.now()
		resp := r.send_once(method, path, opts) or {
			bucket.mu.unlock()
			r.notify(method, path, 0, attempt, started)
			return err
		}
		bucket.update(resp)
		// A route that joins a bucket Discord already named feeds its headers to that bucket.
		mut shared_bucket := r.limiter.learn(route, path, resp)
		bucket.mu.unlock()
		if !isnil(shared_bucket) && voidptr(shared_bucket) != voidptr(bucket) {
			shared_bucket.mu.lock()
			shared_bucket.update(resp)
			shared_bucket.mu.unlock()
		}
		r.notify(method, path, resp.status, attempt, started)
		if resp.status == 429 && attempt < 5 {
			wait := retry_after(resp)
			if resp.headers['x-ratelimit-global'] == 'true' {
				r.limiter.block_global(wait)
			} else {
				bucket.block(wait)
			}
			continue
		}
		if resp.status in [502, 503] && attempt < 4 {
			time.sleep(r.retry_delay * attempt)
			continue
		}
		if resp.status >= 300 {
			info := json2.decode[ApiErrorBody](resp.body) or { ApiErrorBody{} }
			return DiscordError{
				method:     method.str()
				route:      redact(path)
				status:     resp.status
				error_code: info.code
				message:    info.message
				body:       resp.body
			}
		}
		return resp.body
	}
	return error('unreachable')
}

// get decodes a GET response into T.
pub fn (mut r Rest) get[T](path string) !T {
	return json2.decode[T](r.request(.get, path)!)!
}

fn (mut r Rest) send_once(method http.Method, path string, opts RequestOptions) !HttpResponse {
	mut headers := map[string]string{}
	if opts.auth {
		headers['Authorization'] = 'Bot ${r.token}'
	}
	if opts.reason != '' {
		headers['X-Audit-Log-Reason'] = urllib.query_escape(opts.reason).replace('+', '%20')
	}
	mut body := opts.body
	if opts.files.len > 0 {
		content_type, form := multipart(opts.body, opts.files)
		headers['Content-Type'] = content_type
		body = form
	} else if body != '' {
		headers['Content-Type'] = 'application/json'
	}
	url := if opts.query == '' { api_base + path } else { '${api_base}${path}?${opts.query}' }
	return r.transport.send(HttpRequest{
		method:     method
		url:        url
		headers:    headers
		body:       body
		user_agent: r.user_agent
	})!
}

fn (r &Rest) notify(method http.Method, path string, status int, attempt int, started time.Time) {
	if r.observers.len == 0 {
		return
	}
	event := RestEvent{
		method:   method.str()
		route:    redact(path)
		status:   status
		attempt:  attempt
		duration: time.now() - started
	}
	for f in r.observers {
		f(event)
	}
}

// bucket returns the bucket a route uses, following what Discord taught about shared buckets.
fn (mut l Limiter) bucket(route string) &Bucket {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	key := l.aliases[route] or { route }
	if b := l.buckets[key] {
		return b
	}
	b := &Bucket{}
	l.buckets[key] = b
	return b
}

// learn maps a route to the bucket Discord named, shared by every route with that hash and
// the same major parameter, and returns that bucket; nil when Discord named none.
fn (mut l Limiter) learn(route string, path string, resp HttpResponse) &Bucket {
	hash := resp.headers['x-ratelimit-bucket'] or { return unsafe { nil } }
	key := '${hash}:${major_param(path)}'
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	l.aliases[route] = key
	if key !in l.buckets {
		l.buckets[key] = l.buckets[route] or { &Bucket{} }
	}
	return l.buckets[key] or { unsafe { nil } }
}

fn (mut l Limiter) wait_global() {
	for {
		l.mu.lock()
		until := l.global_until
		l.mu.unlock()
		now := time.now()
		if now < until {
			time.sleep(until - now)
			continue
		}
		if l.global.allow() {
			return
		}
		time.sleep(5 * time.millisecond)
	}
}

fn (mut l Limiter) block_global(wait time.Duration) {
	l.mu.lock()
	l.global_until = time.now().add(wait)
	l.mu.unlock()
}

// wait_turn runs with the bucket locked: requests of one bucket go out one at a time.
fn (mut b Bucket) wait_turn() {
	if b.remaining > 0 {
		return
	}
	now := time.now()
	if now < b.reset_at {
		time.sleep(b.reset_at - now)
	}
	b.remaining = 1
}

fn (mut b Bucket) update(resp HttpResponse) {
	if remaining := resp.headers['x-ratelimit-remaining'] {
		b.remaining = remaining.int()
	}
	if after := resp.headers['x-ratelimit-reset-after'] {
		b.reset_at = time.now().add(time.Duration(i64(after.f64() * f64(time.second))))
	}
}

fn (mut b Bucket) block(wait time.Duration) {
	b.mu.lock()
	b.remaining = 0
	b.reset_at = time.now().add(wait)
	b.mu.unlock()
}

// retry_after reads how long a 429 asks to wait, from the body or the headers.
fn retry_after(resp HttpResponse) time.Duration {
	mut seconds := 0.0
	if info := json2.decode[RateLimitBody](resp.body) {
		seconds = info.retry_after
	}
	if seconds <= 0 {
		seconds = (resp.headers['retry-after'] or { '1' }).f64()
	}
	return time.Duration(i64(seconds * f64(time.second)))
}

// route_key names the limit a request falls under before Discord names its bucket: the
// method and the path, with IDs other than the major parameter replaced.
fn route_key(method http.Method, path string) string {
	parts := path.trim_left('/').split('/')
	mut out := []string{cap: parts.len}
	for i, part in parts {
		if i == 1 && parts[0] in ['channels', 'guilds', 'webhooks', 'interactions'] {
			out << part // the major parameter
		} else if i == 2 && parts[0] in ['webhooks', 'interactions'] {
			out << ':token'
		} else if i > 0 && parts[i - 1] == 'reactions' {
			out << ':reaction'
			break // every reaction route of a message shares a limit
		} else if part.len > 0 && part.bytes().all(it >= `0` && it <= `9`) {
			out << ':id'
		} else {
			out << part
		}
	}
	return '${method} /${out.join('/')}'
}

fn major_param(path string) string {
	parts := path.trim_left('/').split('/')
	if parts.len > 2 && parts[0] == 'webhooks' {
		return '${parts[1]}/${parts[2]}'
	}
	if parts.len > 1 && parts[0] in ['channels', 'guilds', 'webhooks', 'interactions'] {
		return parts[1]
	}
	return 'global'
}

// redact hides the token segment of interaction and webhook routes, since it grants access to them.
fn redact(path string) string {
	parts := path.split('/')
	if parts.len > 3 && parts[1] in ['interactions', 'webhooks'] {
		mut out := parts.clone()
		out[3] = ':token'
		return out.join('/')
	}
	return path
}

// multipart encodes `payload_json` and the files; Discord references them as `files[n]`.
pub fn multipart(payload_json string, files []discord.File) (string, string) {
	boundary := 'veyfert${rand.u64()}'
	mut sb := strings.new_builder(1024)
	if payload_json != '' {
		sb.write_string('--${boundary}\r\nContent-Disposition: form-data; name="payload_json"\r\nContent-Type: application/json\r\n\r\n${payload_json}\r\n')
	}
	for i, f in files {
		name := f.name.replace_each(['"', '_', '\r', '_', '\n', '_'])
		sb.write_string('--${boundary}\r\nContent-Disposition: form-data; name="files[${i}]"; filename="${name}"\r\nContent-Type: ${f.content_type}\r\n\r\n')
		sb.write(f.data) or {}
		sb.write_string('\r\n')
	}
	sb.write_string('--${boundary}--\r\n')
	return 'multipart/form-data; boundary=${boundary}', sb.str()
}
