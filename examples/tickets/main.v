module main

import os
import sync
import veyfert
import veyfert.discord
import veyfert.formatter

// A ticket bot: /ticket-panel posts a button, the button opens a form, and the form opens a
// private thread with the member and the staff. Closing it posts a transcript to a log channel
// and archives the thread.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/tickets
//
// Optional settings:
//   STAFF_ROLE_ID   the role that is added to every ticket and may close any of them
//   LOG_CHANNEL_ID  where closed tickets and their transcripts go
// The bot needs Create Private Threads, Send Messages in Threads and Manage Threads where the
// panel is. Transcripts include what members wrote only with the Message Content intent enabled
// in the Developer Portal.

const staff_role_id = env_id('STAFF_ROLE_ID')
const log_channel_id = env_id('LOG_CHANNEL_ID')

fn env_id(name string) discord.Snowflake {
	return discord.Snowflake.parse(os.getenv(name)) or { discord.Snowflake{} }
}

// Tickets remembers the open ticket of each member, so nobody opens two. A restart forgets it,
// which only lets members open a new one.
@[heap]
struct Tickets {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	open map[string]discord.Snowflake // thread by '<guild_id>:<user_id>'; 0 while it is created
}

// claim reserves a ticket for a member, or returns the thread they already have.
fn (mut t Tickets) claim(key string) ?discord.Snowflake {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	if id := t.open[key] {
		return id
	}
	t.open[key] = discord.Snowflake{}
	return none
}

// thread_of returns the thread of a member's open ticket.
fn (mut t Tickets) thread_of(key string) ?discord.Snowflake {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	id := t.open[key] or { return none }
	return if id.is_zero() { none } else { id }
}

fn (mut t Tickets) set(key string, thread_id discord.Snowflake) {
	t.mu.lock()
	t.open[key] = thread_id
	t.mu.unlock()
}

fn (mut t Tickets) release(key string) {
	t.mu.lock()
	t.open.delete(key)
	t.mu.unlock()
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'ticket-panel', description: 'Posts the panel where members open tickets')]
@[veyfert.Perms('manage_guild')]
struct Panel {}

fn (p Panel) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		embeds:     [
			discord.Embed{
				title:       'Need help?'
				description: 'Press the button to open a private ticket with the staff.'
				color:       discord.colors.blurple
			},
		]
		components: [
			discord.action_row(discord.button(
				style:     .primary
				label:     'Open a ticket'
				emoji:     discord.parse_emoji('🎫')
				custom_id: 'ticket:open'
			)),
		]
	)!
}

// OpenTicket answers the panel's button with the form, unless the member has a ticket open.
@[veyfert.CustomId('ticket:open')]
struct OpenTicket {
	tickets &Tickets
}

fn (h OpenTicket) run(mut ctx veyfert.ComponentContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut tickets := h.tickets
	if existing := tickets.thread_of('${guild_id}:${ctx.author().id}') {
		ctx.write(
			content:   'You already have a ticket: ${formatter.channel_mention(existing)}'
			ephemeral: true
		)!
		return
	}
	ctx.modal(TicketForm{
		tickets: h.tickets
	})!
}

// TicketForm is the form the button opens; its fields with a Label are the inputs.
@[veyfert.Modal(custom_id: 'ticket:form', title: 'Open a ticket')]
struct TicketForm {
	tickets &Tickets
mut:
	subject string  @[veyfert.Label: 'What is it about?'; veyfert.MaxLength: 80; veyfert.Placeholder: 'I cannot see the rules channel']
	details ?string @[veyfert.Label: 'Anything else we should know?'; veyfert.MaxLength: 1000; veyfert.Paragraph]
}

fn (f TicketForm) submit(mut ctx veyfert.ModalContext) ! {
	guild_id := ctx.guild_id() or { return }
	channel_id := ctx.channel_id() or { return }
	user := ctx.author()
	key := '${guild_id}:${user.id}'
	mut tickets := f.tickets
	if existing := tickets.claim(key) {
		ctx.write(
			content:   'You already have a ticket: ${formatter.channel_mention(existing)}'
			ephemeral: true
		)!
		return
	}
	ticket := ctx.client.threads.create(channel_id, 'ticket-${user.username}',
		kind:                  12 // private: only the people added see it
		invitable:             false
		auto_archive_duration: 10080
		reason:                'Ticket of ${user.username}'
	) or {
		tickets.release(key)
		return err
	}
	tickets.set(key, ticket.id)
	ctx.client.threads.add_member(ticket.id, user.id)!
	// Mentioning the staff role adds its members to the private thread.
	has_staff := !staff_role_id.is_zero()
	staff := if has_staff { ' ${formatter.role_mention(staff_role_id)}' } else { '' }
	ctx.client.messages.write(ticket.id,
		content:          '${user.mention()} opened a ticket.${staff}'
		embeds:           [
			discord.Embed{
				title:       f.subject
				description: f.details or { 'No details.' }
				color:       discord.colors.blurple
			},
		]
		components:       [
			discord.action_row(discord.button(
				style:     .danger
				label:     'Close'
				emoji:     discord.parse_emoji('🔒')
				custom_id: 'ticket:close:${user.id}' // the owner travels in the ID
			)),
		]
		allowed_mentions: discord.AllowedMentions{
			users: [user.id]
			roles: if has_staff { [staff_role_id] } else { [] }
		}
	)!
	ctx.write(
		content:   'Your ticket is open: ${formatter.channel_mention(ticket.id)}'
		ephemeral: true
	)!
}

// OwnerOrStaff lets through the member who opened the ticket, the staff role, and members who
// manage threads.
struct OwnerOrStaff {}

fn (mut g OwnerOrStaff) check_handler(mut ctx veyfert.InteractionContext) ! {
	member := ctx.member() or { return veyfert.deny('Tickets live in servers.') }
	data := ctx.interaction.data or { return veyfert.deny('This is not a button.') }
	owner := (data.custom_id or { '' }).all_after_last(':')
	perms := discord.Permissions.parse(member.permissions or { '0' })
	if ctx.author().id.str() == owner || staff_role_id in member.roles
		|| perms.has(.manage_threads) || perms.has(.administrator) {
		return
	}
	return veyfert.deny('Only the member who opened this ticket and the staff can close it.')
}

@[veyfert.CustomIdPrefix('ticket:close:')]
struct CloseTicket {
	tickets &Tickets
mut:
	guard OwnerOrStaff // a field whose type has check_handler runs before `run`
}

fn (h CloseTicket) run(mut ctx veyfert.ComponentContext) ! {
	guild_id := ctx.guild_id() or { return }
	thread_id := ctx.channel_id() or { return }
	owner := discord.Snowflake.parse(ctx.custom_id.all_after_last(':'))!
	closer := ctx.author()
	ctx.update(components: [])! // the answer to the click: the button goes away
	ctx.client.messages.write(thread_id, content: '🔒 Closed by ${closer.username}.')!
	if !log_channel_id.is_zero() {
		ctx.client.messages.write(log_channel_id,
			embeds: [
				discord.Embed{
					title:       'Ticket closed'
					description: 'Opened by ${formatter.user_mention(owner)}, closed by ${closer.mention()}.'
					color:       discord.colors.grey
				},
			]
			files:  [transcript(mut ctx.client, thread_id)!]
		)!
	}
	mut tickets := h.tickets
	tickets.release('${guild_id}:${owner}')
	ctx.client.threads.edit(thread_id,
		archived: true
		locked:   true
		reason:   'Ticket closed by ${closer.username}'
	)!
}

// transcript is the thread's last 100 messages as text, oldest first.
fn transcript(mut c veyfert.Client, thread_id discord.Snowflake) !discord.File {
	mut messages := c.messages.list(thread_id, limit: 100)!
	messages.reverse_in_place()
	lines := messages.map('[${it.timestamp#[..16].replace('T', ' ')}] ${it.author.username}: ${it.content}')
	return discord.File{
		name:         'transcript-${thread_id}.txt'
		data:         lines.join('\n').bytes()
		content_type: 'text/plain'
	}
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	tickets := &Tickets{}
	bot.commands.add(Panel{})
	bot.components.add(OpenTicket{
		tickets: tickets
	})
	bot.components.add(CloseTicket{
		tickets: tickets
	})
	bot.modals.add(TicketForm{
		tickets: tickets
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/tickets.json'
	)!
	bot.run()!
}
