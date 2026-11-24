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
