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
| [welcome](welcome/main.v) | Greets new members with a card and a role, and says goodbye | Gateway events as plain functions, the cache, allowed mentions, settings from the environment | Server Members |
| [tickets](tickets/main.v) | A panel button opens a form, the form opens a private thread with the staff, closing it logs a transcript | Buttons, a modal with dependencies, a handler guard, data in the custom ID, threads, files | — |
| [role-menu](role-menu/main.v) | An admin picks roles; members take them or give them back from a menu | A role select, `wait_for_component`, resolved data, a string select, deferred answers | — |
| [levels](levels/main.v) | XP for talking, level-up announcements, `/rank` and `/leaderboard`, saved to a JSON file | Message events, a custom event with `emit`, shared state, the Scheduler plugin, the `client_close` hook | — |
| [tictactoe](tictactoe/main.v) | Tic-tac-toe with buttons, against a member or against the bot | State in custom IDs (no storage), a prefix route, updating the message, disabled buttons | — |
| [reminders](reminders/main.v) | `/remind when:1h30m what:...`, then lists and cancels them; delivered by DM when the channel is closed | Autocomplete, `check_options`, subcommands, the Scheduler plugin, a JSON file written safely | — |
| [tags](tags/main.v) | Saved answers per server: create and edit them in a form, post them with `/tag show` or `@bot t name` | A modal for creating and editing (`CustomIdRegex`), shared autocomplete, a prefix-only command, no pings | — |
