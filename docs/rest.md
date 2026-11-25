# REST and shorters

Everything that is not the gateway goes through Discord's REST API: sending messages, banning,
creating channels. veyfert has three layers for it:

- **Shorters** (`bot.messages`, `bot.members`, `bot.guilds`…): the common actions with veyfert's
  own models, which also keep what Discord answers in the [cache](cache.md). Start here.
- **`veyfert.rest.api`**: one generated function per endpoint of Discord's API, for the rest; see
  [rest-api.md](rest-api.md).
- **`bot.rest`**: the HTTP client underneath both, with Discord's rate limits.

```v
import os
import time
import veyfert
import veyfert.rest

@[veyfert.Declare(name: 'clean', description: 'Deletes the last messages')]
@[veyfert.Perms('manage_messages')]
struct Clean {
mut:
	count int @[veyfert.Desc: 'How many'; veyfert.Max: 100; veyfert.Min: 2]
}

fn (c Clean) run(mut ctx veyfert.CommandContext) ! {
	channel_id := ctx.channel_id() or { return }
	ctx.defer_reply(true)!
	messages := ctx.client.messages.list(channel_id, limit: c.count)!
	ctx.client.messages.delete_bulk(channel_id, messages.map(it.id), 'cleaned by ${ctx.author().username}') or {
		if err is rest.DiscordError {
			ctx.edit_response(content: 'Discord refused: ${err.message} (code ${err.error_code})')!
			return
		}
		return err
	}
	ctx.edit_response(content: 'Deleted ${messages.len} messages.')!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	// Every attempt of every request, for metrics or logs.
	bot.rest.observe(fn (e rest.RestEvent) {
		if e.status == 429 || e.duration > 2 * time.second {
			println('${e.method} ${e.route}: ${e.status} in ${e.duration} (attempt ${e.attempt})')
		}
	})
	bot.commands.add(Clean{})
	bot.upload_commands()!
	bot.run()!
}
```

## Shorters

As in Seyfert, a shorter call asks Discord, keeps the answer in the cache, then returns it.
`fetch` methods read the cache first; `force: true` asks Discord anyway. Actions that Discord
records in the audit log take a `reason`.

```v
msg := bot.messages.write(channel_id, content: 'Hello')!
bot.messages.reply(msg, content: 'Replying to myself')!
bot.reactions.add(channel_id, msg.id, '👍')!
bot.members.ban(guild_id, user_id, 24 * time.hour, 'raid')! // deletes a day of their messages
bot.members.timeout(guild_id, user_id, 10 * time.minute, 'spam')!
role := bot.roles.create(guild_id, name: 'Helpers', color: 0x57F287)!
bot.members.add_role(guild_id, user_id, role.id, 'helps a lot')!
dm := bot.users.write(user_id, content: 'Welcome!')!
guild := bot.guilds.fetch(guild_id)! // from the cache when it is there
```

| Shorter | What it covers |
|---|---|
| `bot.messages` | write, reply, edit, delete, fetch, list, delete_bulk, crosspost, pin, unpin, pins, end_poll, answer_voters |
| `bot.reactions` | add, delete_own, delete, list, clear |
| `bot.channels` | fetch, list, create, edit, delete, typing, set_permission, delete_permission, edit_positions, add_follower, member_permissions, role_permissions, overwrites_for, fetch_member_permissions, fetch_role_permissions, set_voice_status |
| `bot.members` | fetch, list, search, edit, kick, ban, unban, add_role, remove_role, timeout, resolve, add, roles, sort_roles, permissions, fetch_permissions, presence, voice, has_timeout |
| `bot.roles` | list, fetch, create, edit, delete, member_counts, fetch_permissions, edit_positions |
| `bot.guilds` | fetch, list, leave, edit, fetch_self, widget_url, incidents, search_messages |
| `bot.guilds.audit` | fetch (the audit log) |
| `bot.guilds.onboarding`, `bot.guilds.welcome` | fetch, edit |
| `bot.guilds.widget` | settings, edit, fetch, image |
| `bot.guilds.moderation` | auto moderation rules: list, create, fetch, edit, delete |
| `bot.guilds.events` | scheduled events: list, create, fetch, edit, delete, subscribers |
| `bot.guilds.stickers` | list, fetch, create, edit, delete |
| `bot.users` | fetch, dm, write, delete_dm |
| `bot.threads` | create, create_from_message, join, leave, add_member, remove_member, list_active, edit, lock, fetch_member, list_members, list_archived, list_joined_archived_private |
| `bot.webhooks` | create, list, delete, execute, edit, fetch, fetch_message, edit_message, delete_message, list_guild |
| `bot.bans` | list, fetch, create, remove, bulk_create |
| `bot.emojis` | list, create, delete, fetch, edit |
| `bot.application` | the application: fetch, edit, its emojis, entitlements and SKUs, activity_instance |
| `bot.monetization` | list_skus, fetch_sku, subscriptions, fetch_subscription |
| `bot.interactions` | answers by interaction token: reply, followup, fetch_response, edit_message, delete_response… |
| `bot.invites` | fetch, delete, create, list_channel, list_guild, and the target users of an invite |
| `bot.soundboard` | defaults, send, list, fetch, create, edit, delete |
| `bot.stages` | stage instances: fetch, create, edit, delete |
| `bot.templates` | guild templates: fetch, list, create, sync, edit, delete |
| `bot.voice_states` | request_speak, set_suppress |

`v doc` shows every method with its options. Shorters that need the application ID ask Discord
for it once, when the gateway has not given it.

## The REST client

`bot.rest` sends authenticated requests:

```v
// A body comes back as text; get[T] decodes it.
text := bot.rest.request(.get, '/users/@me')!
me := bot.rest.get[discord.User]('/users/@me')!
// A JSON body, an audit log reason, and files as multipart.
bot.rest.request(.post, '/channels/${channel_id}/messages',
	body:   '{"content":"Look"}'
	reason: 'testing'
	files:  [discord.file_from_path('chart.png')!]
)!
```

`rest.RequestOptions` has `body` (JSON), `query` (encoded, without `?`), `reason`, `files`,
`form` and `file_field` (plain multipart forms), and `auth` (false for requests without the token).

## Rate limits

Requests follow Discord's rate limits by themselves:

- Routes share buckets as Discord says in its headers, and wait when a bucket is empty.
- The global limit of 50 requests a second is respected; interaction answers do not count.
- A 429 waits for `retry_after` and tries again; a global 429 pauses every request.
- 502 and 503 are retried three times.

## Errors

A non-2xx answer is a `rest.DiscordError` with `method`, `route` (tokens redacted), `status`,
`error_code` (Discord's JSON code, such as 50013 for missing permissions), `message`, and `body`,
which holds the per-field errors of a 400:

```v
bot.members.kick(guild_id, user_id, '') or {
	if err is rest.DiscordError && err.error_code == 50013 {
		println('missing permissions')
	}
}
```

## Observers and transports

- `bot.rest.observe(fn (rest.RestEvent))` runs after every attempt, with `method`, `route`,
  `status` (0 when no answer came), `attempt` and `duration`.
- `bot.rest.transport` sends the HTTP requests. Tests swap in a fake with
  `veyfert.testing.new_transport()` (see [testing.md](testing.md)), and a proxy can implement
  `rest.Transport` (`send(req rest.HttpRequest) !rest.HttpResponse`).
