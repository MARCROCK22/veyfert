module main

import json2
import os
import sync
import time
import veyfert
import veyfert.discord
import veyfert.formatter
import veyfert.plugins

// A reminders bot: `/remind when:1h30m what:stretch` reminds you in the same channel, or by DM
// when it cannot write there. /reminders list shows yours and /reminders cancel removes one,
// suggesting them as you type. Reminders are kept in a JSON file, so a restart keeps them.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/reminders
// REMINDERS_FILE chooses the file (reminders.json by default).

const max_per_user = 25

struct Reminder {
	id         int
	user_id    discord.Snowflake
	channel_id discord.Snowflake
	due        i64 // Unix seconds
	text       string
}

// Saved is what the file keeps: the reminders, and the next ID to hand out.
struct Saved {
mut:
	next_id int = 1
	list    []Reminder
}

// Reminders holds every pending reminder. Commands and the delivery job run on different
// threads, so a mutex guards it, and every change is written to the file while it is held, in
// order.
@[heap]
struct Reminders {
	path string
mut:
	mu    &sync.Mutex = sync.new_mutex()
	saved Saved
}

fn load_reminders(path string) !&Reminders {
	mut r := &Reminders{
		path: path
	}
	if os.exists(path) {
		r.saved = json2.decode[Saved](os.read_file(path)!)!
	}
	return r
}

// write saves the reminders through a temporary file, so a crash never leaves half a file.
// The caller holds the mutex.
fn (r &Reminders) write() ! {
	os.write_file('${r.path}.tmp', json2.encode(r.saved))!
	os.mv('${r.path}.tmp', r.path)!
}

fn (mut r Reminders) add(user_id discord.Snowflake, channel_id discord.Snowflake, due i64, text string) !Reminder {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	if r.saved.list.filter(it.user_id == user_id).len >= max_per_user {
		return error('you have ${max_per_user} reminders already; cancel one first')
	}
	reminder := Reminder{
		id:         r.saved.next_id
		user_id:    user_id
		channel_id: channel_id
		due:        due
		text:       text
	}
	r.saved.next_id++
	r.saved.list << reminder
	r.write()!
	return reminder
}

// of returns a user's reminders, the soonest first.
fn (mut r Reminders) of(user_id discord.Snowflake) []Reminder {
	r.mu.lock()
	mut mine := r.saved.list.filter(it.user_id == user_id)
	r.mu.unlock()
	mine.sort(a.due < b.due)
	return mine
}

// cancel removes a user's reminder and tells whether there was one.
fn (mut r Reminders) cancel(user_id discord.Snowflake, id int) !bool {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	before := r.saved.list.len
	r.saved.list = r.saved.list.filter(!(it.id == id && it.user_id == user_id))
	if r.saved.list.len == before {
		return false
	}
	r.write()!
	return true
}

// take_due removes and returns the reminders whose time has come.
fn (mut r Reminders) take_due(now i64) ![]Reminder {
	r.mu.lock()
	defer {
		r.mu.unlock()
	}
	due := r.saved.list.filter(it.due <= now)
	if due.len > 0 {
		r.saved.list = r.saved.list.filter(it.due > now)
		r.write()!
	}
	return due
}

// deliver sends the reminders that are due: in their channel, or by DM when the bot cannot
// write there any more.
fn deliver(mut reminders Reminders, mut c veyfert.Client) ! {
	for r in reminders.take_due(time.now().unix())! {
		text := '⏰ ${formatter.user_mention(r.user_id)}, you asked me to remind you: ${r.text}'
		c.messages.write(r.channel_id,
			content:          text
			allowed_mentions: discord.AllowedMentions{
				users: [r.user_id]
			}
		) or {
			c.users.write(r.user_id, content: text) or {
				c.logger.warn('could not deliver reminder ${r.id}: ${err}')
			}
		}
	}
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

// left writes the time until `due` for places that show no timestamps, such as autocomplete
// suggestions.
fn left(due i64, now i64) string {
	s := due - now
	return if s < 60 {
		'in less than a minute'
	} else if s < 3600 {
		'in ${s / 60}m'
	} else if s < 86400 {
		'in ${s / 3600}h ${s % 3600 / 60}m'
	} else {
		'in ${s / 86400}d ${s % 86400 / 3600}h'
	}
}

// clip shortens a text to `n` characters, never in the middle of one.
fn clip(text string, n int) string {
	runes := text.runes()
	return if runes.len <= n { text } else { runes[..n - 1].string() + '…' }
}

@[veyfert.Declare(name: 'remind', description: 'Reminds you of something later')]
struct Remind {
	reminders &Reminders
mut:
	when string @[veyfert.Desc: 'In how long: 10m, 2h, 1d12h... up to a year'; veyfert.MaxLength: 20]
	what string @[veyfert.Desc: 'What to remind you of'; veyfert.MaxLength: 1000]
	// Not an option: check_options works it out from `when`.
	wait time.Duration
}

fn (mut r Remind) check_options(mut _ veyfert.CommandContext) ! {
	r.wait = parse_duration(r.when)!
	if r.wait > 365 * 24 * time.hour {
		return error('a reminder can wait a year at most')
	}
}

fn (r Remind) run(mut ctx veyfert.CommandContext) ! {
	channel_id := ctx.channel_id() or { return }
	due := time.now().add(r.wait)
	mut reminders := r.reminders
	reminder := reminders.add(ctx.author().id, channel_id, due.unix(), r.what) or {
		ctx.write(content: 'I cannot: ${err.msg()}.', ephemeral: true)!
		return
	}
	ctx.write(
		content:   '⏰ I will remind you ${formatter.timestamp(due, .relative)} (reminder #${reminder.id}).'
		ephemeral: true
	)!
}

@[veyfert.Declare(name: 'list', description: 'Lists your reminders')]
struct ListReminders {
	reminders &Reminders
}

fn (l ListReminders) run(mut ctx veyfert.CommandContext) ! {
	mut reminders := l.reminders
	mine := reminders.of(ctx.author().id)
	if mine.len == 0 {
		ctx.write(content: 'You have no reminders. Set one with /remind.', ephemeral: true)!
		return
	}
	lines := mine.map('**#${it.id}** ${formatter.timestamp(time.unix(it.due), .relative)}: ${clip(it.text, 100)}')
	ctx.write(
		embeds:    [
			discord.Embed{
				title:       'Your reminders'
				description: lines.join('\n')
				color:       discord.colors.blurple
			},
		]
		ephemeral: true
	)!
}

@[veyfert.Declare(name: 'cancel', description: 'Cancels one of your reminders')]
struct CancelReminder {
	reminders &Reminders
mut:
	id int @[veyfert.Autocomplete; veyfert.Desc: 'Which reminder']
}

fn (c CancelReminder) run(mut ctx veyfert.CommandContext) ! {
	mut reminders := c.reminders
	text := if reminders.cancel(ctx.author().id, c.id)! {
		'Reminder #${c.id} is cancelled.'
	} else {
		'You have no reminder #${c.id}.'
	}
	ctx.write(content: text, ephemeral: true)!
}

// autocomplete suggests the user's reminders whose ID or text matches what they typed.
fn (c CancelReminder) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	mut reminders := c.reminders
	now := time.now().unix()
	typed := ctx.value.to_lower()
	mut choices := []veyfert.Choice{}
	for r in reminders.of(ctx.author().id) {
		if typed == '' || r.id.str().starts_with(typed) || r.text.to_lower().contains(typed) {
			choices << veyfert.Choice{
				name:  clip('#${r.id} ${left(r.due, now)}: ${r.text}', 100)
				value: r.id
			}
		}
	}
	ctx.respond(choices)!
}

@[veyfert.Declare(name: 'reminders', description: 'Your reminders')]
struct RemindersCommand {
mut:
	list   ListReminders  @[veyfert.Sub]
	cancel CancelReminder @[veyfert.Sub]
}

fn main() {
	path := os.getenv_opt('REMINDERS_FILE') or { 'reminders.json' }
	mut reminders := load_reminders(path) or { panic('cannot read ${path}: ${err}') }
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Remind{
		reminders: reminders
	})
	bot.commands.add(RemindersCommand{
		list:   ListReminders{
			reminders: reminders
		}
		cancel: CancelReminder{
			reminders: reminders
		}
	})
	// Look for due reminders every five seconds. Those that came due while the bot was off go
	// out at once.
	mut jobs := &plugins.Scheduler{}
	jobs.every(5 * time.second, fn [mut reminders] (mut c veyfert.Client) ! {
		deliver(mut reminders, mut c)!
	})
	bot.install(mut jobs)!
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/reminders.json'
	)!
	bot.run()!
}
