# Every endpoint: veyfert.rest.api

`veyfert.rest.api` has one function per endpoint of Discord's REST API, with the request and
response models of Discord's OpenAPI spec: 250 endpoints, 447 models. It is generated, and it is
a separate module, so bots that do not import it do not compile it. Calls share the client's
rate limits.

Use the [shorters](rest.md#shorters) for the common actions, which return veyfert's own models
and keep them in the cache; use this for everything else.

```v
import os
import veyfert
import veyfert.rest.api

@[veyfert.Declare(name: 'links', description: 'Counts the messages with links that mention a word')]
struct Links {
mut:
	word string @[veyfert.Desc: 'The word']
}

fn (l Links) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut endpoints := api.new(mut ctx.client.rest)
	found := endpoints.guild_search(guild_id,
		content: l.word
		has:     [api.has_option_link]
		limit:   1
	)!
	ctx.write(content: '${found.total_results} messages with links mention "${l.word}"')!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Links{})
	mut endpoints := api.new(mut bot.rest)
	me := endpoints.get_my_application()!
	println('running ${me.name}')
	bot.upload_commands()!
	bot.run()!
}
```

## Naming

Each function is named after the endpoint's `operationId` in Discord's spec, in snake_case:
`get_guild`, `list_messages`, `create_message`, `update_guild`, `guild_search`. Path parameters
are arguments, in order; a JSON body is the `body` argument; the last argument is the options.

```v
mut endpoints := api.new(mut bot.rest)
guild := endpoints.get_guild(guild_id, with_counts: true)!
messages := endpoints.list_messages(channel_id, limit: 10, before: last_id)!
sent := endpoints.create_message(channel_id, api.MessageCreateRequest{ content: 'hi' }, reason: 'greeting')!
```

## Options and query parameters

An endpoint with query parameters takes a `…Options` struct, such as `api.ListMessagesOptions`;
the others take `rest.CallOptions`. Both have `reason`, written to the audit log, and `files`,
sent as multipart where the endpoint accepts them. Optional parameters are `?T`, and lists go
out as the parameter repeated: `author_id: [a, b]` sends `?author_id=a&author_id=b`.

## Enums

- Integer enums are V enums, such as `api.ChannelTypes`: `int(api.ChannelTypes.guild_text)`.
- String enums are constants: `api.has_option_link`, `api.sorting_order_desc`,
  `api.available_locales_enum_en_us`.

Fields keep the wire type, `int` or `string`, since Discord adds values and an unknown value would
fail to decode.

## PATCH bodies

In a PATCH, leaving a field out and setting it to `null` mean different things: unchanged, or
cleared. Nullable fields of PATCH bodies are `?discord.Nullable[T]`:

```v
endpoints.update_guild(guild_id, api.GuildPatchRequestPartial{
	name:        'Renamed'
	description: discord.Nullable[string]{
		is_null: true // clears the description
	}
	afk_timeout: discord.Nullable[int]{
		value: 300
	}
	// fields left out stay as they are
})!
```

## Unions

Where the spec allows several shapes, a field is a `discord.RawJson`: its `text` is the JSON, and
`.decode[T]()!` reads it as the type you expect.

```v
components := sent.components.decode[[]discord.Component]()!
```

## Multipart endpoints

Three endpoints take a form instead of JSON: their text fields are a `…Form` struct, and the file
is a `discord.File` argument.

```v
sticker := endpoints.create_guild_sticker(guild_id, api.CreateGuildStickerForm{
	name: 'wave'
	tags: 'hand'
}, discord.file_from_path('wave.png')!, reason: 'new sticker')!
```

The others are `upload_application_attachment` and `update_invite_target_users`.

## Regenerating

`tools/gen_api.vsh` writes `rest/api/models_gen.v` and `rest/api/rest_gen.v` from Discord's
spec, pinned to one commit of [discord-api-spec](https://github.com/discord/discord-api-spec):

```sh
v run tools/gen_api.vsh                 # downloads the pinned spec
v run tools/gen_api.vsh openapi.json    # or reads a local copy
```

It prints what it made and what it skipped, which is nothing at the pinned commit. Moving the pin
is a minor release, with the endpoints and models that changed listed in the changelog.
