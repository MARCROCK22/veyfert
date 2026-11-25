module discord

import crypto.rand
import time

// Helpers on the models: mentions, links, display names, creation times, embed colors and
// emoji parsing.

// created_at is when the ID was made: when the user, message or channel was created.
pub fn (s Snowflake) created_at() time.Time {
	return time.unix_milli(i64(s.unix_ms()))
}

pub fn (u User) mention() string {
	return '<@${u.id}>'
}

// display_name is the user's global name, or their username.
pub fn (u User) display_name() string {
	return u.global_name or { u.username }
}

// tag is the username, with the discriminator of accounts that still have one.
pub fn (u User) tag() string {
	return if u.discriminator in ['', '0'] {
		u.username
	} else {
		'${u.username}#${u.discriminator}'
	}
}

pub fn (m Member) mention() string {
	user := m.user or { return '' }
	return user.mention()
}

// display_name is the member's nickname, or their user's display name.
pub fn (m Member) display_name() string {
	if nick := m.nick {
		return nick
	}
	user := m.user or { return '' }
	return user.display_name()
}

pub fn (c Channel) mention() string {
	return '<#${c.id}>'
}

// url opens the channel in Discord.
pub fn (c Channel) url() string {
	return 'https://discord.com/channels/${if id := c.guild_id {
		id.str()
	} else {
		'@me'
	}}/${c.id}'
}

pub fn (r Role) mention() string {
	return '<@&${r.id}>'
}

// url opens the message in Discord.
pub fn (m Message) url() string {
	return 'https://discord.com/channels/${if id := m.guild_id {
		id.str()
	} else {
		'@me'
	}}/${m.channel_id}/${m.id}'
}

// mention writes the emoji in a message: `<:name:id>` or `<a:name:id>`, or the Unicode emoji.
pub fn (e Emoji) mention() string {
	id := e.id or { return e.name }
	return '<${if e.animated or { false } { 'a' } else { '' }}:${e.name}:${id}>'
}

pub fn (e GuildEmoji) mention() string {
	id := e.id or { return e.name or { '' } }
	return '<${if e.animated { 'a' } else { '' }}:${e.name or { '_' }}:${id}>'
}

// reaction is the emoji as the reaction shorters take it: `name:id`, or the Unicode emoji.
pub fn (e Emoji) reaction() string {
	id := e.id or { return e.name }
	return '${e.name}:${id}'
}

// parse_emoji reads an emoji as users write it: `<:name:id>`, `<a:name:id>`, `name:id`, or a
// Unicode emoji.
pub fn parse_emoji(text string) Emoji {
	t := text.trim_space()
	if t.starts_with('<') && t.ends_with('>') {
		parts := t#[1..-1].split(':')
		if parts.len == 3 {
			if id := Snowflake.parse(parts[2]) {
				return Emoji{
					id:       id
					name:     parts[1]
					animated: parts[0] == 'a'
				}
			}
		}
	}
	if t.contains(':') {
		name, raw_id := t.all_before_last(':'), t.all_after_last(':')
		if id := Snowflake.parse(raw_id) {
			return Emoji{
				id:   id
				name: name
			}
		}
	}
	return Emoji{
		name: t
	}
}

// EmbedColors are Discord's palette, as Seyfert names it: `discord.colors.blurple`.
pub struct EmbedColors {
pub:
	default_color       int
	white               int = 0xffffff
	aqua                int = 0x1abc9c
	green               int = 0x57f287
	blue                int = 0x3498db
	yellow              int = 0xfee75c
	purple              int = 0x9b59b6
	luminous_vivid_pink int = 0xe91e63
	fuchsia             int = 0xeb459e
	gold                int = 0xf1c40f
	orange              int = 0xe67e22
	red                 int = 0xed4245
	grey                int = 0x95a5a6
	navy                int = 0x34495e
	dark_aqua           int = 0x11806a
	dark_green          int = 0x1f8b4c
	dark_blue           int = 0x206694
	dark_purple         int = 0x71368a
	dark_vivid_pink     int = 0xad1457
	dark_gold           int = 0xc27c0e
	dark_orange         int = 0xa84300
	dark_red            int = 0x992d22
	dark_grey           int = 0x979c9f
	darker_grey         int = 0x7f8c8d
	light_grey          int = 0xbcc0c0
	dark_navy           int = 0x2c3e50
	blurple             int = 0x5865f2
	greyple             int = 0x99aab5
	dark_but_not_black  int = 0x2c2f33
	not_quite_black     int = 0x23272a
	discord_dark        int = 0x313338
	discord_light       int = 0xf9f9f9
}

pub const colors = EmbedColors{}

// parse_color reads a color as Seyfert's resolveColor does: `#5865f2`, `5865f2`, `0x5865f2`, a
// name of `colors` (`blurple`, `dark_red`...) or `random`.
pub fn parse_color(text string) !int {
	t := text.trim_space().to_lower()
	if t == 'random' {
		return int(rand.int_u64(0x1000000) or { 0 })
	}
	$for f in EmbedColors.fields {
		if t == f.name || (t == 'default' && f.name == 'default_color') {
			return colors.$(f.name)
		}
	}
	hex := if t.starts_with('#') {
		t[1..]
	} else if t.starts_with('0x') {
		t[2..]
	} else {
		t
	}
	if hex.len == 0 || hex.len > 6 || !hex.bytes().all(it.is_hex_digit()) {
		return error('veyfert: `${text}` is not a color')
	}
	return int(hex.parse_uint(16, 32)!)
}

// rgb builds a color from its parts, 0 to 255 each.
pub fn rgb(r u8, g u8, b u8) int {
	return int(r) << 16 | int(g) << 8 | int(b)
}
