module main

import os
import time
import veyfert
import veyfert.discord
import veyfert.formatter

// A self-assignable roles bot. /rolemenu asks an admin which roles to offer, with a role picker
// that Discord fills, then posts a menu where members pick roles to take them or give them back.
// The menu needs no database: its roles are the options of its select.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/role-menu
// The bot needs Manage Roles, and the roles it hands out must be below its highest role.

@[veyfert.BotPerms('manage_roles')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'rolemenu', description: 'Posts a menu where members pick their own roles')]
@[veyfert.Perms('manage_roles')]
struct RoleMenu {
mut:
	title       ?string @[veyfert.Desc: 'The title of the menu'; veyfert.MaxLength: 100]
	description ?string @[veyfert.Desc: 'What the roles are for'; veyfert.MaxLength: 1000]
}

fn (r RoleMenu) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	channel_id := ctx.channel_id() or { return }
	// 1. The admin picks roles in a select that Discord fills with the server's roles.
	ctx.write(
		content:    'Which roles can members take? Pick up to 25.'
		components: [
			discord.action_row(discord.role_select(
				custom_id:  'rolemenu:pick'
				min_values: 1
				max_values: 25
			)),
		]
		ephemeral:  true
	)!
	mut pick := ctx.wait_for_component(timeout: 2 * time.minute) or {
		ctx.edit_response(content: 'Time is up; run /rolemenu again.', components: [])!
		return
	}
	// 2. Keep the roles the bot can hand out: below its highest role, and not managed by an
	// integration, such as a bot's own role.
	me := ctx.client.members.fetch(guild_id, ctx.client.bot_id()!)!
	top := highest_role(mut ctx.client, guild_id, me.roles)
	picked := pick.resolved().roles
	mut options := []discord.SelectOption{}
	mut offered := []string{}
	mut skipped := []string{}
	for value in pick.values {
		role := picked[value] or { continue }
		if role.managed || role.id == guild_id || role.position >= top {
			skipped << role.mention()
			continue
		}
		options << discord.SelectOption{
			label: role.name
			value: role.id.str()
		}
		offered << role.mention()
	}
	if options.len == 0 {
		pick.update(
			content:    'I cannot hand out any of those roles: move my role above them in the server settings.'
			components: []
		)!
		return
	}
	// 3. The menu itself, in this channel, for everyone.
	ctx.client.messages.write(channel_id,
		embeds:     [
			discord.Embed{
				title:       r.title or { 'Pick your roles' }
				description: '${r.description or { 'Pick a role to take it; pick it again to give it back.' }}\n\n${offered.join('\n')}'
				color:       discord.colors.blurple
			},
		]
		components: [
			discord.action_row(discord.string_select(
				custom_id:   'rolemenu:toggle'
				placeholder: 'Pick roles to take or give back'
				min_values:  1
				max_values:  options.len
				options:     options
			)),
		]
	)!
	note := if skipped.len > 0 {
		'\nLeft out, because my role is not above them: ${skipped.join(', ')}'
	} else {
		''
	}
	pick.update(content: 'Posted the menu with ${options.len} roles.${note}', components: [])!
}

// highest_role is the position of the highest of `roles`; @everyone is 0.
fn highest_role(mut c veyfert.Client, guild_id discord.Snowflake, roles []discord.Snowflake) int {
	mut top := 0
	for role in c.cache.roles(guild_id) {
		if role.id in roles && role.position > top {
			top = role.position
		}
	}
	return top
}

// ToggleRoles gives a member each role they pick, or takes it back when they have it.
@[veyfert.CustomId('rolemenu:toggle')]
struct ToggleRoles {}

fn (h ToggleRoles) run(mut ctx veyfert.ComponentContext) ! {
	guild_id := ctx.guild_id() or { return }
	member := ctx.member() or { return }
	user_id := ctx.author().id
	ctx.defer_reply(true)! // a request per role may take more than 3 seconds
	mut lines := []string{}
	for value in ctx.values {
		role_id := discord.Snowflake.parse(value)!
		if role_id in member.roles {
			ctx.client.members.remove_role(guild_id, user_id, role_id, 'Role menu')!
			lines << '➖ ${formatter.role_mention(role_id)}'
		} else {
			ctx.client.members.add_role(guild_id, user_id, role_id, 'Role menu')!
			lines << '➕ ${formatter.role_mention(role_id)}'
		}
	}
	ctx.edit_response(content: lines.join('\n'))!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(RoleMenu{})
	bot.components.add(ToggleRoles{})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/role-menu.json'
	)!
	bot.run()!
}
