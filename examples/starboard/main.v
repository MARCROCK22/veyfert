module main

import os
import sync
import veyfert
import veyfert.discord
import veyfert.formatter

// A starboard: when a message gets enough ⭐ reactions, the bot reposts it in a starboard
// channel and keeps its count up to date as stars come and go; the author's own star does not
// count. It keeps no files: each post carries the ID of its message in the footer, and after a
// restart the bot finds its posts in the channel again.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... STARBOARD_CHANNEL_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/starboard
// STAR_THRESHOLD sets how many stars a message needs (3), and STAR_EMOJI the emoji (⭐).
// The text of starred messages needs the Message Content intent, enabled in the Developer
// Portal; without it, posts show the author, the images and the link.

const starboard_id = discord.Snowflake.parse(os.getenv('STARBOARD_CHANNEL_ID')) or {
	discord.Snowflake{}
}
const threshold = env_int('STAR_THRESHOLD', 3)
const star = discord.parse_emoji(os.getenv_opt('STAR_EMOJI') or { '⭐' })

fn env_int(name string, default int) int {
	n := os.getenv(name).int()
	return if n > 0 { n } else { default }
}

// Board remembers the starboard post of each starred message.
@[heap]
struct Board {
mut:
	// ponytail: one lock for every message, so two stars never post twice; a lock per message
	// if a busy server makes updates wait.
	mu    &sync.Mutex = sync.new_mutex()
	posts map[u64]discord.Snowflake // post by starred message ID
}

fn footer(message_id discord.Snowflake) string {
	return 'ID ${message_id}'
}

// find returns the post of a message: remembered, or found by its footer among the last 100
// posts of the starboard, as after a restart.
fn (mut b Board) find(mut c veyfert.Client, message_id discord.Snowflake) ?discord.Snowflake {
	if id := b.posts[message_id.value] {
		return id
	}
	for post in c.messages.list(starboard_id, limit: 100) or { return none } {
		for embed in post.embeds {
			if (embed.footer or { continue }).text == footer(message_id) {
				b.posts[message_id.value] = post.id
				return post.id
			}
		}
	}
	return none
}

// card is the embed that reposts a message: its author, text, first image and a link to it.
fn card(m discord.Message) discord.Embed {
	images := m.attachments.filter((it.content_type or { '' }).starts_with('image/'))
	return discord.Embed{
		author:      discord.EmbedAuthor{
			name:     m.author.display_name()
			icon_url: m.author.avatar_url(size: 64)
		}
		description: if m.content != '' { m.content } else { none }
		image:       if images.len > 0 {
			discord.Media{
				url: images[0].url
			}
		} else {
			none
		}
		fields:      [
			discord.EmbedField{
				name:  'Original'
				value: formatter.hyperlink('Jump to the message', m.url())
			},
		]
		color:       discord.colors.gold
		footer:      discord.EmbedFooter{
			text: footer(m.id)
		}
		timestamp:   m.timestamp
	}
}

// update counts the stars of a message, then creates, edits or deletes its post.
fn update(mut board Board, mut c veyfert.Client, channel_id discord.Snowflake, message_id discord.Snowflake) ! {
	if channel_id == starboard_id {
		return
	}
	board.mu.lock()
	defer {
		board.mu.unlock()
	}
	message := c.messages.fetch(channel_id, message_id)!
	if message.author.bot {
		return
	}
	voters := c.reactions.list(channel_id, message_id, star.reaction())!
	stars := voters.filter(it.id != message.author.id).len
	if stars < threshold {
		// Only remembered posts go: looking for others on every reaction would cost a request each.
		if id := board.posts[message_id.value] {
			c.messages.delete(starboard_id, id, 'Fewer stars than ${threshold}')!
			board.posts.delete(message_id.value)
		}
		return
	}
	header := '${star.mention()} **${stars}** in ${formatter.channel_mention(channel_id)}'
	if id := board.find(mut c, message_id) {
		c.messages.edit(starboard_id, id, content: header)!
		return
	}
	post := c.messages.write(starboard_id,
		content:          header
		embeds:           [card(message)]
		allowed_mentions: discord.AllowedMentions{
			parse: []
		}
	)!
	board.posts[message_id.value] = post.id
}

fn main() {
	if starboard_id.is_zero() {
		eprintln('Set STARBOARD_CHANNEL_ID to the channel where starred messages go.')
		exit(1)
	}
	mut bot := veyfert.new_client(
		token:   os.getenv('DISCORD_TOKEN')
		intents: .guilds | .guild_messages | .guild_message_reactions
	)
	mut board := &Board{}
	bot.on[discord.MessageReactionAdd](fn [mut board] (e discord.MessageReactionAdd, mut c veyfert.Client) ! {
		if e.emoji.reaction() == star.reaction() {
			update(mut board, mut c, e.channel_id, e.message_id)!
		}
	})
	bot.on[discord.MessageReactionRemove](fn [mut board] (e discord.MessageReactionRemove, mut c veyfert.Client) ! {
		if e.emoji.reaction() == star.reaction() {
			update(mut board, mut c, e.channel_id, e.message_id)!
		}
	})
	// A moderator may clear the stars, or every reaction, at once.
	bot.on[discord.MessageReactionRemoveEmoji](fn [mut board] (e discord.MessageReactionRemoveEmoji, mut c veyfert.Client) ! {
		if e.emoji.reaction() == star.reaction() {
			update(mut board, mut c, e.channel_id, e.message_id)!
		}
	})
	bot.on[discord.MessageReactionRemoveAll](fn [mut board] (e discord.MessageReactionRemoveAll, mut c veyfert.Client) ! {
		update(mut board, mut c, e.channel_id, e.message_id)!
	})
	bot.run()!
}
