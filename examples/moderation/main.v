module main

import os
import sync
import time
import veyfert
import veyfert.discord
import veyfert.formatter
import veyfert.rest

// A moderation bot: ban, unban, kick, timeout, purge and warnings, as slash commands and as
// prefix commands (`!ban @ana spamming`). It checks the role hierarchy before it acts, tells
// members why by DM, and turns Discord's refusals into answers.
//
// Run it from the folder that contains veyfert, with a test server so commands appear at once:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/moderation
// Prefix commands work by mentioning the bot (`@bot ban @ana spamming`). For `!ban`, enable the
// Message Content intent in the Developer Portal and add `.message_content` to the intents.

// Refusal is an error meant for the user: the error hook in `main` shows its text as it is.
struct Refusal {
	Error
	text string
}

fn (r Refusal) msg() string {
	return r.text
}

fn refuse(text string) IError {
	return Refusal{
		text: text
	}
}

// check_target refuses when the author or the bot may not act on `target`: themselves, the
// server owner, or a member whose highest role is not below theirs. Discord enforces the last
// one for the bot anyway; checking first gives a clear answer.
fn check_target(mut ctx veyfert.CommandContext, target discord.Member) ! {
	guild_id := ctx.guild_id() or { return refuse('This only works in servers.') }
	user := target.user or { return refuse('That member left the server.') }
	bot_id := ctx.client.bot_id()!
	if user.id == ctx.author().id {
		return refuse('You cannot do that to yourself.')
	}
	if user.id == bot_id {
		return refuse('I will not do that to myself.')
	}
	guild := ctx.client.cache.guild(guild_id) or { return } // not loaded yet: Discord decides
	if user.id == guild.owner_id {
		return refuse('Nobody can do that to the server owner.')
	}
	target_top := highest_role(mut ctx.client, guild_id, target.roles)
	if ctx.author().id != guild.owner_id {
		author := ctx.member() or { return refuse('This only works in servers.') }
		if highest_role(mut ctx.client, guild_id, author.roles) <= target_top {
			return refuse('${user.username} has a role as high as yours.')
		}
	}
	me := ctx.client.members.fetch(guild_id, bot_id)!
	if highest_role(mut ctx.client, guild_id, me.roles) <= target_top {
		return refuse('My highest role must be above the highest role of ${user.username}.')
	}
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

// notify tells `user` by DM what happened and why. Members may close their DMs, so a failure
// only means they will not know. It runs before a kick or a ban: after them, the bot and the
// user may share no server, and Discord refuses the DM.
fn notify(mut ctx veyfert.CommandContext, user discord.User, action string, reason string) {
	guild_id := ctx.guild_id() or { return }
	if user.bot {
		return
	}
	place := if guild := ctx.client.cache.guild(guild_id) { guild.name } else { 'a server' }
	ctx.client.users.write(user.id,
		embeds: [
			discord.Embed{
				title:       'You were ${action} in ${place}'
				description: reason
				color:       discord.colors.red
				timestamp:   time.now().format_rfc3339()
			},
		]
	) or {}
}

// audit is the reason the audit log shows: who did it, and why.
fn audit(ctx veyfert.CommandContext, reason string) string {
	return '${ctx.author().username}: ${reason}'
}

@[veyfert.BotPerms('ban_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'ban', description: 'Bans a user, also one who is not in the server')]
@[veyfert.Perms('ban_members')]
struct Ban {
mut:
	user   discord.User @[veyfert.Desc: 'Who to ban']
	reason ?string      @[veyfert.Desc: 'Why; they get it by DM'; veyfert.MaxLength: 400]
	days   ?int         @[veyfert.Desc: 'Delete their messages of the last days'; veyfert.Max: 7; veyfert.Min: 0]
}

fn (b Ban) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	reason := b.reason or { 'No reason given' }
	// A member must be below the author and the bot; a user who is not in the server has no roles.
	if member := ctx.client.members.fetch(guild_id, b.user.id) {
		check_target(mut ctx, member)!
		notify(mut ctx, b.user, 'banned', reason)
	}
	ctx.client.members.ban(guild_id, b.user.id, time.Duration(b.days or { 0 }) * 24 * time.hour,
		audit(ctx, reason))!
	ctx.write(content: '🔨 Banned ${b.user.mention()}: ${reason}')!
}

@[veyfert.BotPerms('ban_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'unban', description: 'Lifts a ban')]
@[veyfert.Perms('ban_members')]
struct Unban {
mut:
	user   discord.User @[veyfert.Desc: 'Who to unban (paste their ID)']
	reason ?string      @[veyfert.Desc: 'Why'; veyfert.MaxLength: 400]
}

fn (u Unban) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	ctx.client.members.unban(guild_id, u.user.id, audit(ctx, u.reason or { 'No reason given' })) or {
		if err is rest.DiscordError && err.error_code == 10026 {
			return refuse('${u.user.username} is not banned.')
		}
		return err
	}
	ctx.write(content: '🔓 Unbanned ${u.user.mention()}.')!
}

@[veyfert.BotPerms('kick_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'kick', description: 'Kicks a member')]
@[veyfert.Perms('kick_members')]
struct Kick {
mut:
	member discord.Member @[veyfert.Desc: 'Who to kick']
	reason ?string        @[veyfert.Desc: 'Why; they get it by DM'; veyfert.MaxLength: 400]
}

fn (k Kick) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := k.member.user or { return }
	reason := k.reason or { 'No reason given' }
	check_target(mut ctx, k.member)!
	notify(mut ctx, user, 'kicked', reason)
	ctx.client.members.kick(guild_id, user.id, audit(ctx, reason))!
	ctx.write(content: '👢 Kicked ${user.mention()}: ${reason}')!
}

@[veyfert.BotPerms('moderate_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'timeout', description: 'Keeps a member from talking for a while')]
@[veyfert.Perms('moderate_members')]
struct Timeout {
mut:
	member   discord.Member @[veyfert.Desc: 'Who to time out']
	duration string         @[veyfert.Desc: 'How long: 10m, 2h, 1d12h... up to 28d'; veyfert.MaxLength: 20]
	reason   ?string        @[veyfert.Desc: 'Why; they get it by DM'; veyfert.MaxLength: 400]
	// Not an option: check_options works it out from `duration`.
	length time.Duration
}

// check_options rejects a duration it cannot read, before anything happens.
fn (mut t Timeout) check_options(mut _ veyfert.CommandContext) ! {
	t.length = parse_duration(t.duration)!
	if t.length > 28 * 24 * time.hour {
		return error('a timeout lasts 28 days at most')
	}
}

fn (t Timeout) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := t.member.user or { return }
	reason := t.reason or { 'No reason given' }
	check_target(mut ctx, t.member)!
	notify(mut ctx, user, 'timed out for ${t.duration}', reason)
	ctx.client.members.timeout(guild_id, user.id, t.length, audit(ctx, reason))!
	until := time.now().add(t.length)
	ctx.write(
		content: '🔇 ${user.mention()} is timed out until ${formatter.timestamp(until, .long_date_short_time)} (${formatter.timestamp(until, .relative)}): ${reason}'
	)!
}

@[veyfert.BotPerms('moderate_members')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'untimeout', description: 'Lifts a timeout')]
@[veyfert.Perms('moderate_members')]
struct Untimeout {
mut:
	member discord.Member @[veyfert.Desc: 'Whose timeout to lift']
	reason ?string        @[veyfert.Desc: 'Why'; veyfert.MaxLength: 400]
}

fn (u Untimeout) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := u.member.user or { return }
	if !ctx.client.members.has_timeout(u.member) {
		return refuse('${user.username} is not timed out.')
	}
	ctx.client.members.timeout(guild_id, user.id, 0, audit(ctx, u.reason or { 'No reason given' }))!
	ctx.write(content: '🔊 ${user.mention()} can talk again.')!
}

@[veyfert.BotPerms('manage_messages')]
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'purge', description: 'Deletes recent messages in this channel')]
@[veyfert.Perms('manage_messages')]
struct Purge {
mut:
	count int           @[veyfert.Desc: 'How many recent messages to look at'; veyfert.Max: 100; veyfert.Min: 1]
	user  ?discord.User @[veyfert.Desc: 'Only delete the messages of this user']
}

fn (p Purge) run(mut ctx veyfert.CommandContext) ! {
	channel_id := ctx.channel_id() or { return }
	ctx.defer_reply(true)!
	// Discord deletes in bulk only messages younger than two weeks.
	oldest := time.now().add(-14 * 24 * time.hour + time.hour)
	mut ids := []discord.Snowflake{}
	for msg in ctx.client.messages.list(channel_id, limit: p.count)! {
		if user := p.user {
			if msg.author.id != user.id {
				continue
			}
		}
		if msg.id.created_at() > oldest {
			ids << msg.id
		}
	}
	reason := audit(ctx, 'purge')
	match ids.len {
		0 {
			ctx.edit_response(content: 'There is nothing to delete younger than two weeks.')!
			return
		}
		1 {
			ctx.client.messages.delete(channel_id, ids[0], reason)!
		}
		else {
			ctx.client.messages.delete_bulk(channel_id, ids, reason)!
		}
	}
	ctx.edit_response(content: '🧹 Deleted ${ids.len} messages.')!
}

// Warning is one warning of a member.
struct Warning {
	reason string
	by     discord.Snowflake
	at     time.Time
}

// Warnings keeps the warnings of each member in memory. Commands run on several threads, so a
// mutex guards it; a bot that must remember them after a restart keeps them in a database.
@[heap]
struct Warnings {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	list map[string][]Warning // by '<guild_id>:<user_id>'
}

fn (mut w Warnings) add(guild_id discord.Snowflake, user_id discord.Snowflake, warning Warning) int {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	key := '${guild_id}:${user_id}'
	w.list[key] << warning
	return w.list[key].len
}

fn (mut w Warnings) of(guild_id discord.Snowflake, user_id discord.Snowflake) []Warning {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	return (w.list['${guild_id}:${user_id}'] or { [] }).clone()
}

fn (mut w Warnings) clear(guild_id discord.Snowflake, user_id discord.Snowflake) int {
	w.mu.lock()
	defer {
		w.mu.unlock()
	}
	key := '${guild_id}:${user_id}'
	count := (w.list[key] or { [] }).len
	w.list.delete(key)
	return count
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'warn', description: 'Warns a member by DM and keeps the warning')]
@[veyfert.Perms('moderate_members')]
struct Warn {
	warnings &Warnings // no attribute: a dependency, shared by every copy of the command
mut:
	member discord.Member @[veyfert.Desc: 'Who to warn']
	reason string         @[veyfert.Desc: 'Why; they get it by DM'; veyfert.MaxLength: 400]
}

fn (w Warn) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := w.member.user or { return }
	check_target(mut ctx, w.member)!
	mut warnings := w.warnings
	count := warnings.add(guild_id, user.id, Warning{
		reason: w.reason
		by:     ctx.author().id
		at:     time.now()
	})
	notify(mut ctx, user, 'warned', w.reason)
	ctx.write(content: '⚠️ Warned ${user.mention()} (warning ${count}): ${w.reason}')!
}

@[veyfert.Declare(name: 'list', description: 'Lists the warnings of a member')]
struct WarningsList {
	warnings &Warnings
mut:
	member discord.Member @[veyfert.Desc: 'Whose warnings']
}

fn (l WarningsList) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := l.member.user or { return }
	mut warnings := l.warnings
	list := warnings.of(guild_id, user.id)
	if list.len == 0 {
		ctx.write(content: '${user.username} has no warnings.', ephemeral: true)!
		return
	}
	// An embed has 25 fields at most: show the latest.
	shown := list#[-25..]
	mut fields := []discord.EmbedField{}
	for i, warning in shown {
		fields << discord.EmbedField{
			name:  '#${list.len - shown.len + i + 1}, ${formatter.timestamp(warning.at, .relative)}'
			value: '${warning.reason}\nby ${formatter.user_mention(warning.by)}'
		}
	}
	ctx.write(
		embeds:    [
			discord.Embed{
				title:  'Warnings of ${user.username} (${list.len})'
				color:  discord.colors.yellow
				fields: fields
			},
		]
		ephemeral: true
	)!
}

@[veyfert.Declare(name: 'clear', description: 'Forgets the warnings of a member')]
struct WarningsClear {
	warnings &Warnings
mut:
	member discord.Member @[veyfert.Desc: 'Whose warnings']
}

fn (c WarningsClear) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := c.member.user or { return }
	mut warnings := c.warnings
	count := warnings.clear(guild_id, user.id)
	ctx.write(content: 'Forgot ${count} warnings of ${user.mention()}.')!
}

// /warnings list and /warnings clear.
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'warnings', description: 'Shows or clears warnings')]
@[veyfert.Perms('moderate_members')]
struct WarningsCommand {
mut:
	list  WarningsList  @[veyfert.Sub]
	clear WarningsClear @[veyfert.Sub]
}

// parse_duration reads durations such as 45s, 10m, 2h, 1d12h or 1w.
fn parse_duration(text string) !time.Duration {
	invalid := error('`${text}` is not a duration such as 10m, 2h or 1d12h')
	mut total := time.Duration(0)
	mut number := i64(0)
	mut digits := 0
	for ch in text.trim_space().to_lower() {
		if ch.is_digit() {
			number = number * 10 + i64(ch - `0`)
			digits++
			if digits > 6 {
				return invalid
			}
			continue
		}
		unit := match ch {
			`s` { time.second }
			`m` { time.minute }
			`h` { time.hour }
			`d` { 24 * time.hour }
			`w` { 7 * 24 * time.hour }
			else { return invalid }
		}
		if digits == 0 {
			return invalid
		}
		total += time.Duration(number) * unit
		number = 0
		digits = 0
	}
	if digits > 0 || total == 0 {
		return invalid
	}
	return total
}

fn main() {
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		intents:  .guilds | .guild_messages
		prefixes: ['!']
	)
	warnings := &Warnings{}
	bot.commands.add(Ban{})
	bot.commands.add(Unban{})
	bot.commands.add(Kick{})
	bot.commands.add(Timeout{})
	bot.commands.add(Untimeout{})
	bot.commands.add(Purge{})
	bot.commands.add(Warn{
		warnings: warnings
	})
	bot.commands.add(WarningsCommand{
		list:  WarningsList{
			warnings: warnings
		}
		clear: WarningsClear{
			warnings: warnings
		}
	})
	// One answer for every failure: refusals as they are, Discord's permission errors explained,
	// and anything else logged.
	bot.commands.defaults.on_run_error = fn (mut ctx veyfert.CommandContext, failure IError) ! {
		text := if failure is Refusal {
			failure.text
		} else if failure is rest.DiscordError && failure.error_code == 50013 {
			'Discord says I am missing permissions for that here.'
		} else {
			ctx.client.logger.error('/${ctx.path}: ${failure}')
			'Something went wrong.'
		}
		ctx.edit_or_reply(content: '❌ ${text}', ephemeral: true)!
	}
	bot.on[veyfert.BotReady](fn (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('Ready as ${e.user.username}')
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/moderation.json'
	)!
	bot.run()!
}
