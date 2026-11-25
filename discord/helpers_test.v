module discord

fn test_cdn_urls_follow_the_hash_and_keep_to_what_the_cdn_serves() {
	user := User{
		id:     Snowflake{80351110224678912}
		avatar: 'a_abc'
		banner: 'def'
	}
	base := 'https://cdn.discordapp.com'
	assert user.avatar_url() == '${base}/avatars/80351110224678912/a_abc.gif'
	assert user.avatar_url(force_static: true) == '${base}/avatars/80351110224678912/a_abc.png'
	assert user.avatar_url(size: 100, format: 'webp') == '${base}/avatars/80351110224678912/a_abc.webp?size=100'
	// Sizes and formats the CDN lacks are left out.
	assert user.avatar_url(size: 99, format: 'bmp') == '${base}/avatars/80351110224678912/a_abc.gif'
	assert (user.banner_url() or { '' }) == '${base}/banners/80351110224678912/def.png'
	plain := User{
		id: Snowflake{80351110224678912}
	}
	assert plain.avatar_url().starts_with('${base}/embed/avatars/')
	assert plain.banner_url() == none
	mut refused := ''
	ImageOptions{
		size: 99
	}.check() or { refused = err.msg() }
	assert refused.contains('no size 99')
	ImageOptions{
		size:   256
		format: 'jpg'
	}.check() or { assert false, err.msg() }

	member := Member{
		user:   user
		avatar: 'mem'
	}
	assert member.avatar_url(Snowflake{30}) == '${base}/guilds/30/users/80351110224678912/avatars/mem.png'
	assert (Member{
		user: plain
	}).avatar_url(Snowflake{30}) == plain.avatar_url()
	guild := Guild{
		id:   Snowflake{30}
		icon: 'ico'
	}
	assert (guild.icon_url(size: 64) or { '' }) == '${base}/icons/30/ico.png?size=64'
	assert guild.banner_url() == none
	assert (Role{
		id:   Snowflake{50}
		icon: 'r'
	}.icon_url() or { '' }) == '${base}/role-icons/50/r.png'
	assert (Emoji{
		id:       Snowflake{9}
		name:     'wave'
		animated: true
	}.url() or { '' }) == '${base}/emojis/9.gif'
	assert Emoji{
		name: '👍'
	}.url() == none
	assert Sticker{
		id:          Snowflake{7}
		format_type: 4
	}.url() == 'https://media.discordapp.net/stickers/7.gif'
	assert Sticker{
		id:          Snowflake{7}
		format_type: 3
	}.url() == '${base}/stickers/7.json'
	assert sound_url(Snowflake{3}, 'mp3') == '${base}/soundboard-sounds/3.mp3'
	assert sound_url(Snowflake{3}, 'wav') == '${base}/soundboard-sounds/3.ogg'
	assert guild_tag_badge_url(Snowflake{30}, 'b', format: 'gif') == '${base}/guild-tag-badges/30/b.png'
	assert avatar_decoration_url('a_deco', format: 'png') == '${base}/avatar-decoration-presets/a_deco.png'
}

fn test_mentions_links_and_names() {
	user := User{
		id:            Snowflake{7}
		username:      'ana'
		discriminator: '0'
	}
	assert user.mention() == '<@7>' && user.display_name() == 'ana' && user.tag() == 'ana'
	old := User{
		username:      'bob'
		discriminator: '1234'
		global_name:   'Bobby'
	}
	assert old.tag() == 'bob#1234' && old.display_name() == 'Bobby'
	assert Member{
		user: user
		nick: 'Annie'
	}.display_name() == 'Annie'
	assert Member{
		user: old
	}.display_name() == 'Bobby'
	assert Member{
		user: user
	}.mention() == '<@7>'
	assert Channel{
		id:       Snowflake{40}
		guild_id: Snowflake{30}
	}.url() == 'https://discord.com/channels/30/40'
	assert Channel{
		id: Snowflake{41}
	}.mention() == '<#41>'
	assert Role{
		id: Snowflake{50}
	}.mention() == '<@&50>'
	assert Message{
		id:         Snowflake{5}
		channel_id: Snowflake{41}
	}.url() == 'https://discord.com/channels/@me/41/5'
	// Discord's own example: 175928847299117063 was made on 2016-04-30 11:18:25.796 UTC.
	assert Snowflake{175928847299117063}.created_at().unix_milli() == 1462015105796
}

fn test_emojis_parse_and_encode() {
	wave := parse_emoji('<a:wave:123>')
	assert wave.id or { Snowflake{} } == Snowflake{123} && wave.name == 'wave'
		&& wave.animated or { false }
	assert wave.mention() == '<a:wave:123>' && wave.reaction() == 'wave:123'
	assert parse_emoji('blob:456').reaction() == 'blob:456'
	thumbs := parse_emoji(' 👍 ')
	assert thumbs.id == none && thumbs.reaction() == '👍' && thumbs.mention() == '👍'
	assert parse_emoji('<:x:notanid>').id == none
	assert GuildEmoji{
		id:   Snowflake{9}
		name: 'blob'
	}.mention() == '<:blob:9>'
}

fn test_colors_parse_as_seyfert_resolves_them() ! {
	assert parse_color('#5865F2')! == 0x5865f2
	assert parse_color('0xff0000')! == 0xff0000
	assert parse_color('57f287')! == colors.green
	assert parse_color('Blurple')! == colors.blurple
	assert parse_color('dark_red')! == 0x992d22
	assert parse_color('default')! == 0
	random := parse_color('random')!
	assert random >= 0 && random <= 0xffffff
	for bad in ['nope', '#1234567', '#', '#xyz'] {
		if _ := parse_color(bad) {
			assert false, '${bad} is not a color'
		}
	}
	assert rgb(88, 101, 242) == colors.blurple
}
