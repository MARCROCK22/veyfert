module testing

import json2
import veyfert.discord

// The payloads come from user 7 ("ana"), a member of guild 30 with no roles or permissions, in
// channel 300, where the bot has every permission, the way Discord sends them. Each builder
// takes `From` to change who sends it and the permissions involved.

// From is who sends a payload. By default it is ana, and the bot has every permission in the
// channel, so commands with @[BotPerms] run; lower `bot_permissions` to test the refusal.
@[params]
pub struct From {
pub:
	user_id            string = '7'
	username           string = 'ana'
	roles              []string // the member's role IDs
	member_permissions discord.Permissions = discord.no_permissions()  // the member's, in the channel
	bot_permissions    discord.Permissions = discord.all_permissions() // the bot's, in the channel
}

fn (f From) user() string {
	return '{"id":"${f.user_id}","username":${json2.encode(f.username)}}'
}

// interaction wraps `body`, the interaction's data and, for components, its message, with the
// place, the member and the permissions of `from`.
fn interaction(id int, kind int, body string, from From) string {
	return '{"id":"${id}","application_id":"1","type":${kind},"token":"token","guild_id":"30","channel_id":"300","member":{"user":${from.user()},"roles":${json2.encode(from.roles)},"permissions":"${from.member_permissions.wire()}"},"app_permissions":"${from.bot_permissions.wire()}","locale":"en-US",${body}}'
}

// command_interaction is a slash command; `options` is the JSON array of its options, such as
// '[{"name":"text","type":3,"value":"hi"}]'.
pub fn command_interaction(name string, options string, from From) string {
	return interaction(100, 2, '"data":{"id":"5","name":"${name}","type":1,"options":${options}}',
		from)
}

// component_interaction is a click, or a pick of `values`, on a component of message 200.
pub fn component_interaction(custom_id string, values []string, from From) string {
	return interaction(101, 3, '"message":{"id":"200","channel_id":"300","author":{"id":"1","username":"bot"},"content":"","timestamp":""},"data":{"custom_id":"${custom_id}","component_type":2,"values":${json2.encode(values)}}',
		from)
}

// modal_submit is a modal sent with `values`, input custom_id to text.
pub fn modal_submit(custom_id string, values map[string]string, from From) string {
	mut inputs := []string{}
	for id, value in values {
		inputs << '{"type":18,"component":{"type":4,"custom_id":"${id}","value":${json2.encode(value)}}}'
	}
	return interaction(102, 5, '"data":{"custom_id":"${custom_id}","components":[${inputs.join(',')}]}',
		from)
}

// autocomplete_interaction is someone typing in an option with autocomplete. `options` is the
// JSON array of the options so far, with `"focused":true` on the one being typed, such as
// '[{"name":"text","type":3,"value":"ru","focused":true}]'.
pub fn autocomplete_interaction(name string, options string, from From) string {
	return interaction(103, 4, '"data":{"id":"5","name":"${name}","type":1,"options":${options}}',
		from)
}

struct Target {
	id string
}

// message_menu is a message context menu command run on `message`, the JSON of a message such
// as `message_create`'s.
pub fn message_menu(name string, message string, from From) string {
	target := json2.decode[Target](message) or {
		panic('veyfert.testing: message_menu needs the JSON of a message with an "id": ${err}')
	}
	return interaction(104, 2, '"data":{"id":"6","name":"${name}","type":3,"target_id":"${target.id}","resolved":{"messages":{"${target.id}":${message}}}}',
		from)
}

// message_create is a message, from ana unless `from` says otherwise, for prefix commands and
// listeners. Messages carry no permissions: `from`'s permissions do not apply.
pub fn message_create(content string, from From) string {
	return '{"id":"400","channel_id":"300","guild_id":"30","author":${from.user()},"member":{"roles":${json2.encode(from.roles)}},"content":${json2.encode(content)},"timestamp":"2026-01-01T00:00:00+00:00","mentions":[]}'
}
