# Changelog

Breaking changes say what to change. See the deprecation policy in the README.

## 0.1.0 (unreleased)

Layout: the framework is `veyfert`, on top of `veyfert.discord` (types, events, components),
`veyfert.rest` (HTTP, rate limits) with `veyfert.rest.api` (generated endpoints) and
`veyfert.cache`; official plugins are in `veyfert.plugins`, and `veyfert.formatter` writes
Discord's markdown. Bots import `veyfert` and `veyfert.discord`. Message and member actions are on
the shorters: `c.messages.reply(msg, ...)` and `c.members.ban(guild_id, user_id, ...)`.

First version: the gateway with sharding, resuming and zlib or zstd-stream compression; REST
with rate limits and generated endpoints; commands, subcommands, context menus, autocomplete,
guards and hooks; components v1 and v2 and modals; the cache and shorters; prefix commands;
languages; plugins; interactions over HTTP (`veyfert.server`); and `veyfert.testing`.

### Seyfert parity

What Seyfert has and the first version lacked (docs/PLAN.md, phase 8):

- **Shorters:** 128 more methods, and `c.application`, `c.monetization`, `c.interactions`,
  `c.invites`, `c.soundboard`, `c.stages`, `c.templates` and `c.voice_states`, with
  `c.guilds.audit`, `onboarding`, `welcome`, `widget`, `moderation`, `events` and `stickers`.
- **Events:** typed payloads for the 42 gateway events that only raw listeners saw, and
  `c.request_soundboard_sounds` (opcode 31).
- **Commands:** entry point commands (`@[EntryPoint]`, `@[AppHandler]`,
  `ctx.launch_activity()`); the hooks `on_before_options`, `on_before_guards`, `on_after_run`,
  `on_permissions_fail` and `on_internal_error`; `check_options`; and `c.commands.args_parser`
  for prefix commands.
- **Components:** `@[CustomIdRegex]` routes, a `filter` method that passes an interaction on,
  `ctx.modal(form, custom_id:)`, guards and hooks on handlers, `c.collect[T]` and
  `ctx.collect_components`, and `discord.file_from_base64`.
- **Utilities:** `veyfert.formatter`; the CDN URL of every image Discord serves; `mention()`,
  `url()`, `display_name()`, `tag()`, `Snowflake.created_at()`, `Snowflake.is_zero()`,
  `discord.colors`, `parse_color`, `rgb` and `parse_emoji`.
- **Cache:** `cache.Adapter`, with `MemoryAdapter`, `LimitedMemoryAdapter` and the conformance
  suite `check_adapter`, as a second level behind the in-memory cache (`cache.Options.adapter`).
- **Plugins:** `info() PluginInfo` (version, imports, semver requirements, intents), `c.hook`,
  `SharedKey[T]`, `c.wrap_guards`, `c.wrap_autocomplete`, `PluginError` and `PluginErrors`;
  what a plugin registers is taken back when it is torn down or its setup fails.
- **REST:** the generator skips nothing in Discord's spec: multipart endpoints, array query
  parameters, and the string enums as constants.
- **Gateway:** automatic resharding (`ClientOptions.resharding`).
- **Documentation:** `docs/` has a page per part, with examples that CI builds.

### Changes

- `run` waits for the events already queued before the `client_close` hooks and the plugins'
  teardown, and returns the teardown failures, which it used to log.
- `stop` closes the shards so that their sessions stay resumable: `save_sessions` and
  `ClientOptions.sessions` now resume them on the next start. Until they expire, Discord shows
  the bot online.
- `Plugin` is unchanged, but installing a second plugin with a name that is taken fails.
- `veyfert.testing`'s payloads give the bot every permission in the channel, so commands with
  `@[BotPerms]` run in tests. `testing.From`, the last argument of every payload builder, sets
  who sends a payload, their roles and the permissions involved, and `autocomplete_interaction`
  and `message_menu` build the two payloads that were missing.
