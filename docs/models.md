# Discord's data: veyfert.discord

`veyfert.discord` has Discord's data as V structs: users, members, guilds, channels, messages,
roles, emojis, stickers, interactions, the gateway events, components, embeds and polls. It also
has snowflakes, permissions, intents, files, the CDN's URLs and small helpers. Optional fields are
`?T`.

```v
import os
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'whois', description: 'Shows who someone is')]
struct Whois {
mut:
	who discord.Member @[veyfert.Desc: 'Who']
}

fn (w Whois) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := w.who.user or { return }
	ctx.write(
		embeds: [
			discord.Embed{
				title:       w.who.display_name()
				description: '${user.mention()} (${user.tag()}), on Discord since ${user.id.created_at().ymmdd()}'
				color:       discord.parse_color('blurple')!
				thumbnail:   discord.Media{
					url: w.who.avatar_url(guild_id, size: 256)
				}
			},
		]
	)!
}

fn main() {
	perms := discord.Permissions.from_names('kick_members,ban_members') or { panic(err) }
	println('${perms.names()} is ${perms.wire()}')
	id := discord.Snowflake.parse('175928847299117063')!
	println('made at ${id.created_at()}')
	println(discord.parse_emoji('<a:wave:123>').reaction()) // wave:123, for the reaction shorters
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Whois{})
	bot.upload_commands()!
	bot.run()!
}
```

## Snowflakes

Discord's IDs are `discord.Snowflake`, a `u64` that travels as a string in JSON.

- `discord.Snowflake.parse('123')!` reads one, and `.str()` writes it.
- `id.created_at()` is when it was made, as a `time.Time`; `id.unix_ms()` the same in
  milliseconds.
- A literal: `discord.Snowflake{80351110224678912}`.

## Permissions

`discord.Permissions` is a flag enum: `.kick_members | .ban_members`.

- `perms.has(.administrator)` and `perms.all(.kick_members | .ban_members)` test bits.
- `discord.Permissions.parse('8')` reads Discord's string form, and `perms.wire()` writes it.
- `discord.Permissions.from_names('kick_members,ban_members')!` reads names, and
  `perms.names()` lists them.
- `discord.no_permissions()` and `discord.all_permissions()`.

## Intents

`discord.Intents` is a flag enum too; [client.md](client.md#intents) lists them.

## Files

`discord.File` is a name, bytes and a content type:

- `discord.file_from_path('chart.png')!`: the type comes from the extension.
- `discord.file_from_url('https://…', 'name.png')!`: downloads it.
- `discord.file_from_base64(name, data, content_type)!`: plain base64 or a `data:` URI, whose type
  wins.
- `file.data_uri()`: the file as a `data:` URI, as some endpoints want images.

## CDN URLs

The models build the URLs of the images Discord serves. `discord.ImageOptions` has `size` (one
of `discord.image_sizes`: 16, 32, 64, 100, 128, 256, 512, 1024, 2048 or 4096), `format` (one of
`discord.image_formats`: `webp`, `png`, `jpg`, `jpeg` or `gif`) and `force_static` (a still
image even for an animated one). A size or format the CDN does not offer
is left out of the URL; `ImageOptions.check()!` reports it.

| Method or function | Image |
|---|---|
| `user.avatar_url(opts)` | The avatar, or the default avatar |
| `user.banner_url(opts)`, `user.avatar_decoration_url(opts)` | `?string`: none when unset |
| `member.avatar_url(guild_id, opts)` | The server avatar, or the user's |
| `member.banner_url(guild_id, opts)` | The server banner |
| `guild.icon_url`, `splash_url`, `discovery_splash_url`, `banner_url` | The server's images |
| `role.icon_url(opts)` | A role icon |
| `emoji.url(opts)`, `sticker.url()`, `sound.url()` | Emojis, stickers, soundboard sounds |
| `scheduled_event.cover_url(opts)`, `application.icon_url(opts)`, `application.cover_url(opts)` | Their images |
| `discord.default_avatar_url`, `channel_icon_url`, `team_icon_url`, `app_asset_url`, `achievement_icon_url`, `sticker_pack_banner_url`, `guild_tag_badge_url`, `avatar_decoration_url`, `sound_url` | The rest |

## Helpers

| Helper | Gives |
|---|---|
| `user.mention()`, `member.mention()`, `role.mention()`, `channel.mention()` | `<@id>`, `<@&id>`, `<#id>` |
| `user.display_name()`, `member.display_name()` | The nickname, the global name, or the username |
| `user.tag()` | `name#1234`, or the username for new usernames |
| `channel.url()`, `message.url()` | Links that open them |
| `emoji.mention()`, `emoji.reaction()` | `<:name:id>`, and the form the reaction endpoints take |
| `discord.parse_emoji('<a:wave:123>')` | An emoji from what a user types: custom or Unicode |
| `discord.colors`, `discord.parse_color(text)!`, `discord.rgb(r, g, b)` | Seyfert's color names (`discord.colors.blurple`), and colors from `#5865F2`, `0x5865F2` or a name |

For markdown, mentions and timestamps in text, see [formatter.md](formatter.md).

## Nullable and RawJson

- `discord.Nullable[T]` tells "leave as it is" (none) from "clear" (`is_null: true`) in PATCH
  bodies; see [rest-api.md](rest-api.md#patch-bodies).
- `discord.RawJson` holds JSON that has several possible shapes: `text` is the JSON, and
  `.decode[T]()!` reads it as a type.

## Components, embeds and polls

Their constructors are in [components.md](components.md#building-components), and embeds in
[responses.md](responses.md#embeds).
