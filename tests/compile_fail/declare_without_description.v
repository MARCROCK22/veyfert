// expect: description
module main

import veyfert

@[veyfert.Declare(name: 'ping')]
struct Ping {}

fn (p Ping) run(mut ctx veyfert.CommandContext) ! {}

fn main() {
	mut bot := veyfert.new_client(token: 'x')
	bot.commands.add(Ping{})
}
