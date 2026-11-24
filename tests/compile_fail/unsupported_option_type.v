// expect: veyfert: unsupported option type
module main

import veyfert

@[veyfert.Declare(name: 'tags', description: 'Takes a list')]
struct Tags {
mut:
	tags []string @[veyfert.Desc: 'Some tags']
}

fn (t Tags) run(mut ctx veyfert.CommandContext) ! {}

fn main() {
	mut bot := veyfert.new_client(token: 'x')
	bot.commands.add(Tags{})
}
