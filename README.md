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

Status: 0.x, tested on Windows against Discord and with fake gateways. The API can still
change; see [Deprecation policy](#deprecation-policy).

## Contents

- [Layout](#layout)
- [Install](#install)
- [Commands](#commands)
- [Components and modals](#components-and-modals)
- [Events](#events)
- [Cache and shorters](#cache-and-shorters)
- [Prefix commands](#prefix-commands)
- [Languages](#languages)
- [Plugins](#plugins)
- [Interactions over HTTP](#interactions-over-http)
- [Testing your bot](#testing-your-bot)
- [Gateway and REST](#gateway-and-rest)
- [Known V issues](#known-v-issues)
- [Deprecation policy](#deprecation-policy)

## Layout

In V a folder is a module. veyfert is split by layer, and a bot imports the layers it uses:

| Module | What it has |
|---|---|
| `veyfert` | The framework: `Client`, gateway and sharding, commands, contexts, guards, component and modal handlers, shorters, prefix commands, languages and plugins |
| `veyfert.discord` | Discord's data: users, members, channels, messages, guilds, events, components and their constructors, embeds, polls, permissions, intents, snowflakes and files |
| `veyfert.cache` | The in-memory cache (`cache.Options`) |
| `veyfert.rest` | The HTTP client: rate limits, transports, errors (`rest.DiscordError`) |
| `veyfert.rest.api` | One generated function per REST endpoint |
| `veyfert.plugins` | Official plugins, such as `plugins.Scheduler` |
| `veyfert.server` | Interactions received over HTTP |
| `veyfert.testing` | A fake gateway and REST API for tests (`veyfert.testing.ws` is its WebSocket server) |

Most bots import `veyfert` and `veyfert.discord`. The repository also has `examples/`,
`tests/compile_fail/` (code that must not compile), `tools/gen_api.vsh` (the REST generator),
`benchmarks/` and `docs/PLAN.md` (the design and its decisions).

## Install

veyfert needs V 0.5 (master) with `json2`. Until it is on VPM, clone it into a folder named
`veyfert` and add its parent folder to V's module path:

```sh
git clone https://github.com/MARCROCK22/veyfert ~/vlibs/veyfert
v -path "@vlib|@vmodules|$HOME/vlibs" run bot.v
```

Set `DISCORD_TOKEN`. While developing, upload commands to a test server, where changes apply at
once: `bot.upload_commands(guild_id: discord.Snowflake.parse(id)!, cache_path: '.veyfert/commands.json')!`.
With `cache_path`, unchanged commands are not uploaded again.

## Commands

A command is a struct with `@[veyfert.Declare(name:, description:)]` and a
`run(mut ctx veyfert.CommandContext) !` method.

### Options

A field with `@[veyfert.Desc: '...']` in a `mut:` section is an option. Its type sets the option
type, and `?T` makes it optional:

| Field type | Option |
|---|---|
| `string`, `int`, `i64`, `f64`, `bool` | text, integer, number, boolean |
| an enum | text with the enum's values as choices; `@[veyfert.Label: 'Shown name']` on a value renames it |
| `discord.User`, `discord.Member` | user (a `Member` must be in the server) |
| `discord.Channel`, `discord.Role`, `discord.Mentionable`, `discord.Attachment` | channel, role, user or role, file |

More attributes, one value each: `Min`, `Max` (numbers), `MinLength`, `MaxLength` (text),
`Channels: 'guild_text,guild_voice'`, and `Autocomplete`. Fields without attributes are
dependencies, such as a database handle: they travel with every copy of the command.

Unsupported option types and options outside `mut:` fail to compile; Discord's other rules
(name lengths, 25 options, required before optional) are checked when the command is added.

### Answering

`ctx.write(...)` answers once. `ctx.defer_reply(ephemeral)` buys 15 minutes; then
`ctx.edit_response(...)`. After the answer come `ctx.followup(...)`, `ctx.fetch_response()` and
`ctx.delete_response()`; `ctx.edit_or_reply(...)` does whichever fits. `MessageOptions` holds
`content`, `embeds`, `components`, `files`, `poll`, `allowed_mentions`, `ephemeral`, `tts`,
`flags` and `reply_to`.

### Subcommands and context menus

Fields marked `@[veyfert.Sub]` are subcommands; a subcommand with `@[Sub]` fields of its own is
a group:

```v
@[veyfert.Declare(name: 'config', description: 'Server settings')]
struct Config {
mut:
	greeting Greeting   @[veyfert.Sub]
	mod      Moderation @[veyfert.Sub] // has subcommands of its own: a group
}
```

`@[veyfert.UserMenu('Show avatar')]` and `@[veyfert.MessageMenu('Count words')]` declare context
menu commands; their `run` reads `ctx.target_user()` or `ctx.target_message()`.

### Autocomplete

Mark the option with `@[veyfert.Autocomplete]` and add a method:

```v
fn (s Search) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	ctx.respond(s.items.filter(it.starts_with(ctx.value)).map(veyfert.Choice{ name: it, value: it }))!
}
```

### Guards

A field whose type has `check(mut ctx veyfert.CommandContext) !` is a guard: it runs before
`run`, and before every subcommand when it is on a group. Its state after `check` is there for
`run`. `return veyfert.deny('reason')` stops the command and tells the user;
`return veyfert.stop()` stops it silently.

```v
struct Search {
mut:
	cd    veyfert.Cooldown           = veyfert.cooldown(3, 10 * time.second)
	perms veyfert.RequirePermissions = veyfert.require_permissions(.manage_messages)
	text  string @[veyfert.Desc: 'What to look for']
}
```

`bot.commands.use(guard)` adds a guard to every command. The order is: the bot's permissions
(`@[veyfert.BotPerms('ban_members')]`), options, global guards, the groups' guards, then the
command's.

### Hooks and declaration attributes

Optional methods handle failures: `on_run_error(mut ctx, failure IError) !`,
`on_options_error`, `on_guard_error(mut ctx, reason string) !` and
`on_bot_permissions_fail(mut ctx, missing discord.Permissions) !`. Without them,
`bot.commands.defaults` answers; you can replace those functions.

More struct attributes: `Perms('manage_guild')` (members without it do not see the command),
`Nsfw`, `Guilds('id1,id2')` (upload only there), `Contexts('guild,bot_dm,private_channel')`,
`Integrations('guild_install,user_install')`, `Aliases('a,b')` and
`Ignore('slash'|'prefix')`.

## Components and modals

Components are flat structs that `veyfert.discord` builds: `action_row`, `button`,
`string_select`, `user_select`, `role_select`, `mentionable_select`, `channel_select` and
`text_input`. Components v2 add `container`, `section`, `text_display`, `thumbnail`,
`media_gallery`, `file_component` and `separator`, and veyfert sets the IS_COMPONENTS_V2 flag for
you. Modals add `label`, `file_upload`, `radio_group`, `checkbox_group` and `checkbox`.
`Embed.validate()` checks Discord's limits, and messages are validated before they are sent.

```v
ctx.write(
	content:    'Pick one'
	components: [discord.action_row(discord.button(style: .success, label: 'Yes', custom_id: 'vote:yes'))]
)!
```

A handler is a struct with `@[veyfert.CustomId('id')]` or `@[veyfert.CustomIdPrefix('vote:')]`
and `run(mut ctx veyfert.ComponentContext) !`, added with `bot.components.add(Vote{})`.
`ctx.update(...)` edits the message and `ctx.defer_update()` acknowledges it.

A modal is a struct: fields with `@[veyfert.Label: '...']` are its inputs (`string`, `?string`,
or an enum for a select), plus `Paragraph`, `Placeholder`, `MinLength`, `MaxLength` and `Desc`.
`ctx.modal(Feedback{})!` opens it, prefilled with the fields' values, and
`bot.modals.add(Feedback{})` routes submissions to its `submit(mut ctx veyfert.ModalContext) !`,
with the fields filled.

Inside a command, `ctx.wait_for_component(timeout: 30 * time.second)` and
`ctx.wait_for_modal(Feedback{}, time.minute)` wait for the user's next click or submission. Those
interactions skip the handlers.

## Events

A listener's payload type names its event:

```v
bot.on[discord.MessageCreate](fn (m discord.MessageCreate, mut c veyfert.Client) ! {
	if m.content == 'ping' {
		c.messages.reply(m.Message, content: 'pong')!
	}
})
```

`once[T]` runs a listener for the next event only. `wait_for[T](filter, timeout)` blocks until
an event passes `filter`. `on_raw` sees every dispatch before decoding. `emit[T]` sends your own
events (a struct with `@[discord.Event('NAME')]`).

Listeners run on a pool of `workers` threads, and commands on their own pool, because Discord
gives 3 seconds to answer. State that listeners share needs `shared` or `sync`; `workers: 1`
runs them in order. The framework's own events are `veyfert.GuildsReady` (per shard),
`veyfert.BotReady` (once, for every shard), `veyfert.ShardDisconnect` and
`veyfert.ShardReconnect`. At startup, guilds arrive as `veyfert.RawGuildCreate`, and
`discord.GuildCreate` means a new guild. Repeated `GuildMemberUpdate` and `PresenceUpdate`
events reach only raw listeners.

## Cache and shorters

`bot.cache` keeps what the gateway sends, as typed structs: guilds, channels and threads,
roles, users, members, emojis, stickers, presences, voice states, stage instances, bans seen
since startup, and with `cache: cache.Options{ messages: 100 }` (from `veyfert.cache`) the last
messages of each channel. `cache.Options` also turns resources off, and
`bot.cache.permissions(guild, user, roles, channel)` works out a member's permissions in a
channel.

Shorters wrap the common endpoints: `bot.messages`, `reactions`, `channels`, `members`,
`roles`, `guilds`, `users`, `threads`, `webhooks`, `bans` and `emojis`. As in Seyfert, each call
asks Discord, keeps the answer in the cache, then returns it; `fetch` reads the cache first
(`force: true` asks Discord). `bot.messages.reply(msg, content: ...)` quotes a message, and
`bot.members.ban(guild_id, user_id, 24 * time.hour, 'raid')` moderates by ID.

## Prefix commands

With `prefixes: ['!']` in `ClientOptions`, or a function in `bot.commands.prefix`, the same
commands run from messages. Mentioning the bot also works as a prefix:

```
!search "two words" 5
!ban @ana -reason spamming links
```

Options come in order, or by name with `-name value`, and the last text option takes the rest
of the line. Users, roles and channels can be mentions or IDs, and attachment options take the
message's attachments. Answers become messages in the channel. Guild messages need the
privileged MESSAGE_CONTENT intent, except those that mention the bot.

## Languages

`Langs[T]` maps locales to a struct of your texts. With `@[required]` fields, a language that
forgets one does not compile:

```v
struct Texts {
	hello fn (name string) string @[required]
	ping  veyfert.CommandText     @[required]
}

mut langs := veyfert.Langs[Texts]{}
langs.add('en-US', english)
langs.add('es-ES', spanish)
t := langs.of(ctx.interaction) // the user's language, or the server's with prefer_guild_locale
```

`@[veyfert.Locale('ping')]` on a command and `bot.commands.localize(langs)` translate names,
descriptions and choices for Discord.

## Plugins

A plugin implements `name()`, `setup(mut c) !` and `teardown(mut c) !`; install it with
`bot.install(mut p)!`. Plugins can use `bot.commands.observe` (a `CommandEvent` after every
command), `bot.rest.observe` (every REST attempt), `bot.intercept` (change or drop incoming
events) and `bot.intercept_send` (change or drop what a shard sends).
`veyfert.plugins` has the official ones, such as `plugins.Scheduler`, which runs jobs on an
interval.

## Interactions over HTTP

`veyfert.server` receives interactions on an HTTPS endpoint (behind a reverse proxy or a
tunnel) instead of the gateway. It checks Discord's Ed25519 signature, answers PING, and sends
your first answer in the HTTP response. A deferral goes out at 2.5 seconds, and a later answer
edits it.

```v
import veyfert.server

server.serve(mut bot, public_key: os.getenv('PUBLIC_KEY'), port: 8080)!
```

## Testing your bot

`veyfert.testing` runs a bot without Discord: `start_gateway(port, guild_ids)` plays the gateway
on 127.0.0.1, `new_transport(responses...)` records REST requests, `client(gateway, transport)`
connects them, and `command_interaction`, `component_interaction`, `modal_submit` and
`message_create` build payloads.

```v
mut gw := testing.start_gateway(31999, ['30'])!
mut fake_api := testing.new_transport()
mut bot := testing.client(gw, fake_api)
bot.commands.add(Ping{})
spawn fn [mut bot] () {
	bot.run() or {}
}()
gw.wait_identified(time.second)
gw.dispatch('INTERACTION_CREATE', testing.command_interaction('ping', '[]'))!
reply := fake_api.wait(1, time.second) or { panic('no reply') }
assert reply.body.contains('pong')
```

## Gateway and REST

- **Sharding:** `shards: veyfert.ShardRange{start: 0, end: 4, total: 8}` runs part of a sharded
  bot. Identifies follow `max_concurrency`, and `bot.reconnect(shard)` drops a connection.
- **Compression:** `compress: true` has Discord zlib-compress large payloads. `zstd: true`
  compresses the whole connection, if you build with `-d veyfert_zstd`.
  `max_message_bytes` raises the 8 MiB message limit.
- **Restarts:** `bot.save_sessions(path)` when stopping and
  `sessions: veyfert.load_sessions(path)` on start resume instead of identifying. Discord replays
  the missed events, but the cache starts empty.
- **Gateway requests:** `request_members`, `set_presence` and `update_voice_state` are on the
  client.
- **Attachments:** `files: [discord.file_from_path('chart.png')!]`, or a `discord.File` with
  bytes.
- **REST:** requests follow Discord's rate limits: shared buckets, the global limit, and
  retries of 429, 502 and 503. A non-2xx answer is a `rest.DiscordError`.
- **Every endpoint:** `veyfert.rest.api` has one generated function per endpoint of Discord's
  OpenAPI spec (pinned in `tools/gen_api.vsh`). It is a separate module, so bots that do not
  import it do not compile it:

  ```v
  import veyfert.rest.api

  mut endpoints := api.new(mut bot.rest)
  guild := endpoints.get_guild(guild_id)!
  ```

  Unions arrive as `discord.RawJson`, with `.decode[T]()`. In PATCH bodies,
  `?discord.Nullable[T]` tells "unchanged" (none) from "clear" (`{is_null: true}`).

## Known V issues

veyfert works around these V issues; [docs/PLAN.md](docs/PLAN.md) (risks 12-21) has the
details:

- `v fmt` flattens field attributes that take several arguments
  ([vlang/v#32875](https://github.com/vlang/v/issues/32875)), so field attributes take one value.
- A generic call under `$if a is Schema` is instantiated for every field
  ([vlang/v#32876](https://github.com/vlang/v/issues/32876)), so guards are found by type; `v -check`
  misses a `$compile_error` in those branches ([vlang/v#32877](https://github.com/vlang/v/issues/32877)).
- `net.websocket` reports one close twice ([vlang/v#32878](https://github.com/vlang/v/issues/32878)),
  so the shard keeps the first report of each connection.
- `json2` writes `@[raw]` fields back as strings ([vlang/v#32879](https://github.com/vlang/v/issues/32879))
  and `json2.Null` in a sum type as `{"_type":"Null"}` ([vlang/v#32880](https://github.com/vlang/v/issues/32880)),
  hence `discord.RawJson` and `discord.Nullable[T]`.
- In veyfert's builds, some generated C takes another expression's type or name: a generic
  method only the library calls, and `time.now()` in `net.http.Server`'s `DebugHandler`. A minimal
  program does not show it, so it is not reported yet. veyfert avoids both:
  `veyfert.server` has its own small HTTP/1.1 server.
- A flag enum's built-in `zero()` is not found through a module prefix
  ([vlang/v#32882](https://github.com/vlang/v/issues/32882)), so `discord.no_permissions()` exists.
- `net.websocket` has data races that `-race` reports: it masks frames with V's global `rand`
  generator, which is not thread safe; `TcpConn.read` copies the connection while another thread
  writes to it; and `Client.close()` closes the socket while `listen()` reads from it. veyfert does
  not use the global generator, and `tests/tsan.supp` suppresses only those three, also for your
  bot's tests: `TSAN_OPTIONS="suppressions=$PWD/tests/tsan.supp" v -race test .`
- `net.websocket`'s server binds every interface, so `veyfert.testing` has its own on 127.0.0.1.

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
