# veyfert documentation

veyfert is a Discord bot framework for V, inspired by Seyfert. Each page explains one part, with
examples you can copy; the complete programs in them are built in CI, so they compile as shown.

Start with [Getting started](getting-started.md), then read what your bot needs.

## Basics

| Page | What it covers |
|---|---|
| [Getting started](getting-started.md) | Installing, a first bot, uploading commands, building for production |
| [The client](client.md) | `ClientOptions`, intents, threads, running and stopping, logs |
| [Commands](commands.md) | Slash commands, options, subcommands, context menus, autocomplete, hooks, entry points, uploading |
| [Answering interactions](responses.md) | `write`, defer, edits, followups, embeds, files, mentions |
| [Guards](guards.md) | Checks before a command runs: cooldowns, permissions, your own |
| [Components and modals](components.md) | Buttons, selects, components v2, handlers, modals, collectors, polls |
| [Events](events.md) | Typed listeners, `wait_for`, collectors, custom events, the event list |
| [Prefix commands](prefix-commands.md) | The same commands from messages, such as `!ban @ana` |

## The connection

| Page | What it covers |
|---|---|
| [The gateway](gateway.md) | Shards, compression, saving sessions, lifecycle events, close codes, gateway requests |
| [Resharding](resharding.md) | Moving to more shards while the bot runs |
| [Interactions over HTTP](http-interactions.md) | `veyfert.server`: interactions on an HTTPS endpoint instead of the gateway |

## Data

| Page | What it covers |
|---|---|
| [The cache](cache.md) | What the bot knows without asking, cache options, permissions, adapters |
| [REST and shorters](rest.md) | `bot.messages`, `bot.members`… the REST client, rate limits, errors |
| [Every endpoint](rest-api.md) | `veyfert.rest.api`: one generated function per endpoint |
| [Discord's data](models.md) | `veyfert.discord`: snowflakes, permissions, files, CDN URLs, helpers |
| [Formatting text](formatter.md) | `veyfert.formatter`: markdown, mentions, timestamps, invite links |

## More

| Page | What it covers |
|---|---|
| [Languages](i18n.md) | `Langs[T]`: typed texts per language, and translated commands |
| [Plugins](plugins.md) | Writing and installing plugins, hooks, shared values, wrappers |
| [Testing a bot](testing.md) | `veyfert.testing`: a fake gateway and REST API |
| [Known V issues](known-issues.md) | What veyfert works around in V, and the issues upstream |
| [PLAN.md](PLAN.md) | The design, its decisions, and what was built in each phase |

## Modules

In V a folder is a module. A bot imports the layers it uses:

| Module | What it has |
|---|---|
| `veyfert` | The framework: `Client`, gateway and sharding, commands, contexts, guards, handlers, shorters, prefix commands, languages, plugins |
| `veyfert.discord` | Discord's data: models, events, components, embeds, polls, permissions, intents, snowflakes, files |
| `veyfert.cache` | The cache and its adapters |
| `veyfert.rest` | The HTTP client: rate limits, transports, `rest.DiscordError` |
| `veyfert.rest.api` | One generated function per REST endpoint |
| `veyfert.formatter` | Markdown, mentions, timestamps and links |
| `veyfert.plugins` | Official plugins, such as `plugins.Scheduler` |
| `veyfert.server` | Interactions received over HTTP |
| `veyfert.testing` | A fake gateway and REST API for tests |

`v doc` shows every public function and type with its comment. From the repository's root, this
writes a page per module into `api-docs/`:

```sh
v doc -m -f html -o api-docs .
```
