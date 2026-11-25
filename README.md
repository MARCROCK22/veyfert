# veyfert

A Discord bot framework for [V](https://vlang.io), inspired by
[Seyfert](https://github.com/tiramisulabs/seyfert). Commands, options, modals and events are
plain V structs: veyfert reads them at compile time, so a command's options are its typed
fields and an event listener gets a typed payload.

```v
import os
import veyfert
import veyfert.discord

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
	bot.commands.add(Greet{})
	bot.upload_commands()!
	bot.run()!
}
```

Status: 0.x, tested on Windows against Discord, and in CI on Linux, macOS and Windows with fake
gateways and `-race`. The API can still change; see [Deprecation policy](#deprecation-policy).

## What it has

- **Gateway:** sharding, also across processes; automatic resharding as the bot grows; resuming;
  zlib or zstd-stream compression; sessions kept across restarts.
- **Commands:** slash commands, subcommands and groups, context menus, Activity entry points,
  autocomplete, guards, hooks, translations, and prefix commands from the same structs.
- **Components:** buttons, selects, components v2, modals as structs, handlers routed by ID,
  prefix or regular expression, collectors and polls.
- **Events:** a typed listener for every gateway event, `wait_for`, collectors and custom events.
- **Data:** a typed cache with optional adapters for a shared store; shorters that keep it up to
  date; and a generated function for every REST endpoint, all within Discord's rate limits.
- **More:** plugins with imports, requirements, hooks and shared values; interactions over
  HTTP; a formatter; and a fake gateway and REST API for tests.

## Install

veyfert needs V 0.5 (master) with `json2`. It is on VPM:

```sh
v install MARCROCK22.veyfert
```

VPM puts it under the `marcrock22` prefix, so a bot imports `marcrock22.veyfert` and
`marcrock22.veyfert.discord`; in code the module is still `veyfert` (`veyfert.new_client`,
`@[veyfert.Declare(...)]`). The documentation imports `veyfert`, as a bot does when it uses a
clone in a folder named `veyfert`, with that folder's parent on V's module path:

```sh
git clone https://github.com/MARCROCK22/veyfert ~/vlibs/veyfert
v -path "@vlib|@vmodules|$HOME/vlibs" run bot.v
```

Set `DISCORD_TOKEN` and run it. [Getting started](docs/getting-started.md) goes from there.

## Documentation

[docs/](docs/README.md) has a page per part, each with examples; the complete programs in them are
built in CI.

| | |
|---|---|
| Basics | [Getting started](docs/getting-started.md) · [The client](docs/client.md) · [Commands](docs/commands.md) · [Answering](docs/responses.md) · [Guards](docs/guards.md) · [Components and modals](docs/components.md) · [Events](docs/events.md) · [Prefix commands](docs/prefix-commands.md) |
| The connection | [Gateway](docs/gateway.md) · [Resharding](docs/resharding.md) · [Interactions over HTTP](docs/http-interactions.md) |
| Data | [Cache](docs/cache.md) · [REST and shorters](docs/rest.md) · [Every endpoint](docs/rest-api.md) · [Discord's data](docs/models.md) · [Formatter](docs/formatter.md) |
| More | [Languages](docs/i18n.md) · [Plugins](docs/plugins.md) · [Testing](docs/testing.md) · [Known V issues](docs/known-issues.md) |

The repository also has [examples/](examples/README.md) (complete bots that build in CI),
`tests/compile_fail/` (code that must not compile), `tools/gen_api.vsh` (the REST generator),
`benchmarks/` and [docs/PLAN.md](docs/PLAN.md), the design and its decisions.

## Known V issues

veyfert works around several issues of V and its standard library, each reported upstream:
[docs/known-issues.md](docs/known-issues.md) lists them. Two matter when you deploy:

- Over `wss://`, V's `net.websocket` reads the TLS connection on one thread while others write
  to it, which the TLS backends do not support
  ([vlang/v#31772](https://github.com/vlang/v/issues/31772)); veyfert has no workaround yet.
- `-race` reports races inside `net.websocket`; `tests/tsan.supp` suppresses only those. Use it
  with `-race`, for veyfert or for your bot:
  `TSAN_OPTIONS="suppressions=<veyfert>/tests/tsan.supp"`.

## Deprecation policy

- Until 1.0, a minor version (0.x) may break the API. Every break is listed in CHANGELOG.md with
  what to change.
- A function, type or field that is going away is first marked `@[deprecated: 'use X']` and
  `@[deprecated_after: 'YYYY-MM-DD']`, at least one minor release and 30 days before removal. V
  warns where it is used, and turns that into an error after the date.
- The generated REST code follows the pinned discord-api-spec commit. Moving the pin is a minor
  release, with the endpoints and models that changed listed.
- From 1.0 on, breaking changes need a major version.

## License

MIT.
