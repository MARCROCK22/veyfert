module testing

import time
import veyfert
import veyfert.discord

@[veyfert.Declare(name: 'ping', description: 'Answers pong')]
struct Ping {}

fn (p Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'pong')!
}

fn test_a_bot_runs_against_the_fake_gateway_and_api() ! {
	mut gw := start_gateway(31960, ['30'])!
	mut api := new_transport()
	mut bot := client(gw, api)
	bot.commands.add(Ping{})
	spawn fn [mut bot] () {
		bot.run() or {}
	}()
	assert gw.wait_identified(2 * time.second)
	gw.dispatch('INTERACTION_CREATE', command_interaction('ping', '[]'))!
	reply := api.wait(1, 2 * time.second) or { panic('no reply') }
	assert reply.url.ends_with('/interactions/100/token/callback')
	assert reply.body == '{"type":4,"data":{"content":"pong"}}'
	// The guild arrived and the cache has it.
	assert bot.cache.channels(discord.Snowflake{30}).len == 1
	bot.stop()
}

fn test_the_transport_answers_in_turn() ! {
	mut api := new_transport(Response{
		body: '{"id":"1","username":"first"}'
	}, Response{
		body: '{"id":"2","username":"second"}'
	})
	mut bot := client(none, api)
	assert bot.users.fetch(discord.Snowflake{1})!.username == 'first'
	assert bot.users.fetch(discord.Snowflake{2})!.username == 'second'
	assert bot.users.fetch(discord.Snowflake{3})!.username == 'second'
	assert api.requests().len == 3
}

fn test_payloads_decode_as_discord_sends_them() ! {
	mut api := new_transport()
	mut bot := client(none, api)
	bot.commands.add(Ping{})
	bot.handle_interaction(command_interaction('ping', '[]'))
	assert api.requests().len == 1
	assert message_create('hi').contains('"content":"hi"')
	assert modal_submit('form', {
		'text': 'hello'
	}).contains('"custom_id":"text","value":"hello"')
	assert component_interaction('x', ['a']).contains('"values":["a"]')
}

@[veyfert.BotPerms('ban_members')]
@[veyfert.Declare(name: 'ban', description: 'Needs to ban')]
struct Ban {}

fn (b Ban) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'banned')!
}

fn test_the_bot_has_every_permission_unless_a_test_lowers_them() {
	mut bot := client(none, new_transport())
	bot.commands.add(Ban{})
	assert bot.handle_http(command_interaction('ban', '[]'), time.second).body.contains('banned')
	refused := bot.handle_http(command_interaction('ban', '[]', bot_permissions: .send_messages),
		time.second)
	assert refused.body.contains('I need these permissions here: ban_members.')
}

@[veyfert.Declare(name: 'whoami', description: 'Says who runs it')]
struct WhoAmI {}

fn (w WhoAmI) run(mut ctx veyfert.CommandContext) ! {
	user := ctx.author()
	member := ctx.member() or { return error('no member') }
	ctx.write(
		content: '${user.username}:${user.id}:${member.roles.map(it.str()).join(',')}:${member.permissions or {
			''
		}}'
	)!
}

fn test_from_changes_who_sends_a_payload() {
	mut bot := client(none, new_transport())
	bot.commands.add(WhoAmI{})
	assert bot.handle_http(command_interaction('whoami', '[]'), time.second).body.contains('"content":"ana:7::0"')
	other := bot.handle_http(command_interaction('whoami', '[]',
		user_id:            '8'
		username:           'bo'
		roles:              ['50', '51']
		member_permissions: .manage_messages
	), time.second)
	assert other.body.contains('"content":"bo:8:50,51:8192"')
}

@[veyfert.Declare(name: 'pick', description: 'Picks a fruit')]
struct Pick {
mut:
	fruit string @[veyfert.Autocomplete; veyfert.Desc: 'A fruit']
}

fn (p Pick) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: p.fruit)!
}

fn (p Pick) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	ctx.respond(['apple', 'apricot', 'banana'].filter(it.starts_with(ctx.value)).map(veyfert.Choice{
		name:  it
		value: it
	}))!
}

fn test_autocomplete_and_message_menu_payloads() {
	mut bot := client(none, new_transport())
	bot.commands.add(Pick{})
	bot.commands.add(CountWords{})
	typed := bot.handle_http(autocomplete_interaction('pick', '[{"name":"fruit","type":3,"value":"ap","focused":true}]'),
		time.second)
	assert typed.body.contains('"type":8') && typed.body.contains('"apple"')
		&& typed.body.contains('"apricot"') && !typed.body.contains('banana')
	counted := bot.handle_http(message_menu('Count words', message_create('one two three',
		user_id:  '8'
		username: 'bo'
	)), time.second)
	assert counted.body.contains('"content":"3 words by bo"')
}

@[veyfert.MessageMenu('Count words')]
struct CountWords {}

fn (c CountWords) run(mut ctx veyfert.CommandContext) ! {
	msg := ctx.target_message() or { return error('no target') }
	ctx.write(content: '${msg.content.fields().len} words by ${msg.author.username}')!
}
