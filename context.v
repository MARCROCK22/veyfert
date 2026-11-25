module veyfert

import json2
import veyfert.discord

// InteractionContext answers one interaction. Command, component and modal contexts embed it.
@[heap]
pub struct InteractionContext {
pub:
	interaction discord.Interaction
	// message is the message that ran a prefix command. Then `interaction` is built from it,
	// and answers are messages in its channel: replies, edits and deletes.
	message ?discord.Message
pub mut:
	client &Client = unsafe { nil }
mut:
	replied  bool
	deferred bool
	inline   &InlineReply = unsafe { nil } // set for interactions received over HTTP
	response ?discord.Message // the answer to a prefix command
}

// CommandContext is what a command's `run` receives. Its answer methods come from
// InteractionContext.
@[heap]
pub struct CommandContext {
	InteractionContext
pub:
	path string // the command path, such as 'config mod ban'
mut:
	outcome string // for command observers; '' while it goes well
	failure string
}

// MessageOptions is the content of a message: an interaction answer, a followup or an edit.
// In an edit, `none` leaves a part as it is and an empty list removes it.
@[params]
pub struct MessageOptions {
pub:
	content          ?string
	embeds           ?[]discord.Embed
	components       ?[]discord.Component // components v2 set message_flag_components_v2 for you
	files            []discord.File
	poll             ?discord.Poll
	allowed_mentions ?discord.AllowedMentions
	ephemeral        bool // only the author sees it; answers and followups only
	tts              bool
	flags            int                // more message flags, such as message_flag_suppress_embeds
	reply_to         ?discord.Snowflake // the message this one replies to, in the same channel
}

struct MessagePayload {
	content           ?string
	embeds            ?[]discord.Embed
	components        ?[]discord.Component
	poll              ?discord.Poll
	allowed_mentions  ?discord.AllowedMentions
	tts               ?bool
	flags             ?int
	message_reference ?discord.MessageReference
}

struct Callback[T] {
	kind int @[json: 'type']
	data T
}

fn message_payload(opts MessageOptions) !MessagePayload {
	for e in opts.embeds or { []discord.Embed{} } {
		e.validate()!
	}
	mut flags := opts.flags
	if opts.ephemeral {
		flags |= discord.message_flag_ephemeral
	}
	if components := opts.components {
		if components.any(it.kind != .action_row) {
			flags |= discord.message_flag_components_v2
		}
	}
	return MessagePayload{
		content:           opts.content
		embeds:            opts.embeds
		components:        opts.components
		poll:              opts.poll
		allowed_mentions:  opts.allowed_mentions
		tts:               if opts.tts { true } else { none }
		message_reference: if id := opts.reply_to {
			discord.MessageReference{
				message_id:         id
				fail_if_not_exists: false
			}
		} else {
			none
		}
		flags:             if flags != 0 { flags } else { none }
	}
}

// author is the user who triggered the interaction, in a guild or in DMs.
pub fn (ctx &InteractionContext) author() discord.User {
	return interaction_user(ctx.interaction)
}

pub fn (ctx &InteractionContext) guild_id() ?discord.Snowflake {
	return ctx.interaction.guild_id
}

pub fn (ctx &InteractionContext) channel_id() ?discord.Snowflake {
	return ctx.interaction.channel_id
}

// resolved holds the users, roles, channels, attachments and messages the interaction points to.
pub fn (ctx &InteractionContext) resolved() discord.Resolved {
	data := ctx.interaction.data or { return discord.Resolved{} }
	return data.resolved or { discord.Resolved{} }
}

// target_user is the user a user command was used on.
pub fn (ctx &InteractionContext) target_user() ?discord.User {
	data := ctx.interaction.data or { return none }
	id := data.target_id or { return none }
	return ctx.resolved().users[id.str()] or { return none }
}

// target_message is the message a message command was used on.
pub fn (ctx &InteractionContext) target_message() ?discord.Message {
	data := ctx.interaction.data or { return none }
	id := data.target_id or { return none }
	return ctx.resolved().messages[id.str()] or { return none }
}

fn (mut ctx InteractionContext) callback[T](kind int, data T, files []discord.File) ! {
	body := json2.encode(Callback[T]{ kind: kind, data: data })
	if !isnil(ctx.inline) {
		if ctx.inline.answer(body, files) {
			return
		}
		// The HTTP response already deferred the interaction: an answer edits that defer.
		match kind {
			4, 7 {
				ctx.client.rest.request(.patch, '${ctx.webhook_path()}/messages/@original',
					body:  json2.encode(data)
					files: files
				)!
			}
			5, 6 {}
			else {
				return error('veyfert: too late for this answer; the HTTP response deferred the interaction')
			}
		}
		return
	}
	ctx.client.rest.request(.post,
		'/interactions/${ctx.interaction.id}/${ctx.interaction.token}/callback',
		body:  body
		files: files
	)!
}

fn (ctx &InteractionContext) webhook_path() string {
	return '/webhooks/${ctx.interaction.application_id}/${ctx.interaction.token}'
}

// write answers the interaction with a message. It can answer once; then use `followup`,
// `edit_response` or `edit_or_reply`.
pub fn (mut ctx InteractionContext) write(opts MessageOptions) ! {
	if ctx.replied {
		return error('veyfert: this interaction was already answered; use followup or edit_response')
	}
	if msg := ctx.message {
		ctx.response = ctx.client.messages.write(msg.channel_id, MessageOptions{
			...opts
			ephemeral: false
			reply_to:  msg.id
		})!
	} else {
		ctx.callback(4, message_payload(opts)!, opts.files)!
	}
	ctx.replied = true
}

struct NoData {}

// launch_activity answers by launching the app's Activity, which needs Activities enabled for
// the app. Entry point commands with @[AppHandler] answer this way.
pub fn (mut ctx InteractionContext) launch_activity() ! {
	if ctx.message != none {
		return error('veyfert: a prefix command cannot answer with this; it has no interaction')
	}
	if ctx.replied {
		return error('veyfert: this interaction was already answered')
	}
	ctx.callback(12, NoData{}, [])!
	ctx.replied = true
}

// defer_reply buys up to 15 minutes; Discord shows a loading state until `edit_response`.
pub fn (mut ctx InteractionContext) defer_reply(ephemeral bool) ! {
	if ctx.replied {
		return error('veyfert: this interaction was already answered')
	}
	if msg := ctx.message {
		ctx.client.channels.typing(msg.channel_id)!
	} else {
		ctx.callback(5, MessagePayload{ flags: if ephemeral { 64 } else { none } }, [])!
	}
	ctx.replied = true
	ctx.deferred = true
}

pub fn (mut ctx InteractionContext) edit_response(opts MessageOptions) !discord.Message {
	if msg := ctx.message {
		if response := ctx.response {
			ctx.response = ctx.client.messages.edit(response.channel_id, response.id, opts)!
		} else {
			// A deferred prefix command has no message yet: its first edit sends it.
			ctx.response = ctx.client.messages.write(msg.channel_id, MessageOptions{
				...opts
				ephemeral: false
				reply_to:  msg.id
			})!
		}
		return ctx.response or { discord.Message{} }
	}
	text := ctx.client.rest.request(.patch, '${ctx.webhook_path()}/messages/@original',
		body:  json2.encode(message_payload(opts)!)
		files: opts.files
	)!
	return json2.decode[discord.Message](text)!
}

pub fn (mut ctx InteractionContext) delete_response() ! {
	if ctx.message != none {
		response := ctx.response or { return }
		ctx.client.messages.delete(response.channel_id, response.id, '')!
		ctx.response = none
		return
	}
	ctx.client.rest.request(.delete, '${ctx.webhook_path()}/messages/@original')!
}

pub fn (mut ctx InteractionContext) fetch_response() !discord.Message {
	if ctx.message != none {
		response := ctx.response or { return error('veyfert: this command has not answered yet') }
		return ctx.client.messages.fetch(response.channel_id, response.id, force: true)
	}
	return json2.decode[discord.Message](ctx.client.rest.request(.get, '${ctx.webhook_path()}/messages/@original')!)!
}

// followup sends another message after the first answer.
pub fn (mut ctx InteractionContext) followup(opts MessageOptions) !discord.Message {
	if msg := ctx.message {
		return ctx.client.messages.write(msg.channel_id, MessageOptions{
			...opts
			ephemeral: false
		})
	}
	text := ctx.client.rest.request(.post, ctx.webhook_path(),
		body:  json2.encode(message_payload(opts)!)
		query: 'wait=true'
		files: opts.files
	)!
	return json2.decode[discord.Message](text)!
}

// edit_or_reply edits the answer when there is one, and answers otherwise.
pub fn (mut ctx InteractionContext) edit_or_reply(opts MessageOptions) ! {
	if ctx.replied {
		ctx.edit_response(opts)!
	} else {
		ctx.write(opts)!
	}
}

// reply_error tells the user, privately, that something failed: in the answer when there is
// none yet or it was deferred, in a followup otherwise.
fn (mut ctx InteractionContext) reply_error(text string) ! {
	if ctx.deferred {
		ctx.edit_response(content: text)!
	} else if ctx.replied {
		ctx.followup(content: text, ephemeral: true)!
	} else {
		ctx.write(content: text, ephemeral: true)!
	}
}

// member is the member who triggered the interaction; none outside servers.
pub fn (ctx &InteractionContext) member() ?discord.Member {
	return ctx.interaction.member
}

// AutocompleteContext is what a command's `autocomplete` method receives while a user types
// in an option marked with @[veyfert.Autocomplete].
@[heap]
pub struct AutocompleteContext {
	InteractionContext
pub:
	path    string
	focused string                      // the option the user is typing in
	value   string                      // what the user typed so far
	options []discord.InteractionOption // every option of the command, as typed so far
}

struct AutocompleteData {
	choices []Choice
}

// respond shows up to 25 suggestions.
pub fn (mut ctx AutocompleteContext) respond(choices []Choice) ! {
	ctx.callback(8, AutocompleteData{ choices: choices#[..25] }, [])!
	ctx.replied = true
}
