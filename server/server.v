// Package server receives interactions over HTTP: set the app's Interactions Endpoint URL to
// this server, behind HTTPS (a reverse proxy or a tunnel), and Discord sends commands,
// components and modals here instead of through the gateway.
module server

import crypto.ed25519
import encoding.hex
import net
import sync.stdatomic
import time
import veyfert

@[params]
pub struct Options {
pub:
	public_key string @[required] // the application's public key, in hex, from the developer portal
	host       string // the address to listen on: every interface when empty, 127.0.0.1 behind a local proxy
	port       int           = 8080
	path       string        = '/interactions'
	wait       time.Duration = 2500 * time.millisecond // how long an answer may take before a defer
}

// Server is a small HTTP/1.1 server for Discord's POSTs.
// ponytail: not net.http.Server, whose default DebugHandler does not compile with this V
// (PLAN.md, risk 17); one thread per request and no keep-alive, which Discord's traffic fits.
@[heap]
pub struct Server {
	public_key []u8
	path       string
	wait       time.Duration
	host       string
	port       int
mut:
	client   &veyfert.Client            = unsafe { nil }
	listener &net.TcpListener           = unsafe { nil }
	stopped  &stdatomic.AtomicVal[bool] = stdatomic.new_atomic(false)
}

pub fn new_server(mut bot veyfert.Client, opts Options) !&Server {
	key := hex.decode(opts.public_key) or { return error('veyfert.server: the public key is not hex') }
	if key.len != ed25519.public_key_size {
		return error('veyfert.server: the public key has ${key.len} bytes; it needs ${ed25519.public_key_size}')
	}
	return &Server{
		public_key: key
		path:       opts.path
		wait:       opts.wait
		host:       opts.host
		port:       opts.port
		client:     bot
	}
}

// listen binds the port; `serve` then answers requests.
pub fn (mut s Server) listen() ! {
	s.listener = net.listen_tcp(.ip, '${s.host}:${s.port}')!
}

// serve answers requests until `close`.
pub fn (mut s Server) serve() {
	for !s.stopped.load() {
		mut conn := s.listener.accept() or { continue }
		spawn s.answer(mut conn)
	}
}

pub fn (mut s Server) close() {
	s.stopped.store(true)
	s.listener.close() or {}
}

// serve answers interactions over HTTP until the process stops. Commands, components and
// modals registered on `bot` work as with the gateway; `bot.run()` is only needed for events.
pub fn serve(mut bot veyfert.Client, opts Options) ! {
	mut s := new_server(mut bot, opts)!
	s.listen()!
	bot.logger.info('interactions endpoint on :${opts.port}${opts.path}')
	s.serve()
}

fn (mut s Server) answer(mut conn net.TcpConn) {
	defer {
		conn.close() or {}
	}
	conn.set_read_timeout(10 * time.second)
	req := read_request(mut conn) or {
		write_response(mut conn, 400, 'text/plain', 'bad request')
		return
	}
	if req.method != 'POST' || req.path.all_before('?') != s.path {
		write_response(mut conn, 404, 'text/plain', 'not found')
		return
	}
	if !verify(s.public_key, req.headers['x-signature-timestamp'], req.body, req.headers['x-signature-ed25519']) {
		write_response(mut conn, 401, 'text/plain', 'invalid request signature')
		return
	}
	answer := s.client.handle_http(req.body, s.wait)
	write_response(mut conn, answer.status, answer.content_type, answer.body)
}

// verify checks Discord's signature of `timestamp + body`; Discord tests the endpoint with
// bad signatures and expects a 401.
pub fn verify(public_key []u8, timestamp string, body string, signature string) bool {
	sig := hex.decode(signature) or { return false }
	if public_key.len != ed25519.public_key_size || sig.len != ed25519.signature_size {
		return false
	}
	return ed25519.verify(public_key, (timestamp + body).bytes(), sig) or { false }
}

struct Request {
	method  string
	path    string
	headers map[string]string // names in lowercase
	body    string
}

const max_head = 16 * 1024
const max_body = 1024 * 1024

fn read_request(mut conn net.TcpConn) !Request {
	mut buf := []u8{len: 4096}
	mut data := []u8{}
	mut head_end := -1
	for head_end < 0 {
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('connection closed')
		}
		data << buf[..n]
		head_end = data.bytestr().index('\r\n\r\n') or { -1 }
		if head_end < 0 && data.len > max_head {
			return error('headers too large')
		}
	}
	lines := data[..head_end].bytestr().split('\r\n')
	first := lines[0].split(' ')
	if first.len < 2 {
		return error('bad request line')
	}
	mut headers := map[string]string{}
	for line in lines[1..] {
		if i := line.index(':') {
			headers[line[..i].trim_space().to_lower()] = line[i + 1..].trim_space()
		}
	}
	length := headers['content-length'].int()
	if length < 0 || length > max_body {
		return error('body too large')
	}
	mut body := data[head_end + 4..].clone()
	for body.len < length {
		n := conn.read(mut buf)!
		if n <= 0 {
			return error('connection closed')
		}
		body << buf[..n]
	}
	return Request{
		method:  first[0]
		path:    first[1]
		headers: headers
		body:    body[..length].bytestr()
	}
}

fn write_response(mut conn net.TcpConn, status int, content_type string, body string) {
	reason := match status {
		200 { 'OK' }
		400 { 'Bad Request' }
		401 { 'Unauthorized' }
		404 { 'Not Found' }
		else { 'Error' }
	}
	conn.write_string('HTTP/1.1 ${status} ${reason}\r\nContent-Type: ${content_type}\r\nContent-Length: ${body.len}\r\nConnection: close\r\n\r\n${body}') or {}
}
