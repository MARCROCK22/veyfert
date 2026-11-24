module discord

// Permissions is Discord's permission bitfield; values are bit positions. Discord sends it as
// a decimal string, which `Permissions.parse` reads.
@[flag]
pub enum Permissions as u64 {
	create_instant_invite
	kick_members
	ban_members
	administrator
	manage_channels
	manage_guild
	add_reactions
	view_audit_log
	priority_speaker
	stream
	view_channel
	send_messages
	send_tts_messages
	manage_messages
	embed_links
	attach_files
	read_message_history
	mention_everyone
	use_external_emojis
	view_guild_insights
	connect
	speak
	mute_members
	deafen_members
	move_members
	use_vad
	change_nickname
	manage_nicknames
	manage_roles
	manage_webhooks
	manage_guild_expressions
	use_application_commands
	request_to_speak
	manage_events
	manage_threads
	create_public_threads
	create_private_threads
	use_external_stickers
	send_messages_in_threads
	use_embedded_activities
	moderate_members
	view_creator_monetization_analytics
	use_soundboard
	create_guild_expressions
	create_events
	use_external_sounds
	send_voice_messages
	set_voice_channel_status = 48
	send_polls
	use_external_apps
	pin_messages
	bypass_slowmode
}

// Permissions.parse reads the decimal string Discord sends; an invalid string is no permission.
pub fn Permissions.parse(s string) Permissions {
	return unsafe { Permissions(s.parse_uint(10, 64) or { 0 }) }
}

// Permissions.from_names reads a comma-separated list such as 'ban_members,kick_members'.
pub fn Permissions.from_names(names string) !Permissions {
	mut p := Permissions.zero()
	for name in names.split(',') {
		if name.trim_space() != '' {
			p.set(Permissions.from(name.trim_space())!)
		}
	}
	return p
}

// wire is the decimal string Discord expects.
pub fn (p Permissions) wire() string {
	return u64(p).str()
}

// no_permissions has no permission set. Other modules use it because V does not reach a flag
// enum's built-in `zero()` through a module prefix.
pub fn no_permissions() Permissions {
	return Permissions.zero()
}

// all_permissions has every permission set, as the owner and administrators have.
pub fn all_permissions() Permissions {
	mut p := Permissions.zero()
	$for v in Permissions.values {
		p.set(v.value)
	}
	return p
}

// names lists the permissions, such as 'ban_members, kick_members'.
pub fn (p Permissions) names() string {
	mut out := []string{}
	$for v in Permissions.values {
		if p.has(v.value) {
			out << v.name
		}
	}
	return out.join(', ')
}
