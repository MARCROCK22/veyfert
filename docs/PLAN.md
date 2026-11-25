# Plan: veyfert, a Seyfert-style Discord bot framework for V

> What the analysis is based on: **Seyfert 6.0.0** (commit `ac6e8e9`, 2026-11-23, full source code),
> **V 0.5.2** (`0a43261`, master) and **Discord API v10**.
>
> Legend: ✅ verified with a probe that was compiled and run · 📖 read in V's documentation or code ·
> 🧪 still to be checked with a spike.

## 0. Summary

- **A comptime-first approach.** Commands, options, guards, components, modals and events are V
  *structs* with typed attributes (`@[attribute]`). Compile-time reflection generates the JSON Discord
  asks for and copies each payload into typed fields. That replaces decorators, TypeScript's type
  inference and JavaScript's `Proxy`, and definition errors show up at compile time.
- **Modules by layer** (decided on 2026-11-24; it used to be a single module). In V each folder is a
  module, there are no re-exports, and imports cannot form cycles. The layers that do not depend on
  the client are submodules that the core imports:
  - `veyfert.discord`: types, events and components;
  - `veyfert.rest`: HTTP and rate limits, with `veyfert.rest.api` (the generated REST);
  - `veyfert.cache`.

  Optional parts (`server`, `testing`, `plugins`) import `veyfert` in one direction only. A bot writes
  `import veyfert` and `import veyfert.discord`. A facade built from type aliases does not work: an
  alias loses the `@[Event]` attributes, and `$if field.typ is Alias` does not match.
- **Threads instead of async/await.** Each shard has a reader thread, and since a guild always lands
  on the same shard, per-guild ordering comes for free. User code runs on a bounded pool. Blocking is
  allowed, so `wait_for` replaces callback-based collectors. That removes the reason `WorkerManager`
  exists.
- **Discord and V both speak snake_case.** V forbids uppercase letters in field names (✅), so the
  models mirror Discord's JSON as it is. Seyfert's camelCase layer and its `Transformers` are not
  needed.
- **REST models generated** from Discord's official OpenAPI spec. Gateway payloads are written by
  hand.
- **Eight phases**, each with an exit criterion that can be checked. Phase 0 is a vertical spike
  that validates all of this with a real bot.

## 1. Analysis of Seyfert

### 1.1 Size

It has 315 TypeScript files and 51,280 lines, 15,819 of them Discord API types. It exports 541 runtime
symbols (213 classes, 208 functions, 110 constants and 10 enums). The tests take about 80 files:
Vitest plus type contracts compiled with `tsc`.

### 1.2 Inventory by subsystem

| Subsystem | What it offers | Lines |
|---|---|---|
| `client/` | `BaseClient`, `Client` (gateway), `HttpClient`, `WorkerClient`; `start()`, `uploadCommands()` and `close()`; `setServices` (rest, cache, langs, middlewares, handleCommand); defaults for commands, components and modals; `allowedMentions`; presence per shard; shard ranges; event collectors (filter, idle, timeout); `Transformers` for custom structures | ~3,200 |
| Plugins | `createPlugin`/`definePlugins` with a `register → setup → teardown` lifecycle (teardown in reverse order), `imports`, `requires` (semver) and client and context extensions. They can contribute commands, components, modals, events, middlewares, and middleware and autocomplete wrappers. Also command and REST observers, interceptors for dispatches and for gateway sends, hooks (`commands:beforeLoad`, `plugins:ready`, `client:close`…), cache resources, langs and a typed `shared` registry. Plugins have an order and diagnostics | ~3,900 |
| `commands/` | `Command`, `SubCommand`, `ContextMenuCommand` and `EntryPointCommand`. Decorators `@Declare` (name, description, botPermissions, defaultMemberPermissions, guildId, nsfw, integrationTypes, contexts, ignore, aliases, props), `@Options`, `@Group(s)`, `@AutoLoad`, `@Middlewares` and `@Locales(T)`. Nine option types with required, choices, min/max, channel_types, autocomplete and `value(ok, fail)` transformers. Nine hooks per command besides `run`. Prefix commands with an argument parser and aliases. Contexts: `write`, `deferReply`, `editResponse`, `deleteResponse`, `editOrReply`, `followup`, `fetchResponse`, `modal`, `author`, `member`, `guild()`, `channel()`, `me()`, `t` and `metadata` | 3,650 |
| `components/` | Received components (v2 included), `ComponentCommand` (customId as a string or a RegExp, filter), `ModalCommand`, `ModalContext` (inputs, channels, roles, users, radio, checkbox, files) and component collectors with idle and timeout | 1,760 |
| `builders/` | Embed, buttons, action rows, five select menus, Modal/TextInput, Poll and attachments (URL, path, buffer or base64). Components v2: Container, Section, TextDisplay, MediaGallery, File, Separator, Thumbnail and Label. Also FileUpload, Checkbox(Group) and RadioGroup, with validation and typed errors | 2,270 |
| `api/` | REST over `fetch` with learned buckets (`x-ratelimit-bucket` + major parameter), a global 429 per token, `/interactions` exempt, three retries on 502/503, multipart, `X-Audit-Log-Reason` and observers. A typed router through `Proxy` (`client.proxy.channels(id).messages.post()`) and a CDN router | 2,290 |
| Shorters | 19 classes and ~160 methods (`client.messages.write`, `client.members.ban`…) that follow the path REST → cache → structure | 2,910 |
| `cache/` | 13 resources: users, guilds, members, voiceStates, presences, bans, roles, overwrites, channels, emojis, stickers, stageInstances and messages. Intent-aware, each resource can be turned off, with pagination and search from the cache and member counting with a queue ordered per guild. Memory, LimitedMemory (limit and expiry per resource) and Worker adapters, with a conformance suite | 3,060 |
| `structures/` | ~30 structures with methods: Guild, Member, User, Message, 20 channel classes (with mixins), 17 interaction classes, etc. Includes BitField and PermissionsBitField | 4,190 |
| `events/` | Loading from a folder, ~80 gateway events and 8 of its own (BOT_READY, GUILDS_READY, SHARD_DISCONNECT/RECONNECT, WORKER_*…). The cache is updated before listeners run. Supports `once` and reloading | 1,200 |
| `websocket/` | `Shard`: heartbeat with zombie detection, resume or identify, a policy per close code, an offline send queue, a limit of 120 sends per 60 s and `requestGuildMembers` by nonce with a retry on RATE_LIMITED. `ShardManager`: identify queue by `max_concurrency`, resharding, presence and voice. Also its own socket for Node and `WorkerManager` (threads, clusters or custom, a REST proxy and hot reload by generations with session handover) | 4,040 |
| `langs/` | Loading from a folder, locale aliases, `preferGuildLocale` and typed access `ctx.t.path.key(args).get()` through `Proxy` | 210 |
| Utilities | `Logger`, `Formatter` (markdown, mentions, timestamps, OAuth2 URLs), `SeyfertError` (~80 stable codes with metadata and `cause`), `Collection`/`LimitedCollection` and a development watcher | ~2,600 |

### 1.3 Behavioral contracts to keep

1. `start()` connects but **does not upload commands**. `uploadCommands` is explicit and compares
   against a cache so it does not upload more than needed.
2. Each packet goes in this order: plugin interceptors, `RAW` without waiting, the member and presence
   duplicate filters, the **cache update**, listeners, and then commands, components or modals. Last,
   the ready state is updated: `BOT_READY` fires when every shard is ready.
3. Middlewares: `next()` goes on, `stop()` ends silently, `stop(reason)` denies
   (`onMiddlewaresError`), and an exception goes to the internal error path. Global middlewares run
   before the command's own, and subcommands inherit their parent's.
4. A required option always has a value and an optional one may be missing. Option errors are
   collected per option.
5. The cache respects intents and disabled resources.
6. Shorters do REST, then cache, then return the structure.
7. Plugins are set up in order and torn down in reverse order, with failures wrapped with the
   plugin's name.
8. Gateway sends go through wrappers that can replace or veto the payload.

### 1.4 What exists because of JS/TS and is not ported as is

| In Seyfert | Why it exists | In veyfert |
|---|---|---|
| Workers, `WorkerManager`, a REST proxy between workers, hot reload by generations | JS has a single thread | Threads inside one process; several processes only through shard ranges |
| `locations`, `@AutoLoad`, `reload()`, watcher, `seyfert.config.*` | Loading code at runtime | Explicit registration, resolved at compile time; `v watch` while developing |
| `SeyfertRegistry`, `ParseClient`, `declare module` | Typing only exists at the type level | Concrete and generic types; dependencies go in the command's fields |
| `Proxy` (REST router, `LangRouter`) | Runtime metaprogramming | Generated functions and language structs |
| Builders with chained setters | JS ergonomics | Struct literals with `@[params]` |
| camelCase structures + `Transformers` | Discord uses snake_case and JS uses camelCase | A single snake_case model |

## 2. V features veyfert uses

| V feature | Use in veyfert | Status |
|---|---|---|
| Typed attributes (`@[attribute] struct Declare {...}`) on structs, fields, methods and functions, from another module too (`@[veyfert.Declare(...)]`) | They replace every decorator | ✅ |
| Reflection: `$for f in T.fields`, `f.attributes`, `$if a is Schema`, reading and writing `val.$(f.name)`, `$if f.typ is ?int`, `$for v in E.values`, `$for m in T.methods` and `obj.$method()` | Generating the JSON of commands and modals, copying options into fields and finding optional hooks | ✅ |
| Recursion over field types with generics | The tree command → group → subcommand is declared as types | ✅ |
| `$compile_error` inside a comptime branch | An invalid definition gives a compile error with its own message | ✅ |
| Constrained generics (`add[T Command]`) | Typed registries; V requires the constraint to propagate | ✅ |
| A generic struct that implements a non-generic interface (`Bound[T]` → `Invoker`) | Type erasure in the registries | ✅ |
| `?T`, `!T`, `or {}` and custom errors with `err is T` | Optional Discord fields, optional options that must be handled, `DiscordError` and guard control flow | ✅ |
| `@[flag]` enums with a bit position and `as u64`, `.has()` and `Enum.from('name')` | Intents, permissions (past bit 32) and message flags | ✅ |
| `json2`: `@[json: 'type']`, `@[raw]`, `decode_standard`, `decode_reuse` + `DecodeBuffer`, `@[json_as_number]`, `@[omitempty]` and the `to_json`/`from_json_*` hooks | Two-step gateway decoding (envelope and raw `d`), Snowflake as a string and `Nullable[T]` for PATCH | ✅ |
| Mandatory snake_case field names | Models 1:1 with Discord, and lowercase option names by construction | ✅ |
| `net.websocket` (wss, `!` callbacks, writes serialized per connection, `Server`) | Shards | ✅ client |
| `net.http` (`fetch`, headers, connection reuse, timeouts) | The REST transport | ✅ |
| `crypto.ed25519` | Checking the signatures of interactions received over HTTP | ✅ |
| `compress.zlib` and `compress.zstd` (streaming context, bundled in `thirdparty`) | Payload compression and `zstd-stream` | ✅ |
| `spawn`, channels, `select` with a timeout, `shared`/`lock` and `sync` (RwMutex, WaitGroup, OnceLock) | Shards, the pool, `wait_for` and the shared cache | ✅ |
| `ratelimit.TokenBucket`, `log`, `term`, `time`, `semver`, `config.load[T]` | The global REST limit and cooldowns, logs, colors, plugin requirements and configuration from env, CLI or TOML | 📖 |
| Conditional functions `@[if veyfert_trace ?]` | Traces that disappear from the binary unless built with `-d veyfert_trace` | 📖 |
| `@[params]`, `@[required]`, `@[heap]`, `@[noinit]`, embedded structs, closures with explicit captures, operator overloading | Named options, complete languages at compile time, a client shared between threads, a mandatory constructor, common fields, handlers and Snowflake ordering | 📖 |
| `@VMOD_FILE` / `@VMODHASH` | The version and commit in the `User-Agent` | ✅ version |
| `$embed_file`, `.vsh` scripts, `v test` / `-coverage` / `-race`, `v fmt` / `vet` / `doc`, VPM, cross-compilation (`-os linux`) and `-prod` | Assets inside the binary, the code generator, quality and publishing. Deploying to Linux from Windows needs Clang, LLD and the sysroot V names; otherwise, build in CI | 📖 |

**Rejected, with the reason:**

| Feature | Reason |
|---|---|
| `go` (goroutines) | Its README marks it as experimental. `spawn` is enough: a few long-lived threads plus a pool |
| `@[live]` | The docs say it has no effect with the default compiler, and recommend `v watch` |
| `x.async`, `x.scheduler`, `x.executor` as a foundation | `x.` modules are experimental; if used, behind a small internal API |
| `cache.Lru` | Its README says keeping recency is linear and it is not thread-safe |
| `eventbus` | Based on `voidptr`, untyped |
| `i18n` as the default system | Unchecked text keys and no documented interpolation. Typed language structs are closer to `ctx.t` |
| ORM/`db`, the JS and WASM backends, `-autofree`, `-gc none` | Out of scope, or a risk with no benefit |

## 3. Approaches considered

| Approach | How | For | Against |
|---|---|---|---|
| A. Literal port | Classes → structs, decorators → text attributes, `json2.Any`, runtime maps | Maps directly from Seyfert | Wastes V's types; slower; errors show up at runtime |
| **B. Comptime-first** (recommended) | Structs with typed attributes + reflection; threads; a single module (later split by layer, see §0) | Compile-time errors, typed payloads without `Any`, less code | Depends on V's reflection, which the probes already validated |
| C. Everything generated | A DSL or a spec → a `.vsh` that generates commands and models | Mechanical coverage | A poor experience for whoever writes the bot. Only worth it for the REST models, and B generates those already |

**Recommendation: B**, with code generation only for the REST models and endpoints.

## 4. Design

### 4.1 Seyfert → veyfert equivalences

| Seyfert | veyfert |
|---|---|
| `@Declare({...})` | `@[veyfert.Declare(name: 'x', description: 'y')]`, plus small attributes (`Nsfw`, `Perms`, `Guilds`…), because a schema requires all its fields |
| `@Options({ q: createStringOption(...) })` | Struct fields. The field's type sets the option type, `?T` makes it optional, and `@[Desc]`, `@[Min]`/`@[Max]`, `@[MinLength]`/`@[MaxLength]` and `@[Channels]` add the rest, always with a single value per attribute (see risk 12). An enum field generates the `choices` |
| `ctx.options.q` typed by inference | `c.q`, a plain field of type `string` or `?string` |
| `@Options([SubA, SubB])`, `@Group`, `@Groups` | Fields marked `@[Sub]` whose type is another command. A middle level becomes a group |
| `createMiddleware` + `@Middlewares(['a'])` + `ctx.metadata.a` | Guards: fields whose type implements `Guard` (`check(mut ctx) !`), with no attribute (risk 15). The state the guard leaves is the typed metadata |
| `stop()` / `stop('reason')` / an exception | `return veyfert.stop()` / `return veyfert.deny('reason')` / any other error |
| Hooks `onRunError`, `onOptionsError`… | Optional methods of the struct, found with `$for m in T.methods`, plus defaults on the client |
| `createEvent({ data: { name }, run })` | `bot.on[discord.MessageCreate](fn (e, mut c) ! {...})`. The event name comes from `@[discord.Event('MESSAGE_CREATE')]` on the payload type |
| `client.collectors.create(...)` | `c.wait_for[T](filter, timeout)`, which blocks until a matching event arrives |
| `ComponentCommand` / `ModalCommand` | `@[CustomId('x')]` or `@[CustomIdPrefix('x:')]` + `run`. A modal is a struct whose fields are the inputs: the same reflection builds and parses it |
| Builders | Flat structs that mirror Discord's wire format, plus constructors with `@[params]` |
| `client.proxy...` | One generated function per endpoint in `veyfert.rest.api`, and `rest.request(...)` as the raw path |
| Shorters | `c.messages.write(id, content: '...')!` |
| `SeyfertError` | `rest.DiscordError{ status, code, message }`, `veyfert.GuardStop` and plain V errors |
| `ctx.t.key.get()` | `langs.of(ctx.interaction).key`, with `Langs[T]` over a language struct whose fields are `@[required]` |
| `Logger` | `log.ThreadSafeLog` + `@[if veyfert_trace ?]` |
| `HttpClient` | `server.serve(mut bot, port:, public_key:)` from `veyfert.server` |

### 4.2 What a bot author writes (sketch)

The pieces are verified by probes and tests; this sketch follows the current API.

```v
module main

import os
import time
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'ping', description: 'Replies with the latency')]
struct Ping {}

fn (c Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong! ${ctx.client.latency()}')!
}

enum Order {
	relevance
	newest
}

@[veyfert.Declare(name: 'search', description: 'Searches the database')]
struct Search {
	db &Db // no attribute: a dependency, which travels with the prototype
mut:
	cd    veyfert.Cooldown = veyfert.cooldown(3, 10 * time.second) // a guard: it runs before `run`
	text  string @[veyfert.Desc: 'What to look for']                                    // required
	limit ?int   @[veyfert.Desc: 'How many results at most'; veyfert.Max: 25; veyfert.Min: 1] // optional
	order ?Order @[veyfert.Desc: 'How to sort']                                        // enum choices
}

fn (c Search) run(mut ctx veyfert.CommandContext) ! {
	hits := c.db.search(c.text, c.limit or { 10 })!
	ctx.write(
		content: '${c.cd.remaining} searches left'
		embeds:  [discord.Embed{ title: 'Results', description: hits.join('\n') }]
	)!
}

fn main() {
	db := &Db{}
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'), intents: .guilds)
	bot.commands.add(Ping{})
	bot.commands.add(Search{ db: db })
	bot.on[discord.Ready](fn (e discord.Ready, mut c veyfert.Client) ! {
		c.logger.info('Connected as ${e.user.username}')
	})
	bot.upload_commands(cache_path: '.veyfert/commands.json')!
	bot.run()!
}
```

```v
// Subcommands: the tree is declared with types
@[veyfert.Declare(name: 'config', description: 'Server settings')]
struct Config {
mut:
	language Language   @[veyfert.Sub]
	mod      Moderation @[veyfert.Sub] // Moderation has @[Sub] fields of its own, so it is a group
}

// A modal: the fields are the inputs; when it is sent, it arrives filled
@[veyfert.Modal(custom_id: 'feedback', title: 'Your feedback')]
struct Feedback {
mut:
	text  string  @[veyfert.Label: 'Tell us'; veyfert.Paragraph]
	email ?string @[veyfert.Label: 'Email (optional)']
}

fn (f Feedback) submit(mut ctx veyfert.ModalContext) ! {
	ctx.write(content: 'Thanks', ephemeral: true)!
}

// Inside a command: wait for the next message of the same user
uid := ctx.author().id
resp := ctx.client.wait_for[discord.MessageCreate](fn [uid] (m discord.MessageCreate) bool {
	return m.author.id == uid
}, 30 * time.second) or {
	ctx.followup(content: 'Time is up')!
	return
}
```

### 4.3 Commands inside

- `bot.commands.add(proto)` is generic. At compile time it walks `T.attributes` and `T.fields`,
  generates Discord's JSON and keeps a `Bound[T]{ proto }` behind an interface.
- When the interaction arrives, it copies the prototype, so dependencies travel in the copy. Those
  dependencies must be references (`&Db`) or values that are cheap to copy. Then it fills the options
  and runs the global guards, the command's guards, `run` and the hooks.
- Compile-time validation, with `$compile_error`: unsupported field types and options outside `mut:`.
  Lengths, Discord's limits and trees deeper than three levels are validated at registration,
  because V cannot yet use a schema's values in a `$if`.
- Autocomplete: an optional method `autocomplete(mut ctx veyfert.AutocompleteContext) !`. The context
  says which option has the focus.

### 4.4 Events and concurrency

```
gateway ─► reader thread (1 per shard) ──channel──► handler pool (N threads) ──► REST
           · decodes the envelope                  · on[T] listeners             (blocking,
           · decodes d only when needed            · commands, guards, modals     shared
           · updates the cache (per-guild order)   · wait_for (may block)         rate limit)
           · resolves wait_for and collectors
heartbeat thread per shard · global identify queue (max_concurrency, 5 s) · a separate pool for interactions (3 s)
```

- The reader decodes the envelope (`op`, `s`, `t` and `d` with `@[raw]`) and decodes `d` only when
  the cache or some listener needs it.
- The cache is updated on the shard's thread, so per-guild ordering is guaranteed as long as the
  shard count does not change.
- Listeners, commands and components reach the pool through a bounded channel, which applies
  backpressure. Interactions have their own pool because Discord gives 3 seconds to answer.
- `wait_for` is resolved on the shard's thread, so it takes no pool threads, not even with a single
  worker.
- `workers: 1` gives sequential semantics to whoever does not want to think about concurrency. By
  default there are several threads, and handlers that share state protect it with `shared` or
  `sync`. The tests run with `-race` on Linux and macOS, because `-race` does not exist on Windows.

### 4.5 Gateway

It is a direct port of `shard.ts`:

- heartbeat with jitter and zombie detection;
- resuming through `resume_gateway_url`;
- Seyfert's close code table (4004 and 4010–4014 do not reconnect);
- an offline send queue and a limit of 120 sends per 60 s;
- an identify queue by `max_concurrency`, one every 5 s;
- `request_guild_members` by nonce with a timeout;
- presence, voice state updates and zlib payload compression.

`net.websocket`'s logger writes INFO by default (✅), so it gets its own. `max_message_bytes`, which
defaults to 8 MiB, is exposed as an option.

### 4.6 REST

- `request(method, path, opts) !string` over a `Transport` interface: `net.http` by default, and a mock
  in tests.
- The rate limit follows Seyfert's. The key `METHOD:route` is remapped to the `x-ratelimit-bucket`
  hash plus the major parameter. There is a global limit per token (`ratelimit.TokenBucket`), a 429
  waits for its `retry_after`, 502/503 are retried three times and `/interactions` is exempt from the
  global limit.
- Our own multipart (`payload_json` + `files[n]`), because `http.post_multipart_form` only does POST
  and editing a message with attachments is a PATCH.
- `X-Audit-Log-Reason`, `User-Agent: DiscordBot (url, version)`, CDN helpers (an `a_` hash is a gif;
  sizes) and observers.

### 4.7 Models and JSON

| Problem | Solution | Status |
|---|---|---|
| 64-bit IDs that arrive as strings | `struct Snowflake { value u64 }` with public `to_json`, `from_json_string` and `from_json_number`; accepts a string or a number | ✅ |
| Telling absent from `null` in a PATCH | `?Nullable[T]`: `none` is left out and `{is_null: true}` writes `null` | ✅ |
| Unions discriminated by `type` (components, channels, interactions, options) | `json2` only discriminates with `"_type"`, and that cannot be configured. Flat models like Discord's (a `kind` field + optionals) are used, plus `RawJson.decode[T]()` where a typed view is needed | ✅ |
| Gateway | An envelope with `d @[raw]`, `decode_standard[T]` and a `DecodeBuffer` reused per shard | ✅ |
| Bitfields | `@[flag]` enums; permissions arrive as strings and are converted from `u64` | ✅ |

### 4.8 Cache, structures and shorters

- A typed, unserialized in-memory cache: one map per resource behind a `sync.RwMutex`, with the last
  messages of each channel. It is intent-aware, each resource can be turned off, and member counts
  are tracked.
- External adapters (Redis…) only when someone asks for them: an interface over serialized JSON and
  Seyfert's conformance suite ported to `v test`.
- Shorters are cache-first over the REST endpoints. The original idea was to give structures that
  arrive through events and contexts a client linked in a `@[skip]` field, filled by a comptime walk,
  for `msg.reply(...)` and `member.ban(...)`. That was dropped: see the phase 5 decision.

### 4.9 Components, modals and collectors

- A flat `Component` struct with constructors
  (`discord.button(style: .primary, label: 'Yes', custom_id: 'yes')`), complete Components v2 and
  the `IS_COMPONENTS_V2` flag (1 << 15).
- `Embed.validate()` checks the limits when sending: a title of 256, a description of 4096, 25 fields
  and 6000 characters in total.
- Modals as structs: `ctx.modal(Feedback{})!` builds the inputs from the fields, and when the modal is
  sent, `submit` receives `Feedback` filled in.
- `ctx.wait_for_component(timeout:, custom_id:)` replaces collectors.

### 4.10 i18n

`Langs[T]` is generic: it maps locale → `T`, with aliases, a fallback and `prefer_guild_locale`. `T` is
a user struct with all its fields `@[required]`, so a language that forgets a key does not compile.
The localizations of command names and descriptions come from those same structs. ✅ Constants with
function-typed fields compile.

### 4.11 Plugins, errors and logs

- `interface Plugin { name() string; setup(mut c Client) !; teardown(mut c Client) ! }`, with teardown
  in reverse order. Plugins use the client's public API plus hook lists: REST and command observers,
  and gateway interceptors.
- Requirements with `semver` and a typed `shared` registry when a plugin needs them, not before.
- Official plugins: cooldown (a guard) and scheduler.

### 4.12 Interactions over HTTP

The `veyfert.server` submodule checks `X-Signature-Ed25519` over `timestamp + body` and answers PING
with PONG. For everything else, it waits on a channel for the handler's first answer and returns it
in the HTTP response itself; if none arrives within ~2.5 s, it answers with a defer. In Seyfert this
part is unfinished, according to its own `client/AGENTS.md`.

### 4.13 Testing

- `veyfert.testing`: a fake gateway on its own WebSocket server on 127.0.0.1 (`veyfert.testing.ws`;
  see risk 18), a mock transport that records requests, and payload fixtures.
- Compile-fail tests: a `.vsh` compiles invalid cases and checks the exact `$compile_error` message.
- CI on Linux, macOS and Windows; `-race` on Linux and macOS.

## 5. Repository layout

```
veyfert/
├── v.mod  README.md  CHANGELOG.md  LICENSE
├── client.v                 # module veyfert: Client, ClientOptions, interactions, upload
├── gateway.v                # Shard: connection, heartbeat, resume, close codes, sends through interceptors
├── gateway_manager.v        # shards, identify queue, presence, voice, members, saved sessions
├── gateway_zstd_*.v         # zstd-stream with -d veyfert_zstd, or a stub without it
├── dispatch.v               # cache → collectors → pool; on/once/wait_for/emit; duplicates
├── lifecycle.v              # the framework's events (BOT_READY…) and the gateway's presence
├── commands.v  context.v  guards.v  interactions.v  inline.v  prefix.v  langs.v  plugins.v  shorters.v
├── *_test.v                 # the framework's tests, next to the code
├── discord/                 # module veyfert.discord: models, events, components, embeds,
│                            #   polls, permissions, intents, snowflakes, CDN, files
├── rest/                    # module veyfert.rest: Transport, rate limits, multipart, errors
│   └── api/                 # module veyfert.rest.api: GENERATED, one function per endpoint
├── cache/                   # module veyfert.cache: the in-memory cache
├── plugins/                 # module veyfert.plugins: official plugins (Scheduler)
├── server/                  # module veyfert.server: interactions over HTTP
├── testing/                 # module veyfert.testing: fake gateway and REST, payloads
│   └── ws/                  #   WebSocket server on 127.0.0.1
├── examples/{basic,components}/
├── tests/compile_fail/      # cases that must fail with an exact message (run_compile_fail.vsh)
├── tools/gen_api.vsh        # generator from discord-api-spec (pinned commit)
├── benchmarks/decode/
├── docs/PLAN.md
└── .github/workflows/ci.yml
```

## 6. Phases

| Phase | Goal | Exit criterion |
|---|---|---|
| 0 | Vertical spike | A real bot answers `/ping` and `/search` in a test server, and `v test .` passes on Windows and Linux |
| 1 | Production gateway | Tests against a fake gateway, offline: closes 1006, 4000 and 4004, op 7 and op 9. A real bot holds for 24 h with stable memory |
| 2 | REST and generated models | Tests with a mock transport that replay real header sequences: shared bucket, global 429 and 502 |
| 3 | Commands | Dispatch tests with sample interactions, compile-fail tests and a parity checklist against Seyfert's command guide |
| 4 | Components, modals and messages | The generated JSON matches the examples in Discord's docs; a manual test with the bot |
| 5 | Cache, structures and shorters | Consistency tests with event sequences and a clean `-race` on Linux |
| 6 | Prefix, i18n, plugins and HTTP | An HTTP test with requests signed by a key generated in the test itself |
| 7 | Production and publishing | Public `veyfert.testing`, docs, examples and benchmarks; CI on the three systems and published on VPM |
| 8 | Seyfert parity | Every item of the phase 8 checklist is done, tested and green in CI |

Phases 3 to 6 can overlap once 0, 1 and 2 are done, since those build the gateway and REST.

**Phase 0 — Vertical spike.** Proves the whole path before investing in breadth.
- **Status (2026-11-23): done on Windows.** The `examples/basic` bot uploaded `/ping` and `/search` to
  a test server, identified on the gateway, kept the heartbeat and answered both commands from
  Discord. `v test .` passes, on Linux and macOS too in CI since phase 7. The test uncovered two
  things: `log`'s logger does not flush its buffer per line unless asked (`set_always_flush(true)`),
  and risk 12.
- `v.mod`, `.gitignore` (with `.env` and `.veyfert/`) and minimal CI.
- `Snowflake`, `Nullable[T]`, `Intents` and `Permissions`; the session's probes become `_test.v`.
- One shard: HELLO → IDENTIFY → heartbeat → READY, with the envelope and `d @[raw]`.
- Minimal REST: the interaction callback, `create_message`, `User-Agent` and `DiscordError`.
- Registration through attributes (`Declare`, `Desc`, `Min`, `Max`) and `upload_commands` to a test
  server.
- Requirements: a test Discord application, its token in `DISCORD_TOKEN` (never in the repo) and a
  test server.

**Phase 1 — Production gateway.**
- **Status (2026-11-24): done on Windows, except the 24 h run.** There are 12 scenarios against a fake
  gateway, offline: 1006, 4000, 4004, 4009, op 7, resumable and non-resumable op 9, zombie, offline
  queue, member chunks, guild loading and zlib payloads. There are also 6 dispatch tests. All pass,
  stable over two runs.
- Against real Discord: the bot started with a presence and `BOT_READY`, `request_members` by ID
  returned the member and `reconnect(0)` resumed the session. `stop()` closes cleanly. From Discord,
  `/me` and `/reconnect` answered, the session resumed in 0.4 s and `/ping` kept answering after.
  It stayed online for 30 minutes with no unprovoked disconnections.
- Benchmark (`benchmarks/decode`, `-prod`): a READY of 2500 guilds in 1.7 ms; a GUILD_CREATE of 1000
  members (281 KiB) in 3.6 ms; a MESSAGE_CREATE in 4 µs. That is about 70 MiB/s with `json2`.
- The member and presence duplicate filters were done in phase 5, and `max_message_bytes` is a client
  option since phase 7. On Linux and macOS, the tests and `-race` pass in CI since phase 7.
- Resume and reconnection with `shard.ts`'s close code table, zombie detection, a connection timeout
  and an offline send queue.
- Several shards in one process, with an identify queue by `max_concurrency`, shard ranges (`start`,
  `end`, `total`), presence per shard and the limit of 120 sends per 60 s.
- `request_guild_members` (nonce, chunks, timeout), voice state updates and zlib payload compression.
- Dispatch: `on[T]`, `once[T]`, `RAW`, `emit[T]` for custom events, `GUILDS_READY`, `BOT_READY` and
  `SHARD_DISCONNECT`/`SHARD_RECONNECT`. Lazy decoding and the member and presence duplicate filters.
- A decoding benchmark: READY, a large GUILD_CREATE and MESSAGE_CREATE.

**Phase 2 — REST and generated models.**
- **Status (2026-11-24): done on Windows.** `rest.v` has a swappable `Transport`, learned buckets (a
  shared bucket gets the headers of all its routes), a global limit of 50/s that blocks after a
  global 429 (interactions are exempt), 502/503 retries, our own multipart, `X-Audit-Log-Reason`,
  observers and CDN helpers. There are 10 tests with a mock transport.
- `tools/gen_api.vsh` reads the pinned spec (`3a21a01`) and generates 447 structs, 68 integer enums and
  247 of 250 endpoints. It leaves out the 3 that only take a multipart body and 18 query parameters
  that are arrays. Against real Discord it decoded the user, the application, a guild and messages.
- Decisions: enum fields are `int`/`string`, because Discord adds values and `json2` rejects unknown
  ones; the enums are generated apart for comparisons. What the spec models as a union (channels,
  components) arrives as `RawJson`, which `RawJson.decode[T]()` turns into a model.
- Done in phase 7: in PATCH bodies, the 84 fields that accept `null` are generated as `?Nullable[T]`
  (`none` leaves the value as it is, `{is_null: true}` clears it). String enums are still not
  generated.
- `tools/gen_api.vsh` over discord-api-spec at a pinned commit: models and one function per endpoint,
  with hand-written overrides where the spec falls short.
- A complete rate limiter (see 4.6), our own multipart, `X-Audit-Log-Reason`, `request`, CDN helpers
  and observers.

**Phase 3 — Commands.**
- **Status (2026-11-24): done on Windows.** `commands.v` registers type trees (`@[Sub]`, with groups
  one level below the command), user and message menus, and options of 13 field types with
  `Min`/`Max`, `MinLength`/`MaxLength`, `Channels`, `Autocomplete` and `Label` on enum values. Guards
  are fields whose type implements `Guard` (no `@[Use]`, see risk 15). They run in this order: the
  bot's permissions, options, global guards, the groups' guards and the command's own. There are
  `stop`/`deny`, `Cooldown` and `RequirePermissions`, hook methods (`on_run_error`,
  `on_options_error`, `on_guard_error`, `on_bot_permissions_fail`) and `CommandDefaults` on the
  client. Also `Perms`, `BotPerms`, `Nsfw`, `Guilds`, `Contexts` and `Integrations`, and uploads per
  scope (global and per server).
- 15 dispatch tests with sample interactions and 3 compile-fail tests
  (`v run tests/run_compile_fail.vsh`). Against real Discord, the server accepted the example's 8
  commands: the `/config` tree, both menus, autocomplete, channel types and lengths.
- Compile time: a bot with 100 commands (each with a cooldown, an enum, a `User` and two more options)
  compiles in 12.2 s, against 5.7 s with one; that is about 65 ms per command, and the binary goes
  from 3.4 to 4.1 MB.
- Left for other phases: `modal` on the contexts (phase 4), `guild()`/`channel()` from the cache
  (phase 5) and entry point commands.
- The field's type sets the option type: `string`, `int`, `f64`, `bool`, `User`, `Member`, `Role`,
  `Channel`, `Mentionable` or `Attachment`. `?T` makes it optional and an enum generates the choices,
  with names localizable through attributes on the values. Also `Min`/`Max`, `MinLength`/`MaxLength`
  and channel types.
- Autocomplete, subcommands and groups as a type tree, and user and message context menus. Entry
  point commands are left for the end.
- Contexts with `write`, `defer_reply`, `edit_response`, `delete_response`, `followup`,
  `fetch_response`, `edit_or_reply`, `modal` and ephemeral answers, plus `author`, `member`, `guild`
  and `channel`.
- Per-field and global guards, optional hooks and client defaults. Permissions
  (`default_member_permissions`, and the bot's permissions with `on_bot_permissions_fail`),
  `integration_types`, `contexts`, `nsfw`, per-guild commands and uploads with a hash cache.
- The validations of 4.3. Measure the compile time with 100 synthetic commands.

**Phase 4 — Components, modals and messages.**
- **Status (2026-11-24): done on Windows, except the manual test of modals.** `components.v` has a
  flat `Component` with constructors for the 20 types: v1, Components v2 and modal ones (`label`,
  `file_upload`, `radio_group`, `checkbox_group`, `checkbox`). The single child of `section` and
  `label` is stored already encoded, because V structs cannot contain themselves.
  `IS_COMPONENTS_V2` is set by itself when there are v2 components. There are also a complete
  `Embed` with `validate()`, checked when sending, polls, `allowed_mentions`, `tts`, flags and
  attachments (`file_from_path`, `file_from_url`).
- `interactions.v` routes handlers by an exact `CustomId` or the longest `CustomIdPrefix`.
  `ComponentContext` has `update` and `defer_update`. Modals are structs (`@[Modal]`, with `@[Label]`
  fields of type string, ?string or an enum, which becomes a select): `ctx.modal(form)` builds them
  prefilled with the values, and a submission arrives as the filled struct, both in the format with
  labels and in the older one with action rows. `wait_for_component` and `wait_for_modal` take the
  interaction, which then skips the handlers.
- 9 tests and one for attachments. Against real Discord, three messages were posted and deleted: a v1
  one with a full embed, buttons and selects; a v2 one with a container, a section with a thumbnail,
  a separator, a gallery and a file attached through multipart; and a poll. Modals need someone to
  open them in Discord: `examples/components` has them.
- Brought forward from phase 5: `c.messages` with `write`, `edit`, `delete` and `fetch`.
- A flat `Component` with constructors, complete Components v2 and `IS_COMPONENTS_V2`.
  `Embed.validate()`, polls, attachments (bytes, path or URL) and `allowed_mentions`.
- Handlers by exact or prefix `custom_id`, modals as structs, `wait_for_component`,
  `wait_for_modal`, `update` and `defer_update`.

**Phase 5 — Cache, structures and shorters.**
- **Status (2026-11-24): done; `-race` is clean in CI on Linux and macOS since phase 7.** `cache.v` keeps
  guilds, channels and threads (with their overwrites), roles, users, members, emojis, stickers,
  presences, voice states, stage instances, bans and the last N messages per channel. There is one
  map per resource, each of which can be turned off, behind an `RwMutex`, and it is updated on the
  shard's thread before listeners run. `events.v` types 30 more events. `GUILD_MEMBER_UPDATE` and
  `PRESENCE_UPDATE` repeated within 1.5 s only reach RAW listeners, as in Seyfert.
- `shorters.v`: messages, reactions, channels, members, roles, guilds, users, threads, webhooks, bans
  and emojis (about 50 methods). `fetch`/`list` read the cache first (`force: true` goes to Discord)
  and the audit log reason goes in the options struct. `RawJson.decode[T]()` turns what a generated
  endpoint returns into a model.
- Decision: no client inside the structures, nor in a `@[skip]` field filled by reflection, because it
  would leave nil pointers in structs created by hand. At first, the structures took the client as an
  argument (`msg.reply(mut c, ...)`). Since the split by layer (phase 7), the types live in
  `veyfert.discord`, and V does not allow methods outside a type's module, so those actions are on the
  shorters (`c.messages.reply(msg, ...)`, `c.members.ban(...)`).
- 9 tests (cache consistency with event sequences, duplicates and shorters with a mock transport).
  Against real Discord, the cache filled with `GUILD_CREATE`; sending, replying with a quote,
  reacting, pinning, unpinning, editing, listing reactions and bulk deleting also worked, and the
  message events updated the cache.
- The in-memory cache of the 13 resources (see 4.8).
- Shorters by priority: messages, interactions, channels, members, roles, guilds, threads, reactions,
  webhooks, bans, emojis and users. Then the rest, up to Seyfert's ~160 methods.
- Methods on structures with the client linked.

**Phase 6 — Prefix, i18n, plugins and interactions over HTTP.**
- **Status (2026-11-24): done on Windows.**
  - **Prefix (`prefix.v`):** the same command types run from messages, with
    `ClientOptions.prefixes`, a dynamic `Commands.prefix` or a mention of the bot. There are also
    aliases (`@[Aliases]`) and `@[Ignore('slash'|'prefix')]`. Options come in order or as
    `-name value`, and the last text option takes the rest of the line. Choices are accepted by value
    or label, mentions and IDs are resolved as in an interaction (cache first) and attachments go in
    order. Answers are channel messages: `write` replies with a quote, `defer_reply` shows "typing"
    and `edit_response` edits. Guards see permissions worked out from the cache
    (`Cache.permissions`: roles, owner and overwrites, threads included).
  - **i18n:** `Langs[T]` with aliases, the base language, a fallback and `prefer_guild_locale`.
    `Commands.localize` takes names, descriptions and choices from `CommandText` fields (`@[Locale]`).
    Constants with function fields compile.
  - **Plugins:** `Plugin` with `install` and teardown in reverse order when `run` ends,
    `Commands.observe` (a `CommandEvent` with the outcome) and `Client.intercept` to change or drop
    events. `Scheduler` is the official plugin; the cooldown was already a guard.
  - **`veyfert.server`:** checks the Ed25519 signature, answers PING and returns the handler's first
    answer in the HTTP response. At 2.5 s it sends a defer (6 for components) and the late answer
    edits the defer. It is its own HTTP/1.1 server (risk 17).
- 16 new tests, among them the HTTP one with requests signed by a key generated in the test. Not
  tested against Discord: the prefix needs someone to type (`examples/basic` turns it on), and the
  HTTP endpoint needs an HTTPS URL registered in the developer portal.
- Prefix commands with the same definitions: aliases, an argument parser, errors per option and the
  option to ignore the slash or the message mode.
- `Langs[T]` and command localizations.
- Plugins (see 4.11), with cooldown and scheduler as official ones.
- `veyfert.server` (see 4.12).

**Phase 7 — Production and publishing.**
- **Status (2026-11-24): done, except what does not depend on this work.**
  - `veyfert.testing` is public: a fake gateway on 127.0.0.1, a `Transport` that records requests and
    answers in turn, `client(gw, api)` and payloads (`command_interaction`, `component_interaction`,
    `modal_submit`, `message_create`).
  - Documentation: `README.md` is the guide, with the structure of Seyfert's, and its snippets are
    compiled. `v doc` generates the reference, and there are the two examples.
  - There are `CHANGELOG.md`, `LICENSE` and CI in `.github/workflows/ci.yml` (Linux, macOS and
    Windows): formatting, tests, zstd, compile-fail and examples with `-W`, plus `-race` on Linux and
    macOS (with `tests/tsan.supp`; see risk 21). The deprecation policy is in the README.
  - Optional items done: saving the session when stopping and resuming it on start (`save_sessions`,
    `load_sessions`; the cache starts empty and `BOT_READY` still fires) and `zstd-stream`
    (`zstd: true`, built with `-d veyfert_zstd`, so it costs nothing to bots that do not use it).
  - The split by layer: the `veyfert` core on top of `veyfert.discord`, `veyfert.rest` (with
    `veyfert.rest.api`) and `veyfert.cache`, plus `veyfert.plugins`; see §0 and §5. A script did it,
    qualifying the moved names without touching strings or comments.
  - The two contracts of §1.3 that were missing now hold:
    - (6) each shorter keeps what REST returns in the cache, and forgets what it deletes; a sent
      message is not duplicated when its `MESSAGE_CREATE` arrives.
    - (8) `intercept_send` changes or drops any payload a shard sends.
  - The repository is public on GitHub, and CI passes on Linux, macOS and Windows, `-race` included
    (risk 21 says what it suppresses).
  - Published on VPM as `MARCROCK22.veyfert`, imported as `marcrock22.veyfert`. Not done: the 24 h run,
    benchmarks against Seyfert and automatic resharding. The last one was left out: restarting the
    shards with a new total on the fly requires restructuring `run`, and the manual range
    (`ShardRange`) covers today's large bots.
- Public `veyfert.testing`.
- Optional: `zstd-stream`, automatic resharding, and saving the session when stopping to resume it on
  start, warning that the cache starts empty.
- Documentation (`v doc` and a guide with the same structure as Seyfert's), examples and benchmarks
  against Seyfert (RAM per guild and events per second).
- CI on Linux, macOS and Windows, publishing on VPM and a deprecation policy with `@[deprecated]` and
  `@[deprecated_after]`.

**Phase 8 — Seyfert parity.**
- Asked on 2026-11-24: write all the code that veyfert still lacks compared with Seyfert. The
  inventory compares Seyfert 6.0.0's runtime exports (541) and its 19 shorters (202 methods,
  counting overloads and `raw` twins) with veyfert. Here `fetch` and `raw` are one method, since
  there are no structure classes, and an operation that another shorter already has is not
  repeated: Seyfert's `channels.pins` is `c.messages.pins`.
- Not ported, by design (§1.4): workers and the worker cache adapter, `Transformers` and structure
  classes, loading from files, reload and `seyfert.config`, the proxy router, `Collection`, terminal
  colors and the mixer.
- Checklist; each item is ticked when it is done and tested:
  - Shorters, 127 new methods, done: `shorters_guild.v` and `shorters_app.v`, tested in
    `shorters_parity_test.v`. Seyfert's `messages.purge` is `c.messages.delete_bulk`, and its
    `guilds.channels.edit_positions` and `add_follower` are on `c.channels`:
    - [x] `c.application` (new, 14): emojis (list, fetch, create, edit, delete), entitlements
      (list, fetch, consume, create_test, delete_test), skus, fetch, edit, activity_instance.
    - [x] `c.monetization` (new, 4): list_skus, fetch_sku, subscriptions, fetch_subscription.
    - [x] `c.interactions` (new, 8): reply, fetch_response, fetch_original, edit_message,
      edit_original, delete_response, delete_original, followup.
    - [x] `c.invites` (new, 12): fetch, delete, create, list_channel, list_guild, and the target
      users of an invite (fetch, update, job_status, add, remove, bulk_add, bulk_remove).
    - [x] `c.soundboard` (new, 7): defaults, send, list, fetch, create, edit, delete.
    - [x] `c.stages` (new, 4): fetch, create, edit, delete.
    - [x] `c.templates` (new, 6): fetch, list, create, sync, edit, delete.
    - [x] `c.voice_states` (new, 2): request_speak, set_suppress.
    - [x] `c.guilds` (30): edit, fetch_self, widget_url, incidents, search_messages;
      `audit.fetch`; `onboarding` fetch and edit; `welcome` fetch and edit; `widget` settings,
      edit, fetch and image; `moderation` (auto
      moderation rules) list, create, fetch, edit and delete; `events` (scheduled events) list,
      create, fetch, edit, delete and subscribers; `stickers` list, create, fetch, edit and delete.
    - [x] `c.channels` (8): edit_positions, add_follower, member_permissions, role_permissions,
      overwrites_for, fetch_member_permissions, fetch_role_permissions, set_voice_status.
    - [x] `c.members` (9): resolve, add, roles, sort_roles, permissions, fetch_permissions,
      presence, voice, has_timeout.
    - [x] `c.messages` (2): end_poll, answer_voters.
    - [x] `c.roles` (3): member_counts, fetch_permissions, edit_positions.
    - [x] `c.threads` (6): lock, edit, fetch_member, list_members, list_archived,
      list_joined_archived_private.
    - [x] `c.bans` (3): create, remove, bulk_create.
    - [x] `c.emojis` (2): fetch, edit.
    - [x] `c.users` (1): delete_dm.
    - [x] `c.webhooks` (6): edit, fetch, fetch_message, edit_message, delete_message, list_guild.
  - Events:
    - [x] Typed payloads for the 42 gateway events that only reached RAW listeners, done in
      `discord/events_more.v` (and `RawGuildDelete` in `lifecycle.v`; RAW itself is `c.on_raw`):
      APPLICATION_COMMAND_PERMISSIONS_UPDATE; AUTO_MODERATION_RULE_CREATE, _UPDATE, _DELETE and
      AUTO_MODERATION_ACTION_EXECUTION; CHANNEL_PINS_UPDATE and CHANNEL_INFO; ENTITLEMENT_CREATE,
      _UPDATE and _DELETE; GUILD_AUDIT_LOG_ENTRY_CREATE; GUILD_INTEGRATIONS_UPDATE;
      GUILD_SCHEDULED_EVENT_CREATE, _UPDATE, _DELETE, _USER_ADD and _USER_REMOVE;
      GUILD_SOUNDBOARD_SOUND_CREATE, _UPDATE, _DELETE, GUILD_SOUNDBOARD_SOUNDS_UPDATE and
      SOUNDBOARD_SOUNDS; INTEGRATION_CREATE, _UPDATE and _DELETE; INVITE_CREATE and _DELETE;
      MESSAGE_REACTION_REMOVE_ALL and _REMOVE_EMOJI; MESSAGE_POLL_VOTE_ADD and _REMOVE;
      RAW_GUILD_DELETE; SUBSCRIPTION_CREATE, _UPDATE and _DELETE; THREAD_MEMBER_UPDATE and
      THREAD_MEMBERS_UPDATE; VOICE_SERVER_UPDATE, VOICE_CHANNEL_EFFECT_SEND,
      VOICE_CHANNEL_STATUS_UPDATE and VOICE_CHANNEL_START_TIME_UPDATE; WEBHOOKS_UPDATE. As Seyfert's,
      the cache now also follows INTERACTION_CREATE (the user and the members it mentions),
      MESSAGE_REACTION_ADD and TYPING_START (the member), VOICE_CHANNEL_STATUS_UPDATE and
      RAW_GUILD_DELETE. Tested in `events_parity_test.v`.
    - [x] The gateway request for soundboard sounds (op 31): `c.request_soundboard_sounds(guild_ids)`,
      answered by SOUNDBOARD_SOUNDS events; tested against the fake gateway.
  - Commands (done, tested in `commands_parity_test.v`):
    - [x] Entry point commands (Activities): `@[EntryPoint(name:, description:)]`, which Discord
      launches by itself, or with `@[AppHandler]` a `run` that answers, for example with
      `ctx.launch_activity()` (callback 12). An app has one.
    - [x] The hooks still missing: on_before_options, on_before_guards, on_after_run (with the
      error of `run`), on_permissions_fail and on_internal_error (the errors hooks return), with
      defaults on the client for the last two. on_permissions_fail only applies to prefix
      commands: Discord checks @[Perms] for interactions after each guild's own command
      permissions, which a second check would overrule. Component and modal handlers gained
      guards (`HandlerGuard` fields, and `use` for every handler) and on_before_guards,
      on_guard_error, on_after_run and on_internal_error.
    - [x] Option values that a method transforms or rejects, as Seyfert's `value(ok, fail)`: a
      `check_options(mut ctx) !` method runs after the options are filled; its error goes to
      on_options_error, and it may set other fields. V has no callback per field.
    - [x] A replaceable argument parser for prefix commands: `c.commands.args_parser`.
  - Components and modals (done, tested in `components_parity_test.v`):
    - [x] custom_id matched by a regular expression, `@[CustomIdRegex]`, for components and modal
      submissions (exact IDs win, then prefixes, then expressions), a `filter` method on
      handlers that passes the interaction to the next match, and `ctx.modal(form, custom_id:)`
      to open a modal with an ID that carries data.
    - [x] Collectors for several components or events, with `timeout`, `idle`, `max` and the
      reason they stopped: `c.collect[T](filter, each)` and `ctx.collect_components(each)`. They
      block, like `wait_for`; `each` returns `stop()` to end them, and collected clicks skip
      the handlers.
    - [x] Attachments from base64: `discord.file_from_base64`, plain or as a data URI.
  - Utilities:
    - [ ] A formatter: markdown, mentions (users, channels, roles, slash commands), timestamps and
      their styles, headings, links, code blocks, lists and OAuth2 URLs.
    - [ ] CDN URLs for every image Discord serves, with the allowed formats and sizes.
    - [ ] Helpers on the models: mentions, URLs, display names, creation time, embed colors, color
      parsing and emoji encoding.
  - Cache:
    - [ ] An adapter interface, the in-memory adapter, a limited one (a limit and an expiry per
      resource) and a conformance suite for adapters.
  - Plugins:
    - [ ] Requirements (semver) and imports between plugins, ordering, a typed shared registry
      with disposal, lifecycle hooks (before commands load, plugins ready, client close),
      contributions that teardown removes, plugin intents, guard and autocomplete wrappers, and
      errors that name the plugin, with an aggregate error.
  - REST generator:
    - [ ] The 3 endpoints that only take multipart, the 18 array query parameters and string enums.
  - Gateway:
    - [ ] Automatic resharding.
  - Benchmarks:
    - [ ] RAM per guild and events per second, against Seyfert.
  - Documentation:
    - [ ] The README and CHANGELOG cover everything above.

## 7. Risks and V gaps found

| # | Finding | Evidence | Mitigation in veyfert | Possible PR to V |
|---|---|---|---|---|
| 1 | `json2` only discriminates sum types with `"_type"`, with no option to change it | When encoding it adds `"_type":"Button"`. When decoding Discord's JSON: `could not resolve sumtype ... missing "_type" field?` | Flat models. If a variant has its own `to_json`, `json2` uses it and writes no `_type`. For decoding, `from_json(Any)` + `decode_any[T]` | An attribute to choose the discriminator's key and value |
| 2 | A `?SumType` field (`Null \| string`) did not compile | `unknown function val.to_json` | `?Nullable[T]` | It compiles today, but `json2.Null` inside a sum type comes out as `{"_type":"Null"}` instead of `null`: [vlang/v#32880](https://github.com/vlang/v/issues/32880) |
| 3 | An attribute schema requires all its fields, accepts no default values and cannot repeat on one declaration | `attribute X is missing field`, `cannot have a default value`, `duplicate attribute` | Small schemas and comma-separated lists (`@[Guilds('a,b')]`) | Optional fields with a default value |
| 4 | A schema's values cannot be used in a `$if` | The attribute docs say it "requires further work" | Validate lengths and names at registration, not at compile time | Expose those values to comptime |
| 5 | `-race` does not exist on Windows | V's docs | CI on Linux and macOS, or WSL locally | — |
| 6 | `net.websocket`'s logger writes INFO, and each message has an 8 MiB cap | The probe's output; the module's README | Our own logger and the cap as an option | — |
| 7 | `post_multipart_form` only does POST | `net.http`'s code | Our own multipart over `fetch` | Take the method as a parameter |
| 8 | Discord's OpenAPI spec is in "public preview" and does not cover the gateway | discord-api-spec's README | A pinned commit, overrides and a hand-written gateway | — |
| 9 | `x.` modules are experimental | vlib's convention | A thin internal API on top | — |
| 10 | Compile time grows with each command, because each type instantiates the generics | The generated REST added 1.3 s to each build (5.5 s against 4.2 s for the example) even when the bot did not use its endpoints; the binary barely changed | Measured in phase 3: 100 commands compile in 12.2 s against 5.7 s with one (about 65 ms per command). In phase 7 the generated REST moved to `veyfert.rest.api`: `examples/basic` compiles in 8.7-9.2 s against 10.4-11.5 s with it inside the core | — |
| 11 | `json2`'s performance on large gateway payloads | Not measured at first | A benchmark in phase 1 (about 70 MiB/s); if it falls short, use `json2`'s token scanner on hot events | — |
| 12 | `v fmt -w` flattens field attributes with several arguments: `@[Range(min: 1, max: 10)]` becomes `@[Range; Range_min: 1; Range_max: 10]`. It compiles with warnings, but fails with `-prod` or `-W` | `unknown attribute Range_min ... Unvalidated attributes are deprecated` in phase 0 | On fields, only single-value schemas (`Min`, `Max`, `Desc`, `Label`); `v fmt` keeps them in the equivalent form `@[Min: 1]`. Struct attributes with several arguments are left alone | [vlang/v#32875](https://github.com/vlang/v/issues/32875) |
| 13 | `net.websocket` calls `on_close` twice when the server closes (with its code, then with 1000), and reports a broken connection as 1000 after a read error | `websocket_client.v`'s code (`manage_clean_close` and the `defer` in `listen`); in phase 1 every server close ended in "new session" | The shard keeps the first report of each connection and treats a close preceded by `on_error` as 1006 | [vlang/v#32878](https://github.com/vlang/v/issues/32878) |
| 14 | A `select` inside a library did not link with `-skip-unused`, the default: the C called `sync__channel_select_lang` without declaring it | The phase 1 example only compiled with `-no-skip-unused`; the tests did compile, because their own code uses `select` | `recv_until` polls with `try_pop` every 10 ms; go back to `select` once V fixes it | Not reproduced in isolation on V 0.5.2 `0a43261` (a `select` in a module, generic or not, compiles); no issue until there is a minimal case |
| 15 | A generic call inside `$if a is Schema` (or `$if a.name == '...'`) is instantiated for the type of every field of the struct, not only those with the attribute. `$compile_error` does respect the branch | A phase 3 probe: `guard_fn(proto.$(field.name))` under `$if a is Use` asked for `int.check` and `string.check` | Filter by type, which does limit the instances: guards are found with `$if field.typ is Guard`, and the `@[Sub]` recursion sits inside `$if field.typ is $struct` | [vlang/v#32876](https://github.com/vlang/v/issues/32876); also, `v -check` does not see a `$compile_error` in those branches: [vlang/v#32877](https://github.com/vlang/v/issues/32877) |
| 16 | With `-skip-unused` (the default), an instance of a generic method that only the library itself calls is not generated: the C calls `veyfert__Client_Interaction__wait_for` without defining it. From the bot's code the same call works, and the tests do not catch it | The `examples/components` build in phase 4; `@[markused]` does not fix it, and `-no-skip-unused` runs into another vlib bug (`http.DebugHandler`) | The library does not call its own event generics: `wait_interaction` is a concrete wait. Each example is built with `-W` as a smoke test | Not reproduced in isolation (a case with the same structure compiles). It resembles [vlang/v#27205](https://github.com/vlang/v/issues/27205), closed. In the C, the expression takes another node's name or type, as in risk 17; no issue until there is a minimal case |
| 17 | `net.http.Server` does not compile together with veyfert: in the C of `http.DebugHandler`, `time.now()` comes out as an `i64` (`cannot convert struct time__Time to long long`). A minimal program with `http.Server` does compile, and vlib's `time.now()` sits at the same byte offset as a `$if field.typ is ?i64` in `commands.v`, which points to a type cached by position | The `veyfert.server` test (phase 6) and `-no-skip-unused` (phase 4); the generated C of both builds | A minimal HTTP/1.1 server over `net` (one thread per request, no keep-alive), enough for Discord's POSTs | No issue: it could not be isolated. Aligning the positions by hand in two files did not reproduce it |
| 18 | `net.websocket`'s server always listens on every interface (`:port`), with no address option. On Windows, each new test executable that opens such a port triggers the firewall prompt, which the user kept seeing | `websocket_server.v`, `listen()` | `veyfert.testing.ws`: a minimal WebSocket server on 127.0.0.1 for the fake gateways, and `veyfert.server` with a `host` option | Accept the address in `new_server` |
| 19 | `json2` decodes a `@[raw]` field as the JSON text, but writes it back as a quoted string: decoding and encoding again changes the document | A phase 2 probe | `RawJson`, with its own `from_json(Any)` and `to_json()` | [vlang/v#32879](https://github.com/vlang/v/issues/32879) |
| 20 | The `zero()` that V generates for a `@[flag]` enum is not found through a module prefix: `discord.Permissions.zero()` gives `unknown function: Permissions.zero`. User-defined static methods (`discord.Permissions.parse`) do work | The split by layer (phase 7) | `discord.no_permissions()` | [vlang/v#32882](https://github.com/vlang/v/issues/32882) |
| 21 | `net.websocket` has data races that `-race` reports: it masks every frame with `rand.bytes()`, the global generator, which `rand`'s README says is not thread safe; `net.TcpConn.read` and `read_ptr` take the connection by value, so each read copies the struct while a write on another thread updates it; and `Client.close()` closes the socket while `listen()` may be in `recv()` on it | The first `-race` run in CI (phase 7) | veyfert uses `crypto.rand`, never the global generator. Its test WebSocket server reads through its own copy of the connection and shuts the socket down instead of closing it from another thread. CI suppresses only those three races inside `net.websocket` (`tests/tsan.supp`) | [vlang/v#32886](https://github.com/vlang/v/issues/32886), [vlang/v#32888](https://github.com/vlang/v/issues/32888), [vlang/v#32887](https://github.com/vlang/v/issues/32887) |
| 22 | Over `wss://`, `net.websocket` reads the TLS connection in `listen()` while other threads write to it; [vlang/v#31772](https://github.com/vlang/v/issues/31772) explains that neither Mbed TLS nor OpenSSL supports concurrent calls on one connection | vlib's code and that issue (phase 7); `-race` does not see it, because the tests use `ws://` | None yet: the shard reads on its own thread and writes heartbeats and payloads from others. Doing it safely needs non-blocking TLS with a lock, which belongs in `net.ssl` | [vlang/v#31772](https://github.com/vlang/v/issues/31772) (open) |

## 8. Decisions taken by default

- The name `veyfert`, like the folder, with the MIT license like Seyfert.
- Everything in the repository is in English: the API, its identifiers, its documentation and this
  plan.
- Several threads by default, with `workers: 1` as an option.
- No `WorkerManager`: to use several processes, shard ranges.
- No external cache adapters and no full plugin system until a real case asks for them.
- Voice: only the gateway side (joining and leaving); audio is out of scope.
- No deadlines: each phase ends when it passes its exit criterion.

## 9. Context: other Discord libraries in V

| Repository | Status (GitHub API, 2026-11-23) |
|---|---|
| [DarpHome/discord.v](https://github.com/DarpHome/discord.v) | Active: last push on 2026-06-15, 42★. "Discord API implementation library" |
| [Terisback/discord.v](https://github.com/Terisback/discord.v) | Archived, 115★. The only one that presents itself as a framework |
| [CesiumLabs/vcord](https://github.com/CesiumLabs/vcord) | Archived, WIP |
| [vlang/viscord](https://github.com/vlang/viscord) | No changes since 2020 |

Their code was not reviewed. Reading DarpHome/discord.v would help to compare how it handles the
gateway and REST.

## 10. Sources

- Seyfert: <https://github.com/tiramisulabs/seyfert> (commit `ac6e8e9`, its per-subsystem `AGENTS.md`
  files included).
- Discord's OpenAPI spec: <https://github.com/discord/discord-api-spec> (`specs/openapi.json`, last
  push on 2026-11-06).
- V's documentation, in its repository: `doc/docs.md`, `doc/custom_attributes.md`,
  `doc/custom_attribute_arguments.md`, `vlib/json2/README.md`, `vlib/net/websocket/README.md`, and the
  READMEs of `goroutines`, `cache`, `ratelimit`, `i18n`, `x/async`, `x/executor` and `compress/*`.
- The search for existing libraries: <https://vpm.vlang.io/packages/Terisback.discordv>,
  <https://awesome.ecosyste.ms/projects/github.com%2Fvlang%2Fviscord>,
  <https://www.github.com/CesiumLabs/vcord>.
