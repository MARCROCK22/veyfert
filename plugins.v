module veyfert

import time
import veyfert.discord

// Plugin extends a client through its public API: `setup` runs on `install`, and `teardown`
// when `run` returns, in reverse order of installation.
pub interface Plugin {
	name() string
mut:
	setup(mut c Client) !
	teardown(mut c Client) !
}

// install sets a plugin up; install plugins before `run`.
pub fn (mut c Client) install(mut p Plugin) ! {
	p.setup(mut c) or { return error('veyfert: plugin `${p.name()}`: ${err}') }
	c.plugins << p
	c.logger.info('plugin `${p.name()}` installed')
}

fn (mut c Client) teardown_plugins() {
	for i := c.plugins.len - 1; i >= 0; i-- {
		mut p := c.plugins[i]
		p.teardown(mut c) or { c.logger.error('plugin `${p.name()}` teardown: ${err}') }
	}
	c.plugins.clear()
}

// intercept runs `f` on every dispatch before anything else sees it: it returns the payload to
// use, changed or not, or none to drop the event. Register interceptors before `run`.
pub fn (mut c Client) intercept(f fn (name string, raw string) ?string) {
	c.interceptors << f
}

// intercept_send runs `f` on every payload a shard sends, heartbeats and identifies included:
// it returns the payload to send, changed or not, or none to drop it. Register before `run`.
pub fn (mut c Client) intercept_send(f fn (shard int, payload string) ?string) {
	c.send_interceptors << f
}

// CommandEvent tells observers how a command went.
pub struct CommandEvent {
pub:
	path     string
	user_id  discord.Snowflake
	guild_id ?discord.Snowflake
	prefix   bool // run from a message
	duration time.Duration
	outcome  string // ok, options, guard, bot_permissions or error
	failure  string // the error, when there was one
}

// observe calls `f` after every command; register observers before `run`.
pub fn (mut r Commands) observe(f fn (e CommandEvent)) {
	r.observers << f
}

fn (r &Commands) notify(ctx &CommandContext, started time.Time) {
	if r.observers.len == 0 {
		return
	}
	event := CommandEvent{
		path:     ctx.path
		user_id:  ctx.author().id
		guild_id: ctx.interaction.guild_id
		prefix:   ctx.message != none
		duration: time.since(started)
		outcome:  if ctx.outcome == '' { 'ok' } else { ctx.outcome }
		failure:  ctx.failure
	}
	for f in r.observers {
		f(event)
	}
}
