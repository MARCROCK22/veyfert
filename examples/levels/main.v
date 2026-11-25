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

// A leveling bot: members earn XP for talking, at most once a minute, and level up. /rank
// shows a member's level and /leaderboard the top of the server. The levels are saved to a
// JSON file every minute and when the bot stops.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/levels
// LEVELS_FILE chooses the file (levels.json by default). Messages give XP without the Message
// Content intent: the bot never reads what they say.

// LevelUp is a custom event: the bot emits it, and a listener announces it.
@[discord.Event('LEVEL_UP')]
struct LevelUp {
	guild_id   discord.Snowflake
	channel_id discord.Snowflake
	user_id    discord.Snowflake
	level      int
}

// Entry is what the file keeps for each member.
struct Entry {
mut:
	xp   int
	last i64 // when a message last gave XP, in Unix seconds
}

// Levels holds every member's XP. Listeners and commands run on several threads, so a mutex
// guards it.
@[heap]
struct Levels {
	path string
mut:
	mu      &sync.Mutex = sync.new_mutex()
	entries map[string]Entry // by '<guild_id>:<user_id>'
	dirty   bool
}

fn load_levels(path string) !&Levels {
	mut levels := &Levels{
		path: path
	}
	if os.exists(path) {
		levels.entries = json2.decode[map[string]Entry](os.read_file(path)!)!
	}
	return levels
}

// save writes the levels when they changed: to a temporary file first, so that a crash while
// writing never leaves half a file.
fn (mut l Levels) save() ! {
	l.mu.lock()
	if !l.dirty {
		l.mu.unlock()
		return
	}
	text := json2.encode(l.entries)
	l.dirty = false
	l.mu.unlock()
	os.write_file('${l.path}.tmp', text)!
	os.mv('${l.path}.tmp', l.path)!
}

// gain adds `amount` XP to a member, at most once a minute, and returns their new level when
// they reached one.
fn (mut l Levels) gain(key string, now i64, amount int) ?int {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	mut entry := l.entries[key] or { Entry{} }
	if now - entry.last < 60 {
		return none
	}
	before, _ := level_of(entry.xp)
	entry.xp += amount
	entry.last = now
	l.entries[key] = entry
	l.dirty = true
	after, _ := level_of(entry.xp)
	return if after > before { after } else { none }
}

fn (mut l Levels) xp(key string) int {
	l.mu.lock()
	defer {
		l.mu.unlock()
	}
	return (l.entries[key] or { Entry{} }).xp
}

struct Ranked {
	user_id discord.Snowflake
	xp      int
}

// top returns the members of a guild by XP, the most first.
fn (mut l Levels) top(guild_id discord.Snowflake) []Ranked {
	prefix := '${guild_id}:'
	l.mu.lock()
	mut rows := []Ranked{}
	for key, entry in l.entries {
		if key.starts_with(prefix) {
			id := discord.Snowflake.parse(key.all_after(':')) or { continue }
			rows << Ranked{id, entry.xp}
		}
	}
	l.mu.unlock()
	rows.sort(a.xp > b.xp)
	return rows
}

// xp_for is the XP that `level` takes to reach the next one: 100, 155, 220...
fn xp_for(level int) int {
	return 5 * level * level + 50 * level + 100
}

// level_of splits a total of XP into the level and the XP already earned toward the next.
fn level_of(total int) (int, int) {
	mut level := 0
	mut left := total
	for left >= xp_for(level) {
		left -= xp_for(level)
		level++
	}
	return level, left
}

// bar draws how far `done` is of `total` in ten blocks.
fn bar(done int, total int) string {
	filled := if total > 0 { done * 10 / total } else { 0 }
	return '█'.repeat(filled) + '░'.repeat(10 - filled)
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'rank', description: 'Shows the level of a member')]
struct Rank {
	levels &Levels
mut:
	user ?discord.User @[veyfert.Desc: 'Whose level; yours by default']
}

fn (r Rank) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	user := r.user or { ctx.author() }
	mut levels := r.levels
	total := levels.xp('${guild_id}:${user.id}')
	level, into := level_of(total)
	rows := levels.top(guild_id)
	position := rows.map(it.user_id).index(user.id) + 1
	ctx.write(
		embeds: [
			discord.Embed{
				author:      discord.EmbedAuthor{
					name:     user.display_name()
					icon_url: user.avatar_url(size: 64)
				}
				title:       'Level ${level}'
				description: '${bar(into, xp_for(level))} ${into} / ${xp_for(level)} XP'
				color:       discord.colors.gold
				fields:      [
					discord.EmbedField{
						name:   'Total XP'
						value:  total.str()
						inline: true
					},
					discord.EmbedField{
						name:   'Rank'
						value:  if position > 0 {
							'#${position} of ${rows.len}'
						} else {
							'Not ranked yet'
						}
						inline: true
					},
				]
			},
		]
	)!
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'leaderboard', description: 'The members with the most XP')]
struct Leaderboard {
	levels &Levels
}

fn (b Leaderboard) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut levels := b.levels
	rows := levels.top(guild_id)#[..10]
	if rows.len == 0 {
		ctx.write(content: 'Nobody has XP yet. Say something!')!
		return
	}
	medals := ['🥇', '🥈', '🥉']
	mut lines := []string{}
	for i, row in rows {
		level, _ := level_of(row.xp)
		place := medals[i] or { '**${i + 1}.**' }
		lines << '${place} ${formatter.user_mention(row.user_id)}: level ${level} (${row.xp} XP)'
	}
	ctx.write(
		embeds: [
			discord.Embed{
				title:       'Leaderboard'
				description: lines.join('\n')
				color:       discord.colors.gold
			},
		]
	)!
}

fn main() {
	path := os.getenv_opt('LEVELS_FILE') or { 'levels.json' }
	mut levels := load_levels(path) or { panic('cannot read ${path}: ${err}') }
	mut bot := veyfert.new_client(
		token:   os.getenv('DISCORD_TOKEN')
		intents: .guilds | .guild_messages
	)
	bot.commands.add(Rank{
		levels: levels
	})
	bot.commands.add(Leaderboard{
		levels: levels
	})
	// Every message in a server may give 15 to 25 XP. crypto.rand is safe from several threads,
	// unlike the default generator.
	bot.on[discord.MessageCreate](fn [mut levels] (m discord.MessageCreate, mut c veyfert.Client) ! {
		guild_id := m.guild_id or { return }
		if m.author.bot {
			return
		}
		amount := 15 + int(rand.int_u64(11)!)
		if level := levels.gain('${guild_id}:${m.author.id}', time.now().unix(), amount) {
			c.emit(LevelUp{
				guild_id:   guild_id
				channel_id: m.channel_id
				user_id:    m.author.id
				level:      level
			})
		}
	})
	bot.on[LevelUp](fn (e LevelUp, mut c veyfert.Client) ! {
		c.messages.write(e.channel_id,
			content: '🎉 ${formatter.user_mention(e.user_id)} reached level ${e.level}!'
		)!
	})
	// Save every minute while the bot runs, and once more when it stops.
	mut jobs := &plugins.Scheduler{}
	jobs.every(time.minute, fn [mut levels] (mut _ veyfert.Client) ! {
		levels.save()!
	})
	bot.install(mut jobs)!
	bot.hook(.client_close, fn [mut levels] (mut _ veyfert.Client) ! {
		levels.save()!
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/levels.json'
	)!
	bot.run()!
}
