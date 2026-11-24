// Package ws is a minimal WebSocket server on the loopback interface, for tests. It binds
// 127.0.0.1 only, so firewalls do not ask to allow each test binary, as they do for
// net.websocket's server, which binds every interface.
module ws

import crypto.sha1
import encoding.base64
import net
import sync
import sync.stdatomic

// Conn is the server side of one connection.
@[heap]
pub struct Conn {
pub mut:
	path string // what the client asked for, such as /?v=10&encoding=json
mut:
	tcp    &net.TcpConn = unsafe { nil }
	mu     &sync.Mutex  = sync.new_mutex()
	closed bool // set under mu by the reading thread once it has closed the socket
}

pub fn (mut c Conn) write_string(text string) ! {
	c.frame(0x1, text.bytes())!
}

pub fn (mut c Conn) write_binary(data []u8) ! {
	c.frame(0x2, data)!
}

// close sends a close frame with `code`, then ends the connection.
pub fn (mut c Conn) close(code int, reason string) ! {
	mut payload := [u8(code >> 8), u8(code & 0xff)]
	payload << reason.bytes()
	c.frame(0x8, payload) or {}
	c.drop()
}

// drop ends the TCP connection without a close frame, as a network failure does.
pub fn (mut c Conn) drop() {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	// Only shut the socket down: closing it here would race with the reading thread's recv,
	// and on Linux would not wake it. That thread closes the socket once its read fails.
	if !c.closed {
		net.shutdown(c.tcp.sock.handle)
	}
}

fn (mut c Conn) frame(opcode u8, payload []u8) ! {
	mut out := [u8(0x80) | opcode]
	n := payload.len
	if n < 126 {
		out << u8(n)
	} else if n < 65536 {
		out << [u8(126), u8(n >> 8), u8(n & 0xff)]
	} else {
		out << u8(127)
		for shift := 56; shift >= 0; shift -= 8 {
			out << u8((u64(n) >> u64(shift)) & 0xff)
		}
	}
	out << payload
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	if c.closed {
		return error('connection closed')
	}
	c.tcp.write(out)!
}

// Server accepts connections on 127.0.0.1:port until `close`.
@[heap]
pub struct Server {
mut:
	listener   &net.TcpListener = unsafe { nil }
	on_connect fn (mut c Conn) !              @[required]
	on_message fn (mut c Conn, text string) ! @[required]
	closed     &stdatomic.AtomicVal[bool] = stdatomic.new_atomic(false)
}

// listen starts a server: `on_connect` runs after each handshake and `on_message` for each text
// or binary message.
pub fn listen(port int, on_connect fn (mut c Conn) !, on_message fn (mut c Conn, text string) !) !&Server {
	mut s := &Server{
		listener:   net.listen_tcp(.ip, '127.0.0.1:${port}')!
		on_connect: on_connect
		on_message: on_message
	}
	spawn s.accept()
	return s
}

pub fn (mut s Server) close() {
	s.closed.store(true)
	s.listener.close() or {}
}

fn (mut s Server) accept() {
	for !s.closed.load() {
		mut tcp := s.listener.accept() or { continue }
		spawn s.serve(mut tcp)
	}
}

fn (mut s Server) serve(mut tcp net.TcpConn) {
	mut c := &Conn{
		tcp: tcp
	}
	defer {
		c.mu.lock()
		c.closed = true
		tcp.close() or {}
		c.mu.unlock()
	}
	c.path = handshake(mut tcp) or { return }
	// net.TcpConn.read takes the connection by value, so every read copies the struct; reading
	// through this copy keeps those copies away from the writes that other threads make via `c`.
	mut reader := *tcp
	s.on_connect(mut c) or { return }
	mut message := []u8{}
	for {
		b := read_exact(mut reader, 2) or { return }
		opcode := b[0] & 0x0f
		masked := b[1] & 0x80 != 0
		mut n := u64(b[1] & 0x7f)
		if n == 126 {
			ext := read_exact(mut reader, 2) or { return }
			n = u64(ext[0]) << 8 | u64(ext[1])
		} else if n == 127 {
			ext := read_exact(mut reader, 8) or { return }
			n = 0
			for x in ext {
				n = n << 8 | u64(x)
			}
		}
		mask := if masked { read_exact(mut reader, 4) or { return } } else { []u8{} }
		mut payload := read_exact(mut reader, int(n)) or { return }
		if masked {
			for i in 0 .. payload.len {
				payload[i] ^= mask[i % 4]
			}
		}
		match opcode {
			0x0, 0x1, 0x2 {
				message << payload
				if b[0] & 0x80 != 0 {
					text := message.bytestr()
					message.clear()
					s.on_message(mut c, text) or { return }
				}
			}
			0x8 {
				c.frame(0x8, payload) or {}
				return
			}
			0x9 {
				c.frame(0xA, payload) or { return }
			}
			else {}
		}
	}
}

// handshake answers the HTTP upgrade request and returns the path it asked for.
fn handshake(mut tcp net.TcpConn) !string {
	mut head := []u8{}
	mut buf := []u8{len: 1}
	for !head.bytestr().ends_with('\r\n\r\n') {
		if tcp.read(mut buf)! <= 0 || head.len > 16384 {
			return error('bad handshake')
		}
		head << buf[0]
	}
	mut key := ''
	for line in head.bytestr().split('\r\n') {
		if line.to_lower().starts_with('sec-websocket-key:') {
			key = line.all_after(':').trim_space()
		}
	}
	if key == '' {
		return error('no Sec-WebSocket-Key')
	}
	accept := base64.encode(sha1.sum('${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11'.bytes()))
	tcp.write_string('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n')!
	return head.bytestr().all_before('\r\n').split(' ')[1] or { '/' }
}

fn read_exact(mut tcp net.TcpConn, n int) ![]u8 {
	mut out := []u8{cap: n}
	mut buf := []u8{len: if n > 4096 {
		4096
	} else if n > 0 {
		n
	} else {
		1
	}}
	for out.len < n {
		want := if n - out.len < buf.len { n - out.len } else { buf.len }
		got := tcp.read(mut buf[..want])!
		if got <= 0 {
			return error('connection closed')
		}
		out << buf[..got]
	}
	return out
}
