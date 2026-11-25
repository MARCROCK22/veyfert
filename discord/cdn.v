module discord

pub const cdn_base = 'https://cdn.discordapp.com'

// What the CDN serves, as Seyfert lists it.
pub const image_formats = ['webp', 'png', 'jpg', 'jpeg', 'gif']
pub const sticker_formats = ['png', 'json', 'gif']
pub const sound_formats = ['mp3', 'ogg']
pub const tag_badge_formats = ['png', 'jpeg', 'webp']
pub const image_sizes = [16, 32, 64, 100, 128, 256, 512, 1024, 2048, 4096]

@[params]
pub struct ImageOptions {
pub:
	size         int    // one of image_sizes; 0 leaves it to Discord
	format       string // one of image_formats; '' is gif for animated hashes and png otherwise
	force_static bool   // png even for an animated hash
}

// check tells whether the CDN serves this size and format. The URL helpers leave out a value
// it does not, rather than build a URL that Discord refuses.
pub fn (o ImageOptions) check() ! {
	if o.size != 0 && o.size !in image_sizes {
		return error('veyfert: the CDN has no size ${o.size}; it has ${image_sizes}')
	}
	if o.format != '' && o.format !in image_formats {
		return error('veyfert: the CDN has no format ${o.format}; it has ${image_formats}')
	}
}

fn image_url(url string, hash string, opts ImageOptions) string {
	format := if opts.force_static && hash.starts_with('a_') {
		'png'
	} else if opts.format in image_formats {
		opts.format
	} else if hash.starts_with('a_') {
		'gif'
	} else {
		'png'
	}
	full := '${url}.${format}'
	return if opts.size in image_sizes { '${full}?size=${opts.size}' } else { full }
}

// cdn_image builds the URL of a CDN image, such as `cdn_image('icons/${guild_id}', hash)`.
pub fn cdn_image(path string, hash string, opts ImageOptions) string {
	return image_url('${cdn_base}/${path}/${hash}', hash, opts)
}

// default_avatar_url is one of Discord's six default avatars, picked from the user's ID.
pub fn default_avatar_url(user_id Snowflake) string {
	return '${cdn_base}/embed/avatars/${(user_id.value >> 22) % 6}.png'
}

pub fn avatar_decoration_url(asset string, opts ImageOptions) string {
	return image_url('${cdn_base}/avatar-decoration-presets/${asset}', '', ImageOptions{
		...opts
		format: if opts.format == '' { 'png' } else { opts.format }
	})
}

// channel_icon_url is the icon of a group DM.
pub fn channel_icon_url(channel_id Snowflake, hash string, opts ImageOptions) string {
	return cdn_image('channel-icons/${channel_id}', hash, opts)
}

pub fn team_icon_url(team_id Snowflake, hash string, opts ImageOptions) string {
	return cdn_image('team-icons/${team_id}', hash, opts)
}

pub fn app_asset_url(application_id Snowflake, asset string, opts ImageOptions) string {
	return cdn_image('app-assets/${application_id}', asset, opts)
}

pub fn achievement_icon_url(application_id Snowflake, achievement_id Snowflake, hash string, opts ImageOptions) string {
	return cdn_image('app-assets/${application_id}/achievements/${achievement_id}/icons', hash,
		opts)
}

pub fn sticker_pack_banner_url(banner_asset_id Snowflake, opts ImageOptions) string {
	return cdn_image('app-assets/710982414301790216/store', banner_asset_id.str(), opts)
}

// guild_tag_badge_url is the badge of a guild tag; it is png, jpeg or webp.
pub fn guild_tag_badge_url(guild_id Snowflake, hash string, opts ImageOptions) string {
	return cdn_image('guild-tag-badges/${guild_id}', hash, ImageOptions{
		...opts
		format: if opts.format in tag_badge_formats { opts.format } else { 'png' }
	})
}

// sound_url is a soundboard sound; `format` is mp3 or ogg (the default).
pub fn sound_url(sound_id Snowflake, format string) string {
	return '${cdn_base}/soundboard-sounds/${sound_id}.${if format in sound_formats {
		format
	} else {
		'ogg'
	}}'
}

// avatar_url is the user's avatar, or Discord's default avatar when they have none.
pub fn (u User) avatar_url(opts ImageOptions) string {
	hash := u.avatar or { return default_avatar_url(u.id) }
	return cdn_image('avatars/${u.id}', hash, opts)
}

pub fn (u User) banner_url(opts ImageOptions) ?string {
	return cdn_image('banners/${u.id}', u.banner?, opts)
}

pub fn (u User) avatar_decoration_url(opts ImageOptions) ?string {
	decoration := u.avatar_decoration_data?
	return avatar_decoration_url(decoration.asset, opts)
}

// avatar_url is the member's avatar in their guild, or their user avatar.
pub fn (m Member) avatar_url(guild_id Snowflake, opts ImageOptions) string {
	user := m.user or { return '' }
	if hash := m.avatar {
		return cdn_image('guilds/${guild_id}/users/${user.id}/avatars', hash, opts)
	}
	return user.avatar_url(opts)
}

// banner_url is the member's banner in their guild, or their user banner.
pub fn (m Member) banner_url(guild_id Snowflake, opts ImageOptions) ?string {
	user := m.user?
	if hash := m.banner {
		return cdn_image('guilds/${guild_id}/users/${user.id}/banners', hash, opts)
	}
	return user.banner_url(opts)
}

pub fn (g Guild) icon_url(opts ImageOptions) ?string {
	return cdn_image('icons/${g.id}', g.icon?, opts)
}

pub fn (g Guild) splash_url(opts ImageOptions) ?string {
	return cdn_image('splashes/${g.id}', g.splash?, opts)
}

pub fn (g Guild) discovery_splash_url(opts ImageOptions) ?string {
	return cdn_image('discovery-splashes/${g.id}', g.discovery_splash?, opts)
}

pub fn (g Guild) banner_url(opts ImageOptions) ?string {
	return cdn_image('banners/${g.id}', g.banner?, opts)
}

pub fn (r Role) icon_url(opts ImageOptions) ?string {
	return cdn_image('role-icons/${r.id}', r.icon?, opts)
}

// url is a custom emoji's image; Unicode emojis have none.
pub fn (e Emoji) url(opts ImageOptions) ?string {
	id := e.id?
	return emoji_url(id, e.animated or { false }, opts)
}

pub fn (e GuildEmoji) url(opts ImageOptions) ?string {
	return emoji_url(e.id?, e.animated, opts)
}

fn emoji_url(id Snowflake, animated bool, opts ImageOptions) string {
	return image_url('${cdn_base}/emojis/${id}', if animated { 'a_' } else { '' }, opts)
}

// url is the sticker's file: png (also for APNG), gif, or json for Lottie stickers.
pub fn (s Sticker) url() string {
	format := match s.format_type {
		3 { 'json' }
		4 { 'gif' }
		else { 'png' }
	}
	// Discord serves GIF stickers from its media proxy.
	host := if format == 'gif' { 'https://media.discordapp.net' } else { cdn_base }
	return '${host}/stickers/${s.id}.${format}'
}

pub fn (e ScheduledEvent) cover_url(opts ImageOptions) ?string {
	return cdn_image('guild-events/${e.id}', e.image?, opts)
}

pub fn (a Application) icon_url(opts ImageOptions) ?string {
	return cdn_image('app-icons/${a.id}', a.icon?, opts)
}

pub fn (a Application) cover_url(opts ImageOptions) ?string {
	return cdn_image('app-icons/${a.id}', a.cover_image?, opts)
}

pub fn (s SoundboardSound) url() string {
	return sound_url(s.sound_id, 'ogg')
}
