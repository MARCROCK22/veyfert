module discord

pub const cdn_base = 'https://cdn.discordapp.com'

@[params]
pub struct ImageOptions {
pub:
	size   int    // a power of 2 from 16 to 4096; 0 leaves it to Discord
	format string // png, jpg, webp or gif; '' is gif for animated hashes and png otherwise
}

// cdn_image builds the URL of a CDN image, such as `cdn_image('icons/${guild_id}', hash)`.
pub fn cdn_image(path string, hash string, opts ImageOptions) string {
	format := if opts.format != '' {
		opts.format
	} else if hash.starts_with('a_') {
		'gif'
	} else {
		'png'
	}
	url := '${cdn_base}/${path}/${hash}.${format}'
	return if opts.size > 0 { '${url}?size=${opts.size}' } else { url }
}

// avatar_url is the user's avatar, or Discord's default avatar when they have none.
pub fn (u User) avatar_url(opts ImageOptions) string {
	hash := u.avatar or { return '${cdn_base}/embed/avatars/${(u.id.value >> 22) % 6}.png' }
	return cdn_image('avatars/${u.id}', hash, opts)
}
