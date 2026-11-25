# Interactions over HTTP: veyfert.server

Discord can send commands, components and modals to an HTTPS endpoint instead of through the
gateway. `veyfert.server` is that endpoint: it checks Discord's Ed25519 signature, answers PING,
and routes everything to the same commands and handlers a gateway bot has. A bot that only answers
interactions then needs no gateway connection at all.

```v
import os
import veyfert
import veyfert.server

@[veyfert.Declare(name: 'ping', description: 'Pong over HTTP')]
struct Ping {}

fn (p Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong, without a gateway')!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Ping{})
	bot.upload_commands()!
	// Behind a reverse proxy or a tunnel that terminates HTTPS:
	server.serve(mut bot,
		public_key: os.getenv('DISCORD_PUBLIC_KEY')
		host:       '127.0.0.1'
		port:       8080
	)!
}
```

## Setting it up

1. Run the bot where Discord can reach it over HTTPS: behind a reverse proxy (nginx, Caddy) or a
   tunnel that forwards to `host:port`. `veyfert.server` speaks plain HTTP/1.1.
2. In the Developer Portal, copy the application's **Public Key** into `public_key`.
3. Set **Interactions Endpoint URL** to the public URL plus `path` (`/interactions` by default).
   Discord sends a PING with a valid signature and a request with a bad one; veyfert answers both
   as Discord expects, and the Portal saves the URL.

Once set, Discord sends interactions to the endpoint only, not through the gateway.

## Options

| Field | Default | Meaning |
|---|---|---|
| `public_key` | required | The application's public key, in hex |
| `host` | every interface | The address to listen on; `127.0.0.1` behind a local proxy |
| `port` | 8080 | The port |
| `path` | `/interactions` | The path Discord posts to |
| `wait` | 2.5 s | How long an answer may take before veyfert defers it |

## Answers

Over HTTP, the first answer goes in the HTTP response, which Discord must get within 3 seconds.
A command that writes its answer in time answers in that response; one that takes longer than
`wait` is deferred for it, and its answer then edits the deferral. Commands do not change:
`ctx.write`, `defer_reply`, `followup` and the rest work as with the gateway. See
[responses.md](responses.md).

## With the gateway too

Events only come through the gateway. A bot that needs both serves HTTP on a thread and runs the
gateway:

```v
spawn fn [mut bot] () {
	server.serve(mut bot, public_key: os.getenv('DISCORD_PUBLIC_KEY')) or { panic(err) }
}()
bot.run()!
```

## Lower level

`server.new_server(mut bot, opts)!` makes a server without starting it: `listen()!` binds the
port, `serve()` answers until `close()`. `server.verify(public_key, timestamp, body, signature)`
checks a signature by itself. `bot.handle_http(body, wait)` turns a request body into the answer,
for bots behind a web framework of their own.
