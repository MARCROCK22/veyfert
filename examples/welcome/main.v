module main

import os
import time
import veyfert
import veyfert.discord
import veyfert.formatter

// A welcome bot: it greets new members with a card, gives them a role, and says goodbye when
// they leave. /welcome shows the card to the admins without anyone joining.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/welcome
// It needs the Server Members intent: enable it in the Developer Portal, under Bot.
//
// Optional settings:
//   WELCOME_CHANNEL_ID  where to greet; by default, the server's system channel
//   AUTO_ROLE_ID        a role for every new member; it must be below the bot's highest role

const welcome_channel_id = env_id('WELCOME_CHANNEL_ID')
const auto_role_id = env_id('AUTO_ROLE_ID')

// env_id reads an ID from the environment; 0 when it is not set.
fn env_id(name string) discord.Snowflake {
	return discord.Snowflake.parse(os.getenv(name)) or { discord.Snowflake{} }
}

// welcome_channel is where greetings go: WELCOME_CHANNEL_ID, or the system channel of the
// server, where Discord itself announces joins.
fn welcome_channel(guild discord.Guild) ?discord.Snowflake {
	if !welcome_channel_id.is_zero() {
		return welcome_channel_id
	}
	return guild.system_channel_id
}

// card is the welcome message for `user`.
fn card(guild discord.Guild, user discord.User) veyfert.MessageOptions {
	created := user.id.created_at()
	mut lines := ['You are member number ${guild.member_count} of **${guild.name}**.']
	if rules := guild.rules_channel_id {
		lines << 'Start by reading ${formatter.channel_mention(rules)}.'
	}
	if time.since(created) < 7 * 24 * time.hour {
		lines << '⚠️ This account was created ${formatter.timestamp(created, .relative)}.'
	}
	return veyfert.MessageOptions{
		content:          'Hi ${user.mention()}!'
		embeds:           [
			discord.Embed{
				title:       'Welcome, ${user.display_name()}!'
				description: lines.join('\n')
				color:       discord.colors.green
				thumbnail:   discord.Media{
					url: user.avatar_url(size: 256)
				}
				timestamp:   time.now().format_rfc3339()
			},
		]
		allowed_mentions: discord.AllowedMentions{
			users: [user.id] // ping the newcomer, and nobody a name might mention
		}
	}
}

// greet runs for every member who joins. The cache has already counted them.
fn greet(e discord.GuildMemberAdd, mut c veyfert.Client) ! {
	guild_id := e.guild_id or { return }
	user := e.user or { return }
	if !auto_role_id.is_zero() && !user.bot {
		// A failure here must not cost the greeting: log it and go on.
		c.members.add_role(guild_id, user.id, auto_role_id, 'Role for new members') or {
			c.logger.warn('could not give the role to ${user.username}: ${err}')
		}
	}
	guild := c.cache.guild(guild_id) or { return }
	channel := welcome_channel(guild) or { return }
	c.messages.write(channel, card(guild, user))!
}

// say_goodbye runs for every member who leaves, is kicked or is banned.
fn say_goodbye(e discord.GuildMemberRemove, mut c veyfert.Client) ! {
	guild := c.cache.guild(e.guild_id) or { return }
	channel := welcome_channel(guild) or { return }
	c.messages.write(channel,
		content: '👋 **${e.user.username}** left. We are ${guild.member_count} now.'
	)!
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'welcome', description: 'Shows the card that new members get')]
@[veyfert.Perms('manage_guild')]
struct Preview {}

fn (p Preview) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	guild := ctx.client.cache.guild(guild_id) or { return error('the server has not loaded yet') }
	where := if channel := welcome_channel(guild) {
		'New members get this in ${formatter.channel_mention(channel)}'
	} else {
		'This server has no system channel, so set WELCOME_CHANNEL_ID to greet new members'
	}
	role := if !auto_role_id.is_zero() {
		', with the role ${formatter.role_mention(auto_role_id)}'
	} else {
		''
	}
	ctx.write(
		content:   '${where}${role}:'
		embeds:    card(guild, ctx.author()).embeds
		ephemeral: true
	)!
}

fn main() {
	mut bot := veyfert.new_client(
		token:   os.getenv('DISCORD_TOKEN')
		intents: .guilds | .guild_members
	)
	bot.commands.add(Preview{})
	bot.on[discord.GuildMemberAdd](greet)
	bot.on[discord.GuildMemberRemove](say_goodbye)
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/welcome.json'
	)!
	bot.run()!
}
