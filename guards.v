module veyfert

import sync
import time
import veyfert.discord

// Guard runs before a command: a field of a guard type runs before `run`
// (and before each subcommand), and its state after `check` is there for `run`.
pub interface Guard {
mut:
	check(mut ctx CommandContext) !
}

// GuardStop ends a command before it runs. With no reason it stops silently; a reason goes
// to the user, through on_guard_error when the command or the client defines one.
pub struct GuardStop {
	Error
pub:
	reason string
}

pub fn (e GuardStop) msg() string {
	return if e.reason == '' { 'stopped by a guard' } else { e.reason }
}

pub fn stop() IError {
	return GuardStop{}
}

pub fn deny(reason string) IError {
	return GuardStop{
		reason: reason
	}
}

@[heap]
struct CooldownState {
mut:
	mu   &sync.Mutex = sync.new_mutex()
	uses map[u64][]i64 // user ID -> unix milliseconds of recent uses
}

// Cooldown lets each user run a command `uses` times per `per`.
pub struct Cooldown {
	uses  int
	per   time.Duration
	state &CooldownState = unsafe { nil }
pub mut:
	remaining int // after `check`: the runs this user has left in the window
}

pub fn cooldown(uses int, per time.Duration) Cooldown {
	return Cooldown{
		uses:  uses
		per:   per
		state: &CooldownState{}
	}
}

pub fn (mut c Cooldown) check(mut ctx CommandContext) ! {
	user := ctx.author().id.value
	now := time.now().unix_milli()
	window := c.per.milliseconds()
	mut st := c.state
	st.mu.lock()
	defer {
		st.mu.unlock()
	}
	recent := (st.uses[user] or { []i64{} }).filter(now - it < window)
	if recent.len >= c.uses {
		st.uses[user] = recent
		return deny('Slow down: try again in ${(recent[0] + window - now + 999) / 1000} s.')
	}
	mut next := recent.clone()
	next << now
	st.uses[user] = next
	c.remaining = c.uses - next.len
}

// RequirePermissions stops members who lack these permissions in the channel.
pub struct RequirePermissions {
pub:
	perms discord.Permissions
}

pub fn require_permissions(perms discord.Permissions) RequirePermissions {
	return RequirePermissions{
		perms: perms
	}
}

pub fn (mut r RequirePermissions) check(mut ctx CommandContext) ! {
	member := ctx.interaction.member or { return deny('This command only works in servers.') }
	have := discord.Permissions.parse(member.permissions or { '0' })
	if !have.has(.administrator) && !have.all(r.perms) {
		return deny('You need these permissions: ${r.perms.names()}.')
	}
}
