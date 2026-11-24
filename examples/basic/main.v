module main

import os
import time
import veyfert
import veyfert.discord

// Build from the repo root, adding the folder that contains this checkout to the module path:
//   v -path "@vlib|@vmodules|<parent of veyfert>" run examples/basic
// Set DISCORD_TOKEN, and GUILD_ID to a test server so command changes apply at once.

@[veyfert.Declare(name: 'ping', description: 'Replies with the gateway latency')]
struct Ping {}

fn (c Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong! Gateway latency: ${ctx.client.latency().milliseconds()} ms')!
}

enum Order {
	alphabetical  @[veyfert.Label: 'Alphabetical']
	reverse       @[veyfert.Label: 'Reverse alphabetical']
}

struct Catalog {
	items []string
}

@[veyfert.Declare(name: 'search', description: 'Searches a test catalog')]
struct Search {
	catalog &Catalog // no attribute: a dependency, which travels with the prototype
mut:
	// A field whose type is a guard runs before `run`, and `run` sees its state.
	cd    veyfert.Cooldown = veyfert.cooldown(3, 20 * time.second)
	text  string @[veyfert.Autocomplete; veyfert.Desc: 'What to look for'; veyfert.MaxLength: 30]
	limit ?int   @[veyfert.Desc: 'How many results at most'; veyfert.Max: 10; veyfert.Min: 1]
	order ?Order @[veyfert.Desc: 'How to sort the results']
}

fn (c Search) run(mut ctx veyfert.CommandContext) ! {
	mut hits := c.catalog.items.filter(it.contains(c.text.to_lower()))
	hits.sort()
	if c.order or { Order.alphabetical } == .reverse {
		hits.reverse_in_place()
	}
	hits = hits#[..c.limit or { 5 }]
	ctx.write(
		embeds: [
			discord.Embed{
				title:       'Results for "${c.text}" (${c.cd.remaining} searches left)'
				description: if hits.len > 0 {
					hits.map('• ${it}').join('\n')
				} else {
					'No results'
				}
				color:       0x5865F2
			},
		]
	)!
}

// autocomplete suggests catalog entries while the user types.
fn (c Search) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	ctx.respond(c.catalog.items.filter(it.contains(ctx.value.to_lower())).map(veyfert.Choice{
		name:  it
		value: it
	}))!
}

@[veyfert.Declare(name: 'me', description: 'Asks the gateway for your member and shows what arrives')]
struct Me {}

fn (c Me) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.interaction.guild_id or { return error('this only works in servers') }
	author := ctx.author()
	members := ctx.client.request_members(
		guild_id: guild_id
		user_ids: [author.id]
		timeout:  2 * time.second
	)!
	member := members[0] or { return error('the gateway did not return the member') }
	nick := member.nick or { author.global_name or { author.username } }
	ctx.write(
		content: 'Shard ${ctx.client.shard_id_for(guild_id)}: ${nick}, with ${member.roles.len} roles'
	)!
}

// Anyone can use it: this is a test bot.
@[veyfert.Declare(name: 'reconnect', description: 'Drops the shard connection to check that it resumes')]
struct Reconnect {}

fn (c Reconnect) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.interaction.guild_id or { return error('this only works in servers') }
	shard := ctx.client.shard_id_for(guild_id)
	ctx.write(content: 'Dropping the connection of shard ${shard}; it should resume its session.')!
	ctx.client.reconnect(shard)!
}

// /config is a tree: `config greeting`, and the group `config mod` with `warn`.
@[veyfert.Declare(name: 'greeting', description: 'Changes the server greeting')]
struct Greeting {
mut:
	text string @[veyfert.Desc: 'The new greeting'; veyfert.MaxLength: 100; veyfert.MinLength: 2]
}

fn (c Greeting) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Greeting changed to "${c.text}" (in ${ctx.path})', ephemeral: true)!
}

@[veyfert.Declare(name: 'warn', description: 'Warns a member')]
struct Warn {
mut:
	member  discord.Member   @[veyfert.Desc: 'Who to warn']
	reason  ?string          @[veyfert.Desc: 'Why']
	channel ?discord.Channel @[veyfert.Channels: 'guild_text'; veyfert.Desc: 'Where to warn them']
}

fn (c Warn) run(mut ctx veyfert.CommandContext) ! {
	user := c.member.user or { discord.User{} }
	place := if ch := c.channel { ' in #${ch.name or { '?' }}' } else { '' }
	ctx.write(
		content: '${user.username} (${c.member.roles.len} roles) would get a warning${place}: ${c.reason or { 'no reason given' }}'
	)!
}

@[veyfert.Declare(name: 'mod', description: 'Moderation')]
struct Mod {
mut:
	// A guard on a group runs before each subcommand of the group.
	perms veyfert.RequirePermissions = veyfert.require_permissions(.manage_messages)
	warn  Warn @[veyfert.Sub]
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'config', description: 'Server settings')]
struct Config {
mut:
	greeting Greeting @[veyfert.Sub]
	mod      Mod      @[veyfert.Sub]
}

@[veyfert.Declare(name: 'slow', description: 'Defers the answer, edits it, then sends a followup')]
struct Slow {}

fn (c Slow) run(mut ctx veyfert.CommandContext) ! {
	ctx.defer_reply(false)!
	time.sleep(2 * time.second)
	ctx.edit_response(content: 'Done after 2 s of work.')!
	ctx.followup(content: 'And this is a followup only you can see.', ephemeral: true)!
}

@[veyfert.UserMenu('Show avatar')]
struct ShowAvatar {}

fn (c ShowAvatar) run(mut ctx veyfert.CommandContext) ! {
	user := ctx.target_user() or { return error('no user') }
	ctx.write(content: '${user.username}: ${user.avatar_url(size: 256)}', ephemeral: true)!
}

@[veyfert.MessageMenu('Count words')]
struct CountWords {}

fn (c CountWords) run(mut ctx veyfert.CommandContext) ! {
	msg := ctx.target_message() or { return error('no message') }
	ctx.write(content: 'That message has ${msg.content.fields().len} words.', ephemeral: true)!
}

fn main() {
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		intents:  .guilds | .guild_messages
		// The same commands run from messages: `!ping`, or `@bot ping` without MESSAGE_CONTENT.
		prefixes: ['!']
		presence: discord.Presence{
			activities: [discord.Activity{
				name: 'commands in V'
				kind: .listening
			}]
		}
	)
	catalog := &Catalog{
		items: ['vlang', 'v-analyzer', 'vpm', 'veb', 'vsl', 'vtl', 'discord', 'seyfert', 'veyfert']
	}
	bot.commands.add(Ping{})
	bot.commands.add(Search{ catalog: catalog })
	bot.commands.add(Me{})
	bot.commands.add(Reconnect{})
	bot.commands.add(Config{})
	bot.commands.add(Slow{})
	bot.commands.add(ShowAvatar{})
	bot.commands.add(CountWords{})
	bot.on[veyfert.GuildsReady](fn (e veyfert.GuildsReady, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard}: ${e.guilds} guilds loaded')
	})
	bot.on[veyfert.BotReady](fn (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('Ready as ${e.user.username} with ${e.shards} shard(s)')
	})
	bot.on[veyfert.ShardDisconnect](fn (e veyfert.ShardDisconnect, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard} disconnected (${e.code}); resuming: ${e.resumable}')
	})
	bot.on[veyfert.ShardReconnect](fn (e veyfert.ShardReconnect, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard} is back; session resumed: ${e.resumed}')
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/commands.json'
	)!
	bot.run()!
}
