module veyfert

import semver
import time
import veyfert.discord

// Plugin extends a client through its public API: `setup` runs on `install`, and `teardown`
// when `run` returns, in reverse order of installation. A plugin may also have an
// `info() PluginInfo` method (see Described) to declare its version, the plugins it imports
// or requires, and the gateway intents it needs.
//
// What a plugin registers in `setup` is its own: listeners, interceptors, REST and command
// observers, commands, components, modals, guards, hooks, wrappers and shared values. The
// client forgets them when the plugin is torn down, or at once when its setup fails. What it
// assigns directly, such as `c.commands.defaults`, stays.
pub interface Plugin {
	name() string
mut:
	setup(mut c Client) !
	teardown(mut c Client) !
}

// Described is a plugin with an `info` method.
pub interface Described {
	info() PluginInfo
}

// PluginInfo is what a plugin declares about itself.
pub struct PluginInfo {
pub:
	version  string          // its semver version, which the requirements of other plugins check
	imports  []Plugin        // installed before it, unless a plugin of the same name already is
	requires []Requirement   // plugins that must be installed before it
	intents  discord.Intents // gateway intents it needs, added to the client's
}

// Requirement names a plugin that must be installed, by `install` or as an import, before the
// plugin that requires it.
pub struct Requirement {
pub:
	plugin   string
	version  string // a semver range its version must satisfy, such as '^1.2.0'; '' takes any
	optional bool   // when it is missing or out of range, log a warning instead of failing
}

// PluginError is a plugin that failed. `phase` is install, imports, requires, setup, teardown
// or the disposal of a shared value.
pub struct PluginError {
	Error
pub:
	plugin string
	phase  string
	cause  IError
}

pub fn (e PluginError) msg() string {
	return 'veyfert: plugin `${e.plugin}` failed during ${e.phase}: ${e.cause.msg()}'
}

// PluginErrors gathers several failures: the teardowns when `run` returns, or a setup that
// failed together with the teardown of the plugins set up for it.
pub struct PluginErrors {
	Error
pub:
	errors []IError
}

pub fn (e PluginErrors) msg() string {
	return 'veyfert: ${e.errors.len} plugin failures: ${e.errors.map(it.msg()).join('; ')}'
}

// Installed is a plugin that was set up, with the marks taken around its setup.
struct Installed {
	name string
	info PluginInfo
	from Marks
	to   Marks
mut:
	plugin Plugin
}

// install sets a plugin up, after installing the plugins it imports and checking the ones it
// requires; install plugins before `run`. Installing a second plugin with the same name fails,
// while an import that is already installed is skipped. When a setup fails, the client forgets
// what that plugin registered, and the imports this call set up are torn down again.
pub fn (mut c Client) install(mut p Plugin) ! {
	if c.installing != '' {
		return error('veyfert: install plugins from PluginInfo.imports, not from a setup')
	}
	start := c.plugins.len
	c.install_tree(mut p, []string{}) or {
		mut failures := [err]
		failures << c.uninstall(start)
		if failures.len == 1 {
			return err
		}
		return PluginErrors{
			errors: failures
		}
	}
}

// install_tree installs the imports of `p` and then `p`; `chain` holds the plugins whose
// imports are being installed, to find cycles.
fn (mut c Client) install_tree(mut p Plugin, chain []string) ! {
	name := p.name()
	if name in chain {
		return PluginError{
			plugin: name
			phase:  'imports'
			cause:  error('circular import: ${chain.join(' -> ')} -> ${name}')
		}
	}
	if c.plugins.any(it.name == name) {
		if chain.len > 0 {
			return
		}
		return PluginError{
			plugin: name
			phase:  'install'
			cause:  error('a plugin named `${name}` is already installed')
		}
	}
	info := plugin_info(p)
	mut next := chain.clone()
	next << name
	for imported in info.imports {
		mut q := imported
		c.install_tree(mut q, next)!
	}
	for req in info.requires {
		c.check_requirement(name, req)!
	}
	from := c.marks()
	c.installing = name
	p.setup(mut c) or {
		c.installing = ''
		mut failures := [
			IError(PluginError{
				plugin: name
				phase:  'setup'
				cause:  err
			}),
		]
		failures << c.forget(name, from, c.marks())
		if failures.len == 1 {
			return failures[0]
		}
		return PluginErrors{
			errors: failures
		}
	}
	c.installing = ''
	c.intents.set(info.intents)
	c.plugins << Installed{
		name:   name
		info:   info
		from:   from
		to:     c.marks()
		plugin: p
	}
	c.logger.info('plugin `${name}` installed')
}

fn plugin_info(p Plugin) PluginInfo {
	if p is Described {
		return p.info()
	}
	return PluginInfo{}
}

fn (mut c Client) check_requirement(name string, req Requirement) ! {
	mut problem := ''
	found := c.plugins.filter(it.name == req.plugin)
	if found.len == 0 {
		problem = 'it requires the plugin `${req.plugin}`, which is not installed'
	} else if req.version != '' {
		version := found[0].info.version
		fits := if v := semver.from(version) { v.satisfies(req.version) } else { false }
		if !fits {
			installed := if version == '' { 'has no version' } else { 'is ${version}' }
			problem = 'it requires `${req.plugin}` ${req.version}, and the installed one ${installed}'
		}
	}
	if problem == '' {
		return
	}
	if req.optional {
		c.logger.warn('plugin `${name}`: ${problem}')
		return
	}
	return PluginError{
		plugin: name
		phase:  'requires'
		cause:  error(problem)
	}
}

// teardown_plugins tears the plugins down, the last installed first, and takes back what each
// registered. It returns every failure.
fn (mut c Client) teardown_plugins() ! {
	failures := c.uninstall(0)
	if failures.len == 1 {
		return failures[0]
	}
	if failures.len > 1 {
		return PluginErrors{
			errors: failures
		}
	}
}

// uninstall tears down the plugins installed from index `start` on, the last first.
fn (mut c Client) uninstall(start int) []IError {
	mut failures := []IError{}
	for c.plugins.len > start {
		installed := c.plugins.pop()
		mut p := installed.plugin
		p.teardown(mut c) or {
			// Without the cast, V stores a broken IError (vlang/v#32893).
			failures << IError(PluginError{
				plugin: installed.name
				phase:  'teardown'
				cause:  err
			})
		}
		failures << c.forget(installed.name, installed.from, installed.to)
	}
	return failures
}

// close_plugins ends a run for the plugins: it waits for the handlers to finish the jobs
// already queued, runs the client_close hooks, and tears the plugins down.
fn (mut c Client) close_plugins() ! {
	if c.plugins.len == 0 && !c.hooks.any(it.hook == .client_close) {
		return
	}
	c.drain(10 * time.second)
	c.run_hooks(.client_close)
	c.teardown_plugins()!
}

// Hook is a moment in the client's life where plugins, or the bot, can run code.
pub enum Hook {
	plugins_ready // `run` starts, with every plugin installed
	before_upload // `upload_commands` is about to send the commands; a hook may still add some
	client_close  // `run` is returning: the shards are closed and the queued events handled
}

struct HookFn {
	hook  Hook
	owner string // the plugin whose setup registered it; '' for the bot
	f     fn (mut c Client) ! @[required]
}

// hook runs `f` at `h`, after the hooks registered before it. A hook that fails is logged
// with the name of its plugin, and the others still run.
pub fn (mut c Client) hook(h Hook, f fn (mut c Client) !) {
	c.hooks << HookFn{h, c.installing, f}
}

fn (mut c Client) run_hooks(h Hook) {
	for entry in c.hooks.filter(it.hook == h) {
		entry.f(mut c) or {
			who := if entry.owner == '' { '' } else { 'plugin `${entry.owner}`: ' }
			c.logger.error('${who}hook ${h}: ${err}')
		}
	}
}

// SharedKey names a value that plugins share with each other and with the bot. A plugin
// declares `pub const db = veyfert.SharedKey[&Db]{'db'}`, sets it in `setup`, and anyone reads
// it with `db.get(c)`. A key holds one type; share a reference when the value has state.
pub struct SharedKey[T] {
pub:
	name string
}

struct SharedEntry {
	typ     string
	value   voidptr // a &SharedBox[T]
	dispose ?fn () !
}

struct SharedBox[T] {
	value T
}

// set shares `value` until the plugin whose setup set it is torn down; then `dispose`, when
// given, gets it. A key that is already set fails.
pub fn (k SharedKey[T]) set(mut c Client, value T, dispose ?fn (T) !) ! {
	c.shared_mu.lock()
	defer {
		c.shared_mu.unlock()
	}
	if k.name in c.shared {
		return error('veyfert: the shared value `${k.name}` is already set')
	}
	mut entry := SharedEntry{
		typ:   typeof[T]().name
		value: voidptr(&SharedBox[T]{value})
	}
	if d := dispose {
		entry = SharedEntry{
			...entry
			dispose: fn [d, value] [T]() ! {
				d(value)!
			}
		}
	}
	c.shared[k.name] = entry
}

// get returns the shared value, or none when nothing set it. Reading a key as another type
// than the one it was set with is a bug, and panics.
pub fn (k SharedKey[T]) get(c &Client) ?T {
	c.shared_mu.rlock()
	entry := c.shared[k.name] or {
		c.shared_mu.runlock()
		return none
	}
	c.shared_mu.runlock()
	if entry.typ != typeof[T]().name {
		panic('veyfert: the shared value `${k.name}` holds ${entry.typ}, not ${typeof[T]().name}')
	}
	return unsafe { &SharedBox[T](entry.value) }.value
}

fn (c &Client) shared_keys() []string {
	c.shared_mu.rlock()
	defer {
		c.shared_mu.runlock()
	}
	return c.shared.keys()
}

// GuardWrapper runs around every guard of commands, components and modals, with the guard's
// type name: it calls `next` to run the guard, or returns without calling it to let the
// interaction pass, and may time the guard or change its error.
pub type GuardWrapper = fn (mut ctx InteractionContext, guard string, next fn () !) !

// wrap_guards adds a wrapper around every guard; the first added is the outermost. Add them
// before `run`.
pub fn (mut c Client) wrap_guards(w GuardWrapper) {
	c.guard_wrappers << w
}

// wrap_guard runs `run` inside the guard wrappers.
fn (c &Client) wrap_guard(ctx &InteractionContext, guard string, run fn () !) ! {
	mut next := run
	for i := c.guard_wrappers.len - 1; i >= 0; i-- {
		w := c.guard_wrappers[i]
		inner := next
		next = fn [w, ctx, guard, inner] () ! {
			mut context := unsafe { ctx }
			w(mut context, guard, inner)!
		}
	}
	next()!
}

// AutocompleteWrapper runs around every autocomplete handler: it calls `next` to run it, or
// answers by itself instead.
pub type AutocompleteWrapper = fn (mut ctx AutocompleteContext, next fn () !) !

// wrap_autocomplete adds a wrapper around every autocomplete handler; the first added is the
// outermost. Add them before `run`.
pub fn (mut c Client) wrap_autocomplete(w AutocompleteWrapper) {
	c.complete_wrappers << w
}

// Marks counts what the client has registered. Those registries only grow and plugins go away
// in reverse order of installation, so what a plugin registered lies between the marks taken
// around its setup, and can be taken back.
struct Marks {
	listeners  map[string]int
	raw        int
	intercepts int
	sends      int
	rest       int
	hooks      int
	wrappers   int
	completers int
	entries    int
	guards     int
	observers  int
	c_guards   int
	c_regexes  int
	m_guards   int
	m_regexes  int
	prefix_seq int
	invokers   []string
	perms      []string
	exact      []string
	by_id      []string
	shared     []string
}

fn (c &Client) marks() Marks {
	mut listeners := map[string]int{}
	for name, list in c.listeners {
		listeners[name] = list.len
	}
	return Marks{
		listeners:  listeners
		raw:        c.raw_listeners.len
		intercepts: c.interceptors.len
		sends:      c.send_interceptors.len
		rest:       c.rest.observer_count()
		hooks:      c.hooks.len
		wrappers:   c.guard_wrappers.len
		completers: c.complete_wrappers.len
		entries:    c.commands.entries.len
		guards:     c.commands.guards.len
		observers:  c.commands.observers.len
		c_guards:   c.components.guards.len
		c_regexes:  c.components.regexes.len
		m_guards:   c.modals.guards.len
		m_regexes:  c.modals.regexes.len
		prefix_seq: c.components.next_seq
		invokers:   c.commands.invokers.keys()
		perms:      c.commands.member_perms.keys()
		exact:      c.components.exact.keys()
		by_id:      c.modals.by_id.keys()
		shared:     c.shared_keys()
	}
}

// forget takes back what was registered between two marks, and disposes the values shared in
// between, the newest first. It returns the failures of those disposals.
fn (mut c Client) forget(owner string, from Marks, to Marks) []IError {
	for name, n in to.listeners {
		mut list := c.listeners[name] or { continue }
		cut(mut list, from.listeners[name] or { 0 }, n)
		if list.len == 0 {
			c.listeners.delete(name)
		} else {
			c.listeners[name] = list
		}
	}
	cut(mut c.raw_listeners, from.raw, to.raw)
	cut(mut c.interceptors, from.intercepts, to.intercepts)
	cut(mut c.send_interceptors, from.sends, to.sends)
	c.rest.drop_observers(from.rest, to.rest)
	cut(mut c.hooks, from.hooks, to.hooks)
	cut(mut c.guard_wrappers, from.wrappers, to.wrappers)
	cut(mut c.complete_wrappers, from.completers, to.completers)
	cut(mut c.commands.guards, from.guards, to.guards)
	cut(mut c.commands.observers, from.observers, to.observers)
	cut(mut c.components.guards, from.c_guards, to.c_guards)
	cut(mut c.components.regexes, from.c_regexes, to.c_regexes)
	cut(mut c.modals.guards, from.m_guards, to.m_guards)
	cut(mut c.modals.regexes, from.m_regexes, to.m_regexes)
	// prefix_names points at entries by index, so the indexes past the cut move down.
	n := to.entries - from.entries
	if n > 0 {
		c.commands.entries.delete_many(from.entries, n)
		for name, i in c.commands.prefix_names.clone() {
			if i >= to.entries {
				c.commands.prefix_names[name] = i - n
			} else if i >= from.entries {
				c.commands.prefix_names.delete(name)
			}
		}
	}
	for key in added(from.invokers, to.invokers) {
		c.commands.invokers.delete(key)
	}
	for key in added(from.perms, to.perms) {
		c.commands.member_perms.delete(key)
	}
	for key in added(from.exact, to.exact) {
		c.components.exact.delete(key)
	}
	for key in added(from.by_id, to.by_id) {
		c.modals.by_id.delete(key)
	}
	// Prefix routes are sorted by length, so they are found by the order they were added in.
	c.components.prefixes = c.components.prefixes.filter(it.seq < from.prefix_seq
		|| it.seq >= to.prefix_seq)
	mut failures := []IError{}
	for key in added(from.shared, to.shared).reverse() {
		c.shared_mu.lock()
		entry := c.shared[key] or {
			c.shared_mu.unlock()
			continue
		}
		c.shared.delete(key)
		c.shared_mu.unlock()
		if dispose := entry.dispose {
			dispose() or {
				failures << IError(PluginError{
					plugin: owner
					phase:  'the disposal of `${key}`'
					cause:  err
				})
			}
		}
	}
	return failures
}

fn cut[T](mut list []T, from int, to int) {
	if to > from {
		list.delete_many(from, to - from)
	}
}

// added returns what `to` has beyond `from`, counting repeats.
fn added(from []string, to []string) []string {
	mut left := map[string]int{}
	for s in from {
		left[s]++
	}
	mut out := []string{}
	for s in to {
		if left[s] > 0 {
			left[s]--
		} else {
			out << s
		}
	}
	return out
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
