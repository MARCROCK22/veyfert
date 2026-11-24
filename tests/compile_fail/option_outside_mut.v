// expect: veyfert: command options must be declared in a `mut:` section
module main

import veyfert

@[veyfert.Declare(name: 'echo', description: 'Repeats')]
struct Echo {
	text string @[veyfert.Desc: 'What to repeat']
}

fn (e Echo) run(mut ctx veyfert.CommandContext) ! {}

fn main() {
	mut bot := veyfert.new_client(token: 'x')
	bot.commands.add(Echo{})
}
