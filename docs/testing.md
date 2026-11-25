# Testing a bot: veyfert.testing

`veyfert.testing` runs a bot without Discord: a fake gateway on 127.0.0.1, a fake REST API that
records requests, and the payloads Discord would send. Tests stay fast and need no token.

```v
// bot_test.v: run with `v test .`
import time
import veyfert
import veyfert.testing

@[veyfert.Declare(name: 'ping', description: 'Pong')]
struct Ping {}

fn (p Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'pong')!
}

fn test_ping_answers_through_the_gateway() ! {
	mut gw := testing.start_gateway(31999, ['30'])!
	mut fake_api := testing.new_transport()
	mut bot := testing.client(gw, fake_api)
	bot.commands.add(Ping{})
	spawn fn [mut bot] () {
		bot.run() or {}
	}()
	assert gw.wait_identified(2 * time.second)
	gw.dispatch('INTERACTION_CREATE', testing.command_interaction('ping', '[]'))!
	reply := fake_api.wait(1, 2 * time.second) or { return error('no answer') }
	assert reply.body.contains('pong')
	bot.stop()
}

// Without a gateway: the interaction goes in as an HTTP one, and the answer comes back.
fn test_ping_answers_without_a_gateway() {
	mut bot := testing.client(none, testing.new_transport())
	bot.commands.add(Ping{})
	answer := bot.handle_http(testing.command_interaction('ping', '[]'), time.second)
	assert answer.body.contains('pong')
}
```

## The fake gateway

`testing.start_gateway(port, guild_ids)!` plays Discord's side on `127.0.0.1:port`: it says
HELLO, answers IDENTIFY with READY and a GUILD_CREATE per guild, acknowledges heartbeats and
resumes. Give each test its own port.

| Method | Does |
|---|---|
| `gw.wait_identified(timeout)` | Waits for the bot's IDENTIFY and for its guilds to be sent |
| `gw.dispatch(name, json)!` | Sends an event, such as `INTERACTION_CREATE` or `MESSAGE_CREATE` |
| `gw.close(code)` | Closes the connection with a close code, or drops it with 0, to test reconnections |
| `gw.received()` | The opcode of every payload the bot sent, in order |
| `gw.url()` | Its `ws://` URL |

## The fake REST API

`testing.new_transport(responses...)` records every request and answers with the scripted
responses in turn, repeating the last; with none, it answers `200 {}`.

```v
mut fake_api := testing.new_transport(testing.Response{
	body: '{"id":"500","channel_id":"300","author":{"id":"1","username":"bot"},"content":"hi","timestamp":""}'
}, testing.Response{
	status: 403
	body:   '{"code":50013,"message":"Missing Permissions"}'
})
```

- `fake_api.requests()` returns the requests so far, with `method`, `url`, `headers` and `body`.
- `fake_api.wait(n, timeout)` waits for the `n`-th request (from 1) and returns it.

`testing.client(gateway, transport)` builds a quiet client on them, with one shard and one
thread per pool, so events are handled in order. Pass `none` as the gateway for a client that only
uses REST.

## Payloads

The payloads come from user 7 (`ana`) in channel 300 of guild 30, as Discord sends them:

| Function | Builds |
|---|---|
| `command_interaction(name, options_json)` | A slash command, with its options as JSON: `'[{"name":"text","type":3,"value":"hi"}]'` |
| `component_interaction(custom_id, values)` | A click, or a pick of `values`, on message 200 |
| `modal_submit(custom_id, values)` | A modal sent with its inputs, by input custom_id |
| `message_create(content)` | A message from ana, for listeners and prefix commands |

## Testing without the framework

Commands are structs, so their logic can be tested as plain functions too: build the struct with
its options set and call a method that does the work, leaving `run` to answer.

## Data races

veyfert's CI runs every test with `-race`. To do the same with your bot's tests, on Linux or
macOS, use veyfert's suppressions for the races inside V's `net.websocket` (see
[known-issues.md](known-issues.md)):

```sh
TSAN_OPTIONS="suppressions=$HOME/vlibs/veyfert/tests/tsan.supp" v -race test .
```
