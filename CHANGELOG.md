# Changelog

Breaking changes say what to change. See the deprecation policy in the README.

## 0.1.0 (unreleased)

Layout: the framework is `veyfert`, on top of `veyfert.discord` (types, events, components),
`veyfert.rest` (HTTP, rate limits) with `veyfert.rest.api` (generated endpoints) and
`veyfert.cache`; official plugins are in `veyfert.plugins`. Bots import `veyfert` and
`veyfert.discord`. Message and member actions are on the shorters: `c.messages.reply(msg, ...)`
and `c.members.ban(guild_id, user_id, ...)`.

First version: the gateway with sharding, resuming and zlib or zstd-stream compression; REST
with rate limits and generated endpoints; commands, subcommands, context menus, autocomplete,
guards and hooks; components v1 and v2 and modals; the cache and shorters; prefix commands;
languages; plugins; interactions over HTTP (`veyfert.server`); and `veyfert.testing`.
