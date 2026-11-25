module veyfert

import json2
import veyfert.discord
import veyfert.rest

@[heap]
struct Recorder {
mut:
	requests []rest.HttpRequest
}

fn (mut r Recorder) send(req rest.HttpRequest) !rest.HttpResponse {
	r.requests << req
	return rest.HttpResponse{
		status: 200
		body:   '{"id":"900","channel_id":"40","author":{"id":"1","username":"bot"},"content":"","timestamp":""}'
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test', prefixes: ['!'])
	rec := &Recorder{}
	c.rest.transport = rec
	c.user = discord.User{
		id:       discord.Snowflake{1}
		username: 'bot'
	}
	// @everyone has no permissions; `mods` (31) is administrator.
	c.dispatch(0, 'RAW_GUILD_CREATE', '{"id":"30","name":"Test","owner_id":"99","roles":[{"id":"30","name":"@everyone","permissions":"0"},{"id":"31","name":"mods","permissions":"8"}],"channels":[{"id":"40","type":0}],"members":[{"user":{"id":"1","username":"bot"},"roles":["31"]}]}')
	return c, rec
}

fn interaction(kind int, data string) string {
	return '{"id":"10","application_id":"20","type":${kind},"token":"tok","app_permissions":"8","guild_id":"30","channel_id":"40","member":{"user":{"id":"7","username":"ana"},"roles":[],"permissions":"0"},"message":{"id":"55","channel_id":"40","content":""},"data":${data}}'
}

fn command(name string, options string) string {
	return interaction(2, '{"id":"1","name":"${name}","type":1,"options":${options}}')
}

fn said(content string, roles string) string {
	return '{"id":"500","channel_id":"40","guild_id":"30","author":{"id":"7","username":"ana"},"member":{"roles":[${roles}]},"content":${json2.encode(content)},"timestamp":""}'
}

// answer is the content of the last answer: an interaction callback or a channel message.
fn answer(rec &Recorder) string {
	if rec.requests.len == 0 {
		return '(nothing)'
	}
	body := rec.requests.last().body
	if cb := json2.decode[Callback[MessagePayload]](body) {
		if content := cb.data.content {
			return content
		}
	}
	return (json2.decode[MessagePayload](body) or { return body }).content or { '' }
}

@[heap]
struct Log {
mut:
	steps []string
}

fn (mut l Log) add(step string) {
	l.steps << step
}

struct StepGuard {
	log &Log
}

fn (mut g StepGuard) check(mut _ CommandContext) ! {
	mut l := g.log
	l.add('guard')
}

@[Declare(name: 'hooked', description: 'Records its hooks')]
struct Hooked {
	log &Log
mut:
	step  StepGuard
	text  string @[Desc: 'Some text']
	shout string // not an option: check_options sets it
}

fn (h Hooked) on_before_options(mut _ CommandContext) ! {
	mut l := h.log
	l.add('before_options')
}

fn (mut h Hooked) check_options(mut _ CommandContext) ! {
	mut l := h.log
	l.add('check_options')
	if h.text == 'bad' {
		return error('text cannot be bad')
	}
	h.shout = h.text.to_upper()
}

fn (h Hooked) on_options_error(mut _ CommandContext, failure IError) ! {
	mut l := h.log
	l.add('options_error ${failure.msg()}')
}

fn (h Hooked) on_before_guards(mut _ CommandContext) ! {
	mut l := h.log
	l.add('before_guards')
}

fn (h Hooked) run(mut _ CommandContext) ! {
	mut l := h.log
	l.add('run ${h.shout}')
	if h.text == 'boom' {
		return error('boom')
	}
}

fn (h Hooked) on_run_error(mut _ CommandContext, failure IError) ! {
	mut l := h.log
	l.add('run_error ${failure.msg()}')
	return error('the hook failed too')
}

fn (h Hooked) on_after_run(mut _ CommandContext, failure ?IError) ! {
	mut l := h.log
	if f := failure {
		l.add('after_run ${f.msg()}')
	} else {
		l.add('after_run ok')
	}
}

fn (h Hooked) on_internal_error(mut _ CommandContext, failure IError) ! {
	mut l := h.log
	l.add('internal ${failure.msg()}')
}

fn hooked_client() (&Client, &Log) {
	mut c, _ := recording_client()
	log := &Log{}
	c.commands.add(Hooked{
		log:  log
		step: StepGuard{log}
	})
	return c, log
}

fn test_command_hooks_run_in_seyferts_order() {
	mut c, mut log := hooked_client()
	c.handle_interaction(command('hooked', '[{"name":"text","type":3,"value":"hi"}]'))
	assert log.steps == ['before_options', 'check_options', 'before_guards', 'guard', 'run HI',
		'after_run ok']
}

fn test_check_options_rejects_and_on_options_error_answers() {
	mut c, mut log := hooked_client()
	c.handle_interaction(command('hooked', '[{"name":"text","type":3,"value":"bad"}]'))
	assert log.steps == ['before_options', 'check_options', 'options_error text cannot be bad']
}

fn test_a_failing_run_reaches_on_after_run_and_hook_errors_reach_on_internal_error() {
	mut c, mut log := hooked_client()
	c.handle_interaction(command('hooked', '[{"name":"text","type":3,"value":"boom"}]'))
	assert log.steps == ['before_options', 'check_options', 'before_guards', 'guard', 'run BOOM',
		'run_error boom', 'internal on_run_error: the hook failed too', 'after_run boom']
}

@[Declare(name: 'purge', description: 'Needs to manage messages')]
@[Perms('manage_messages')]
struct Purge {}

fn (p Purge) run(mut ctx CommandContext) ! {
	ctx.write(content: 'purged')!
}

fn test_prefix_commands_check_the_authors_permissions_and_slash_commands_leave_it_to_discord() {
	mut c, rec := recording_client()
	c.commands.add(Purge{})
	c.run_prefix(said('!purge', ''))
	assert answer(rec) == 'You need these permissions here: manage_messages.'
	c.run_prefix(said('!purge', '"31"')) // an administrator
	assert answer(rec) == 'purged'
	// The interaction's member has no permissions, but Discord let them run it: a guild may
	// allow a command to anyone.
	c.handle_interaction(command('purge', '[]'))
	assert answer(rec) == 'purged'
	c.commands.defaults.on_permissions_fail = fn (mut ctx CommandContext, missing discord.Permissions) ! {
		ctx.write(content: 'no ${missing.names()}')!
	}
	c.run_prefix(said('!purge', ''))
	assert answer(rec) == 'no manage_messages'
}

@[Declare(name: 'pair', description: 'Two options')]
struct Pair {
mut:
	a string @[Desc: 'A text']
	b int    @[Desc: 'A number']
}

fn (p Pair) run(mut ctx CommandContext) ! {
	ctx.write(content: '${p.a}/${p.b}')!
}

fn test_a_custom_args_parser_reads_prefix_arguments() {
	mut c, rec := recording_client()
	c.commands.add(Pair{})
	c.run_prefix(said('!pair x 2', ''))
	assert answer(rec) == 'x/2' // the default parser: in order
	c.commands.args_parser = fn (args []string, options []PrefixOption, _ discord.Message) map[string]string {
		assert options.map(it.name) == ['a', 'b'] && options.all(it.required)
		mut values := map[string]string{}
		for arg in args {
			values[arg.all_before('=')] = arg.all_after('=')
		}
		return values
	}
	c.run_prefix(said('!pair b=7 a=hello', ''))
	assert answer(rec) == 'hello/7'
}

@[EntryPoint(name: 'launch', description: 'Starts the game')]
struct Launch {}

@[EntryPoint(name: 'play', description: 'Starts the game')]
@[AppHandler]
struct Play {}

fn (p Play) run(mut ctx CommandContext) ! {
	ctx.launch_activity()!
}

fn test_entry_points_register_and_launch_the_activity() {
	mut c, rec := recording_client()
	c.commands.add(Launch{})
	assert json2.encode(c.commands.entries[0].json) == '{"type":4,"name":"launch","description":"Starts the game","nsfw":false,"handler":2}'
	assert c.commands.prefix_names.len == 0

	mut d, drec := recording_client()
	d.commands.add(Play{})
	assert d.commands.entries[0].json.handler or { 0 } == 1
	d.handle_interaction(interaction(2, '{"id":"1","name":"play","type":4}'))
	assert drec.requests.last().url.ends_with('/interactions/10/tok/callback')
	assert drec.requests.last().body == '{"type":12,"data":{}}'
	assert rec.requests.len == 0
}

struct Gate {
	allow bool
}

fn (mut g Gate) check_handler(mut _ InteractionContext) ! {
	if !g.allow {
		return deny('Not for you')
	}
}

@[CustomId('gated')]
struct Gated {
	log &Log
mut:
	gate Gate
}

fn (g Gated) on_before_guards(mut _ ComponentContext) ! {
	mut l := g.log
	l.add('before_guards')
}

fn (g Gated) run(mut ctx ComponentContext) ! {
	mut l := g.log
	l.add('run')
	ctx.update(content: 'ok')!
}

fn (g Gated) on_after_run(mut _ ComponentContext, failure ?IError) ! {
	mut l := g.log
	l.add(if _ := failure { 'after_run error' } else { 'after_run ok' })
}

fn click(custom_id string) string {
	return interaction(3, '{"custom_id":"${custom_id}","component_type":2}')
}

fn test_component_handlers_have_guards_and_hooks() {
	mut c, rec := recording_client()
	mut log := &Log{}
	c.components.add(Gated{
		log:  log
		gate: Gate{true}
	})
	c.handle_interaction(click('gated'))
	assert log.steps == ['before_guards', 'run', 'after_run ok']
	assert answer(rec) == 'ok'

	mut d, drec := recording_client()
	mut dlog := &Log{}
	d.components.add(Gated{
		log:  dlog
		gate: Gate{false}
	})
	d.handle_interaction(click('gated'))
	assert dlog.steps == ['before_guards']
	assert answer(drec) == 'Not for you'
}

fn test_global_handler_guards_run_before_every_component_and_modal() {
	mut c, rec := recording_client()
	mut log := &Log{}
	c.components.add(Gated{
		log:  log
		gate: Gate{true}
	})
	c.components.use(Gate{false})
	c.handle_interaction(click('gated'))
	assert log.steps == ['before_guards']
	assert answer(rec) == 'Not for you'
}

@[Modal(custom_id: 'note', title: 'A note')]
struct Note {
mut:
	text string @[Label: 'Text']
}

fn (n Note) submit(mut ctx ModalContext) ! {
	ctx.write(content: 'noted ${n.text}')!
}

fn test_modal_guards_run_before_submit() {
	mut c, rec := recording_client()
	c.modals.add(Note{})
	sent := interaction(5, '{"custom_id":"note","components":[{"type":1,"components":[{"type":4,"custom_id":"text","value":"hi"}]}]}')
	c.handle_interaction(sent)
	assert answer(rec) == 'noted hi'
	c.modals.use(Gate{false})
	c.handle_interaction(sent)
	assert answer(rec) == 'Not for you'
}
