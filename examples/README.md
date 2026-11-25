# Example bots

Each folder is a complete bot. Run one from the folder that contains veyfert, with the bot's
token and a test server, where its commands appear at once:

```sh
DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/moderation
```

Without `GUILD_ID`, the commands are uploaded globally. Privileged intents must also be enabled
in the Developer Portal, under Bot; the table says which bots need them. CI builds every bot with
warnings as errors.

| Bot | What it does | What it shows | Privileged intents |
|---|---|---|---|
| [basic](basic/main.v) | Ping, a search with autocomplete, settings, a slow command, context menus | Options, subcommands, guards, prefix commands, deferring | — |
| [components](components/main.v) | Buttons, a select menu, a confirmation, a modal, a poll, a card | Components v1 and v2, modals, waiting for a click | — |
| [moderation](moderation/main.v) | Ban, unban, kick, timeout, purge and warnings | Permissions, the role hierarchy, DMs, `check_options`, one error hook for every command, prefix commands | — |
