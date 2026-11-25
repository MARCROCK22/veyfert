# Getting started

This page takes you from nothing to a bot that answers a slash command. The other pages explain
each part in depth; [the index](README.md) lists them.

## What you need

- V 0.5 (master), with `json2`. `v up` updates it.
- A Discord application with a bot: create it in the
  [Developer Portal](https://discord.com/developers/applications), open **Bot**, and copy the
  token. Keep it out of your code: the examples read it from `DISCORD_TOKEN`.
- The bot in a server. `formatter.oauth2_url` builds the invite link (see
  [formatter.md](formatter.md#oauth2-urls)), or use the Portal's **OAuth2 → URL Generator** with
  the `bot` and `applications.commands` scopes.

## Install

veyfert is on VPM:

```sh
v install MARCROCK22.veyfert
```

VPM puts it under the `marcrock22` prefix, so a bot imports `marcrock22.veyfert` and
`marcrock22.veyfert.discord`. In code the module is still `veyfert`: `veyfert.new_client`,
`@[veyfert.Declare(...)]`.

These pages import `veyfert`, as a bot does when it uses a clone in a folder named `veyfert`,
with that folder's parent on V's module path:

```sh
git clone https://github.com/MARCROCK22/veyfert ~/vlibs/veyfert
v -path "@vlib|@vmodules|$HOME/vlibs" run bot.v
```

## A first bot

```v
import os
import veyfert
import veyfert.discord

// A slash command is a struct with @[Declare] and a `run` method.
@[veyfert.Declare(name: 'ping', description: 'Replies with the gateway latency')]
struct Ping {}

fn (p Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong! ${ctx.client.latency().milliseconds()} ms')!
}

// An option is a field with @[Desc] in a `mut:` section; `?T` makes it optional.
@[veyfert.Declare(name: 'greet', description: 'Says hello')]
struct Greet {
mut:
	who  discord.User @[veyfert.Desc: 'Who to greet']
	loud ?bool        @[veyfert.Desc: 'Shout it']
}

fn (g Greet) run(mut ctx veyfert.CommandContext) ! {
	text := 'Hello, ${g.who.username}!'
	ctx.write(content: if g.loud or { false } { text.to_upper() } else { text })!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Ping{})
	bot.commands.add(Greet{})
	bot.on[veyfert.BotReady](fn (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('Ready as ${e.user.username} on ${e.shards} shard(s)')
	})
	// In development, upload to one server, where changes apply at once. Without GUILD_ID the
	// commands are global, which can take a while to show up everywhere.
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/commands.json' // skips the upload when nothing changed
	)!
	bot.run()!
}
```

Run it:

```sh
DISCORD_TOKEN=... GUILD_ID=... v run bot.v
```

`run` connects to the gateway and blocks until the bot stops. Type `/ping` in your server.

## What happened

- `new_client` made a client with the default options: the `guilds` intent, as many shards as
  Discord recommends, and four threads for listeners plus four for commands. See
  [client.md](client.md).
- `commands.add` read the struct at compile time: its attributes became the command's name and
  description, and its fields its options. Wrong option types do not compile. See
  [commands.md](commands.md).
- `upload_commands` sent the commands to Discord. With `cache_path` it remembers what it sent
  and skips identical uploads.
- `ctx.write` answered the interaction. See [responses.md](responses.md) for deferring,
  editing, followups, embeds and files.
- `bot.on[veyfert.BotReady]` registered a typed listener: the payload type names the event.
  See [events.md](events.md).

## Building for production

Build with `-prod` for an optimized binary:

```sh
v -prod -path "@vlib|@vmodules|$HOME/vlibs" -o bot bot.v
```

Privileged intents (`guild_members`, `guild_presences`, `message_content`) must also be turned
on in the Developer Portal, or Discord closes the connection with 4014 and `run` returns that
error.

## Next steps

- Buttons, selects and modals: [components.md](components.md).
- Commands from messages, such as `!ping`: [prefix-commands.md](prefix-commands.md).
- What the bot knows without asking Discord: [cache.md](cache.md).
- Calling Discord's REST API: [rest.md](rest.md) and [rest-api.md](rest-api.md).
- Testing a bot without Discord: [testing.md](testing.md).
