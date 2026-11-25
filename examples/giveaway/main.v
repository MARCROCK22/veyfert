module main

import crypto.rand
import json2
import os
import sync
import time
import veyfert
import veyfert.discord
import veyfert.formatter
import veyfert.plugins

// A giveaway bot. /giveaway posts a giveaway with an Enter button that members press to enter
// or leave; when it ends, the bot draws the winners, closes the message and congratulates them.
// Right-click a giveaway, then Apps, to end it early or to reroll its winners. Giveaways are
// kept in a JSON file, so a restart does not lose them.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/giveaway
// GIVEAWAYS_FILE chooses the file (giveaways.json by default).

struct Giveaway {
	message_id discord.Snowflake
	channel_id discord.Snowflake
	host_id    discord.Snowflake
	prize      string
	winners    int
	ends       i64 // Unix seconds
mut:
	entrants []discord.Snowflake
	ended    bool
}

// Giveaways holds every giveaway by the ID of its message. Clicks, commands and the job that
// ends giveaways run on different threads, so a mutex guards it, and every change is written
// to the file while it is held.
@[heap]
struct Giveaways {
	path string
mut:
	mu   &sync.Mutex = sync.new_mutex()
	list map[string]Giveaway
}

fn load_giveaways(path string) !&Giveaways {
	mut g := &Giveaways{
		path: path
	}
	if os.exists(path) {
		g.list = json2.decode[map[string]Giveaway](os.read_file(path)!)!
	}
	return g
}

// write saves the giveaways through a temporary file. The caller holds the mutex.
fn (g &Giveaways) write() ! {
	os.write_file('${g.path}.tmp', json2.encode(g.list))!
	os.mv('${g.path}.tmp', g.path)!
}

fn (mut g Giveaways) add(giveaway Giveaway) ! {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	g.list[giveaway.message_id.str()] = giveaway
	g.write()!
}

fn (mut g Giveaways) get(message_id discord.Snowflake) ?Giveaway {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	giveaway := g.list[message_id.str()] or { return none }
	return giveaway
}

// toggle enters a member in a running giveaway, or takes them out, and tells which.
fn (mut g Giveaways) toggle(message_id discord.Snowflake, user_id discord.Snowflake) !(bool, Giveaway) {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	mut giveaway := g.list[message_id.str()] or { return error('no such giveaway') }
	if giveaway.ended {
		return error('this giveaway is over')
	}
	i := giveaway.entrants.index(user_id)
	if i >= 0 {
		giveaway.entrants.delete(i)
	} else {
		giveaway.entrants << user_id
	}
	g.list[message_id.str()] = giveaway
	g.write()!
	return i < 0, giveaway
}

// finish ends a running giveaway now and returns it.
fn (mut g Giveaways) finish(message_id discord.Snowflake) !Giveaway {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	mut giveaway := g.list[message_id.str()] or { return error('that message is not a giveaway') }
	if giveaway.ended {
		return error('that giveaway is over already')
	}
	giveaway.ended = true
	g.list[message_id.str()] = giveaway
	g.write()!
	return giveaway
}

// due ends every running giveaway whose time has come and returns them.
fn (mut g Giveaways) due(now i64) ![]Giveaway {
	g.mu.lock()
	defer {
		g.mu.unlock()
	}
	mut ended := []Giveaway{}
	for _, giveaway in g.list {
		if !giveaway.ended && giveaway.ends <= now {
			ended << Giveaway{
				...giveaway
				ended: true
			}
		}
	}
	for giveaway in ended {
		g.list[giveaway.message_id.str()] = giveaway
	}
	if ended.len > 0 {
		g.write()!
	}
	return ended
}

// pick draws up to `count` different winners. crypto.rand is safe from several threads,
// unlike the default generator.
fn pick(entrants []discord.Snowflake, count int) ![]discord.Snowflake {
	mut pool := entrants.clone()
	mut winners := []discord.Snowflake{}
	for winners.len < count && pool.len > 0 {
		i := int(rand.int_u64(u64(pool.len))!)
		winners << pool[i]
		pool.delete(i)
	}
	return winners
}

fn mentions(ids []discord.Snowflake) string {
	return ids.map(formatter.user_mention(it)).join(', ')
}

fn card(g Giveaway, status string) discord.Embed {
	ends := time.unix(g.ends)
	return discord.Embed{
		title:       '🎉 ${g.prize}'
		description: '${status}\nHosted by ${formatter.user_mention(g.host_id)}'
		color:       if g.ended { discord.colors.grey } else { discord.colors.fuchsia }
		fields:      [
			discord.EmbedField{
				name:   if g.ended { 'Ended' } else { 'Ends' }
				value:  '${formatter.timestamp(ends, .relative)} (${formatter.timestamp(ends, .short_date_short_time)})'
				inline: true
			},
			discord.EmbedField{
				name:   'Winners'
				value:  g.winners.str()
				inline: true
			},
		]
	}
}

fn enter_button(g Giveaway) discord.Component {
	return discord.action_row(discord.button(
		style:     .primary
		label:     'Enter (${g.entrants.len})'
		emoji:     discord.parse_emoji('🎉')
		custom_id: 'giveaway:enter'
		disabled:  g.ended
	))
}

// draw_winners draws the winners of an ended giveaway, closes its message and congratulates
// them.
fn draw_winners(mut c veyfert.Client, g Giveaway) ! {
	winners := pick(g.entrants, g.winners)!
	status := if winners.len > 0 {
		'Winners: ${mentions(winners)}'
	} else {
		'Nobody entered, so nobody won.'
	}
	c.messages.edit(g.channel_id, g.message_id,
		embeds:     [card(g, status)]
		components: [enter_button(g)]
	)!
	if winners.len > 0 {
		c.messages.write(g.channel_id,
			content:          '🎉 Congratulations ${mentions(winners)}! You won **${g.prize}**.'
			reply_to:         g.message_id
			allowed_mentions: discord.AllowedMentions{
				users: winners
			}
		)!
	}
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'giveaway', description: 'Starts a giveaway in this channel')]
@[veyfert.Perms('manage_guild')]
struct Start {
	giveaways &Giveaways
mut:
	prize    string @[veyfert.Desc: 'What the winners get'; veyfert.MaxLength: 200]
	duration string @[veyfert.Desc: 'How long it lasts: 30m, 2h, 1d... up to 30d'; veyfert.MaxLength: 20]
	winners  ?int   @[veyfert.Desc: 'How many winners (1)'; veyfert.Max: 20; veyfert.Min: 1]
	// Not an option: check_options works it out from `duration`.
	length time.Duration
}

fn (mut s Start) check_options(mut _ veyfert.CommandContext) ! {
	s.length = parse_duration(s.duration)!
	if s.length > 30 * 24 * time.hour {
		return error('a giveaway lasts 30 days at most')
	}
}

fn (s Start) run(mut ctx veyfert.CommandContext) ! {
	channel_id := ctx.channel_id() or { return }
	g := Giveaway{
		channel_id: channel_id
		host_id:    ctx.author().id
		prize:      s.prize
		winners:    s.winners or { 1 }
		ends:       time.now().add(s.length).unix()
	}
	message := ctx.client.messages.write(channel_id,
		embeds:     [card(g, 'Press the button to enter.')]
		components: [enter_button(g)]
	)!
	mut giveaways := s.giveaways
	giveaways.add(Giveaway{
		...g
		message_id: message.id
	})!
	ctx.write(content: 'The giveaway is on: ${message.url()}', ephemeral: true)!
}

@[veyfert.CustomId('giveaway:enter')]
struct Enter {
	giveaways &Giveaways
}

fn (e Enter) run(mut ctx veyfert.ComponentContext) ! {
	message := ctx.interaction.message or { return }
	mut giveaways := e.giveaways
	entered, g := giveaways.toggle(message.id, ctx.author().id) or {
		ctx.write(content: 'Too late: ${err.msg()}.', ephemeral: true)!
		return
	}
	ctx.update(components: [enter_button(g)])! // the button shows the new count
	ctx.followup(
		content:   if entered { 'You are in. Good luck!' } else { 'You left the giveaway.' }
		ephemeral: true
	)!
}

// EndNow ends a giveaway early: right-click its message, then Apps.
@[veyfert.Contexts('guild')]
@[veyfert.MessageMenu('End giveaway')]
@[veyfert.Perms('manage_guild')]
struct EndNow {
	giveaways &Giveaways
}

fn (e EndNow) run(mut ctx veyfert.CommandContext) ! {
	message := ctx.target_message() or { return }
	mut giveaways := e.giveaways
	g := giveaways.finish(message.id) or {
		ctx.write(content: 'I cannot end it: ${err.msg()}.', ephemeral: true)!
		return
	}
	draw_winners(mut ctx.client, g)!
	ctx.write(content: 'Ended.', ephemeral: true)!
}

// Reroll draws new winners for an ended giveaway.
@[veyfert.Contexts('guild')]
@[veyfert.MessageMenu('Reroll giveaway')]
@[veyfert.Perms('manage_guild')]
struct Reroll {
	giveaways &Giveaways
}

fn (r Reroll) run(mut ctx veyfert.CommandContext) ! {
	message := ctx.target_message() or { return }
	mut giveaways := r.giveaways
	g := giveaways.get(message.id) or {
		ctx.write(content: 'That message is not a giveaway.', ephemeral: true)!
		return
	}
	if !g.ended {
		ctx.write(content: 'That giveaway is still running.', ephemeral: true)!
		return
	}
	winners := pick(g.entrants, g.winners)!
	if winners.len == 0 {
		ctx.write(content: 'Nobody entered that giveaway.', ephemeral: true)!
		return
	}
	ctx.write(
		content:          '🎉 New draw for **${g.prize}**: congratulations ${mentions(winners)}!'
		allowed_mentions: discord.AllowedMentions{
			users: winners
		}
	)!
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
	path := os.getenv_opt('GIVEAWAYS_FILE') or { 'giveaways.json' }
	mut giveaways := load_giveaways(path) or { panic('cannot read ${path}: ${err}') }
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Start{
		giveaways: giveaways
	})
	bot.commands.add(EndNow{
		giveaways: giveaways
	})
	bot.commands.add(Reroll{
		giveaways: giveaways
	})
	bot.components.add(Enter{
		giveaways: giveaways
	})
	// End the giveaways whose time has come; those that ended while the bot was off end at once.
	mut jobs := &plugins.Scheduler{}
	jobs.every(5 * time.second, fn [mut giveaways] (mut c veyfert.Client) ! {
		for g in giveaways.due(time.now().unix())! {
			draw_winners(mut c, g) or { c.logger.error('could not end the giveaway ${g.message_id}: ${err}') }
		}
	})
	bot.install(mut jobs)!
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/giveaway.json'
	)!
	bot.run()!
}
