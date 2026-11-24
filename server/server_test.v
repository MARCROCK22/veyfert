module server

import crypto.ed25519
import encoding.hex
import net.http
import time
import veyfert
import veyfert.testing

@[veyfert.Declare(name: 'fast', description: 'Answers at once')]
struct Fast {}

fn (f Fast) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'fast')!
}

@[veyfert.Declare(name: 'slow', description: 'Answers late')]
struct Slow {}

fn (s Slow) run(mut ctx veyfert.CommandContext) ! {
	time.sleep(300 * time.millisecond)
	ctx.write(content: 'slow')!
}

fn command(name string) string {
	return '{"id":"1","application_id":"2","type":2,"token":"tok","channel_id":"3","user":{"id":"4","username":"ana"},"data":{"id":"5","name":"${name}","type":1}}'
}

// post sends a request signed the way Discord signs them.
fn post(url string, body string, key ed25519.PrivateKey) !http.Response {
	timestamp := time.now().unix().str()
	signature := ed25519.sign(key, (timestamp + body).bytes())!
	return http.fetch(
		method: .post
		url:    url
		data:   body
		header: http.new_custom_header_from_map({
			'X-Signature-Ed25519':   hex.encode(signature)
			'X-Signature-Timestamp': timestamp
		})!
	)!
}

fn test_the_server_checks_signatures_and_answers_inline() ! {
	public, private := ed25519.generate_key()!
	_, stranger := ed25519.generate_key()!
	mut bot := veyfert.new_client(token: 'test')
	// The late answer is sent from another thread; testing.Transport locks what it records.
	mut api := testing.new_transport(testing.Response{
		body: '{"id":"1","channel_id":"2","author":{"id":"3","username":"x"},"content":"","timestamp":""}'
	})
	bot.rest.transport = api
	bot.commands.add(Fast{})
	bot.commands.add(Slow{})
	mut s := new_server(mut bot,
		public_key: hex.encode(public)
		host:       '127.0.0.1'
		port:       31950
		wait:       100 * time.millisecond
	)!
	s.listen()!
	spawn s.serve()
	defer {
		s.close()
	}
	url := 'http://127.0.0.1:31950/interactions'
	ping := '{"id":"1","application_id":"2","type":1,"token":"t"}'
	assert post(url, ping, private)!.body == '{"type":1}'
	// Discord checks that endpoints reject bad signatures.
	assert post(url, ping, stranger)!.status_code == 401
	assert post(url, ping + ' ', private)!.status_code == 200
	fast := post(url, command('fast'), private)!
	assert fast.body == '{"type":4,"data":{"content":"fast"}}'
	assert (fast.header.get(.content_type) or { '' }) == 'application/json'
	assert api.requests().len == 0
	// No answer within `wait`: the response defers, and the late answer edits it.
	slow := post(url, command('slow'), private)!
	assert slow.body == '{"type":5}'
	late := api.wait(1, 5 * time.second) or {
		assert false, 'the late answer never arrived'
		return
	}
	assert late.method == .patch
	assert late.url.ends_with('/webhooks/2/tok/messages/@original')
	assert late.body == '{"content":"slow"}'
	assert api.requests().len == 1
}

fn test_verify_rejects_tampering() ! {
	public, private := ed25519.generate_key()!
	sig := hex.encode(ed25519.sign(private, '1{}'.bytes())!)
	assert verify(public, '1', '{}', sig)
	assert !verify(public, '2', '{}', sig)
	assert !verify(public, '1', '{} ', sig)
	assert !verify(public, '1', '{}', 'zz')
}
