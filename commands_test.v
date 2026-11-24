module veyfert

import json2
import time
import veyfert.discord
import veyfert.rest

// Recorder answers every request and keeps it, so tests read what a command sent.
@[heap]
struct Recorder {
mut:
	requests []rest.HttpRequest
}

fn (mut r Recorder) send(req rest.HttpRequest) !rest.HttpResponse {
	r.requests << req
	if req.url.ends_with('/oauth2/applications/@me') {
		return rest.HttpResponse{
			status: 200
			body:   '{"id":"42","name":"app"}'
		}
	}
	return rest.HttpResponse{
		status: 200
		body:   if req.method == .put { '[]' } else { '{}' }
	}
}

fn recording_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test')
	rec := &Recorder{}
	c.rest.transport = rec
	return c, rec
}

// interaction builds an INTERACTION_CREATE from a member of guild 30.
fn interaction(kind int, data string, app_permissions string) string {
	return '{"id":"10","application_id":"20","type":${kind},"token":"tok","app_permissions":"${app_permissions}","guild_id":"30","channel_id":"40","member":{"user":{"id":"7","username":"ana"},"roles":[],"permissions":"0"},"data":${data}}'
}

fn command(name string, options string) string {
	return interaction(2, '{"id":"1","name":"${name}","type":1,"options":${options}}', '0')
}

// reply reads the content of the last answer a command sent.
fn reply(rec &Recorder) string {
	if rec.requests.len == 0 {
		return '(no reply)'
	}
	body := rec.requests.last().body
	return (json2.decode[Callback[MessagePayload]](body) or { return body }).data.content or { '' }
}

fn ephemeral(rec &Recorder) bool {
	return rec.requests.len > 0 && rec.requests.last().body.contains('"flags":64')
}

enum Order {
	relevance  @[Label: 'Most relevant']
	newest
}

@[Declare(name: 'probe', description: 'Test command')]
struct Probe {
mut:
	limit  ?int                 @[Desc: 'Maximum'; Min: 1; Max: 25]
	text   string               @[Desc: 'What to look for'; MinLength: 2; MaxLength: 50]
	order  ?Order               @[Desc: 'How to sort']
	exact  bool                 @[Desc: 'Exact match']
	who    ?discord.User        @[Desc: 'A user']
	member ?discord.Member      @[Desc: 'A member']
	role   ?discord.Role        @[Desc: 'A role']
	place  ?discord.Channel     @[Channels: 'guild_text,guild_voice'; Desc: 'A channel']
	thing  ?discord.Mentionable @[Desc: 'Someone or a role']
	file   ?discord.Attachment  @[Desc: 'A file']
	big    ?i64                 @[Desc: 'A big number']
	ratio  ?f64                 @[Desc: 'A ratio']
	topic  ?string              @[Autocomplete; Desc: 'A topic']
}

fn (p Probe) run(mut ctx CommandContext) ! {
	member := p.member or { discord.Member{} }
	place := p.place or { discord.Channel{} }
	thing := p.thing or { discord.Mentionable{} }
	mut out := [p.text, '${p.limit or { -1 }}', '${p.order or { Order.relevance }}', '${p.exact}']
	out << (p.who or { discord.User{} }).username
	out << '${member.nick or { '' }}/${(member.user or { discord.User{} }).username}'
	out << (p.role or { discord.Role{} }).name
	out << place.name or { '' }
	out << (thing.role or { discord.Role{} }).name
	out << (p.file or { discord.Attachment{} }).filename
	out << '${p.big or { 0 }}'
	out << '${p.ratio or { 0.0 }}'
	ctx.write(content: out.join('|'))!
}

fn (p Probe) autocomplete(mut ctx AutocompleteContext) ! {
	ctx.respond([Choice{
		name:  '${ctx.focused}: ${ctx.value}'
		value: ctx.value
	}])!
}

fn test_the_schema_comes_from_the_type() {
	mut c, _ := recording_client()
	c.commands.add(Probe{})
	schema := c.commands.entries[0].json
	assert schema.name == 'probe'
	assert schema.description == 'Test command'
	options := schema.options or { []OptionJson{} }
	// Required options go first, as Discord requires.
	assert options.map(it.name) == ['text', 'exact', 'limit', 'order', 'who', 'member', 'role',
		'place', 'thing', 'file', 'big', 'ratio', 'topic']
	assert options.map(it.kind) == [3, 5, 4, 3, 6, 6, 8, 7, 9, 11, 4, 10, 3]
	text := json2.encode(schema)
	assert text.contains('{"type":3,"name":"text","description":"What to look for","required":true,"min_length":2,"max_length":50}')
	assert text.contains('{"type":4,"name":"limit","description":"Maximum","required":false,"min_value":1,"max_value":25}')
	assert text.contains('"choices":[{"name":"Most relevant","value":"relevance"},{"name":"newest","value":"newest"}]')
	assert text.contains('"name":"place","description":"A channel","required":false,"channel_types":[0,2]}')
	assert text.contains('"name":"topic","description":"A topic","required":false,"autocomplete":true}')
}

fn test_options_fill_the_fields_from_the_interaction() {
	mut c, rec := recording_client()
	c.commands.add(Probe{})
	resolved := '{"users":{"7":{"id":"7","username":"ana"}},"members":{"7":{"nick":"Ani","roles":[]}},"roles":{"8":{"id":"8","name":"mods"}},"channels":{"9":{"id":"9","type":0,"name":"general"}},"attachments":{"11":{"id":"11","filename":"a.png","size":3,"url":"u","proxy_url":"p"}}}'
	options := '[{"name":"text","type":3,"value":"hi"},{"name":"limit","type":4,"value":3},{"name":"order","type":3,"value":"newest"},{"name":"exact","type":5,"value":true},{"name":"who","type":6,"value":"7"},{"name":"member","type":6,"value":"7"},{"name":"role","type":8,"value":"8"},{"name":"place","type":7,"value":"9"},{"name":"thing","type":9,"value":"8"},{"name":"file","type":11,"value":"11"},{"name":"big","type":4,"value":9007199254740991},{"name":"ratio","type":10,"value":0.5}]'
	c.handle_interaction(interaction(2, '{"id":"1","name":"probe","type":1,"options":${options},"resolved":${resolved}}',
		'0'))
	assert rec.requests.len == 1
	assert rec.requests[0].url.ends_with('/interactions/10/tok/callback')
	assert reply(rec) == 'hi|3|newest|true|ana|Ani/ana|mods|general|mods|a.png|9007199254740991|0.5'
}

fn test_optional_options_stay_none() {
	mut c, rec := recording_client()
	c.commands.add(Probe{})
	c.handle_interaction(command('probe', '[{"name":"text","type":3,"value":"hi"},{"name":"exact","type":5,"value":false}]'))
	assert reply(rec) == 'hi|-1|relevance|false||/|||||0|0.0'
}

fn test_a_missing_required_option_goes_to_on_options_error() {
	mut c, rec := recording_client()
	c.commands.add(Probe{})
	c.handle_interaction(command('probe', '[]'))
	assert reply(rec) == 'Invalid options: the option `text` is missing.'
	assert ephemeral(rec)
	c.commands.defaults.on_options_error = fn (mut ctx CommandContext, failure IError) ! {
		ctx.write(content: 'custom: ${failure}')!
	}
	c.handle_interaction(command('probe', '[]'))
	assert reply(rec) == 'custom: the option `text` is missing'
}

fn test_autocomplete_answers_with_choices() {
	mut c, rec := recording_client()
	c.commands.add(Probe{})
	c.handle_interaction(interaction(4, '{"id":"1","name":"probe","type":1,"options":[{"name":"text","type":3,"value":"x"},{"name":"topic","type":3,"value":"ga","focused":true}]}',
		'0'))
	assert rec.requests.len == 1
	assert rec.requests[0].body == '{"type":8,"data":{"choices":[{"name":"topic: ga","value":"ga"}]}}'
}

@[heap]
struct Log {
mut:
	lines []string
}

// Mark is a guard that writes its name, to show the order guards run in.
struct Mark {
mut:
	name string
	log  &Log = unsafe { nil }
}

fn (mut m Mark) check(mut _ CommandContext) ! {
	m.log.lines << m.name
}

@[Declare(name: 'ban', description: 'Ban someone')]
struct BanCmd {
mut:
	mark Mark
	who  discord.User @[Desc: 'Who']
}

fn (b BanCmd) run(mut ctx CommandContext) ! {
	ctx.write(content: 'ban ${b.who.username} at ${ctx.path}')!
}

@[Declare(name: 'kick', description: 'Kick someone')]
struct Kick {}

fn (k Kick) run(mut ctx CommandContext) ! {
	ctx.write(content: 'kick')!
}

@[Declare(name: 'mod', description: 'Moderation')]
struct Mod {
mut:
	mark Mark
	ban  BanCmd @[Sub]
	kick Kick   @[Sub]
}

@[Declare(name: 'lang', description: 'Language')]
struct Lang {}

fn (l Lang) run(mut ctx CommandContext) ! {
	ctx.write(content: 'lang')!
}

@[Contexts('guild')]
@[Declare(name: 'config', description: 'Server settings')]
@[Perms('manage_guild')]
struct Config {
mut:
	mark Mark
	mod  Mod  @[Sub]
	lang Lang @[Sub]
}

fn test_subcommands_form_a_tree_and_inherit_guards() {
	mut c, rec := recording_client()
	log := &Log{}
	c.commands.add(Config{
		mark: Mark{'config', log}
		mod:  Mod{
			mark: Mark{'mod', log}
			ban:  BanCmd{
				mark: Mark{'ban', log}
			}
		}
	})
	mut keys := c.commands.invokers.keys()
	keys.sort()
	assert keys == ['1:config lang', '1:config mod ban', '1:config mod kick']
	assert json2.encode(c.commands.entries[0].json) == '{"type":1,"name":"config","description":"Server settings","options":[{"type":2,"name":"mod","description":"Moderation","required":false,"options":[{"type":1,"name":"ban","description":"Ban someone","required":false,"options":[{"type":6,"name":"who","description":"Who","required":true}]},{"type":1,"name":"kick","description":"Kick someone","required":false,"options":[]}]},{"type":1,"name":"lang","description":"Language","required":false,"options":[]}],"default_member_permissions":"32","nsfw":false,"contexts":[0]}'
	c.handle_interaction(interaction(2, '{"id":"1","name":"config","type":1,"options":[{"name":"mod","type":2,"options":[{"name":"ban","type":1,"options":[{"name":"who","type":6,"value":"7"}]}]}],"resolved":{"users":{"7":{"id":"7","username":"ana"}}}}',
		'0'))
	assert log.lines == ['config', 'mod', 'ban']
	assert reply(rec) == 'ban ana at config mod ban'
	c.handle_interaction(command('config', '[{"name":"lang","type":1,"options":[]}]'))
	assert log.lines == ['config', 'mod', 'ban', 'config']
	assert reply(rec) == 'lang'
}

struct Refuse {}

fn (mut r Refuse) check(mut _ CommandContext) ! {
	return deny('Not today.')
}

struct Halt {}

fn (mut h Halt) check(mut _ CommandContext) ! {
	return stop()
}

@[Declare(name: 'denied', description: 'Always denied')]
struct Denied {
mut:
	no Refuse
}

fn (d Denied) run(mut ctx CommandContext) ! {
	ctx.write(content: 'ran')!
}

@[Declare(name: 'halted', description: 'Always stopped')]
struct Halted {
mut:
	no Halt
}

fn (h Halted) run(mut ctx CommandContext) ! {
	ctx.write(content: 'ran')!
}

fn test_a_deny_answers_and_a_stop_is_silent() {
	mut c, rec := recording_client()
	c.commands.add(Denied{})
	c.commands.add(Halted{})
	c.handle_interaction(command('denied', '[]'))
	assert reply(rec) == 'Not today.'
	assert ephemeral(rec)
	c.handle_interaction(command('halted', '[]'))
	assert rec.requests.len == 1
}

@[Declare(name: 'slow', description: 'Once per minute')]
struct Slow {
mut:
	cd Cooldown = cooldown(1, time.minute)
}

fn (s Slow) run(mut ctx CommandContext) ! {
	ctx.write(content: 'left ${s.cd.remaining}')!
}

fn test_a_cooldown_limits_each_user_and_run_sees_its_state() {
	mut c, rec := recording_client()
	c.commands.add(Slow{})
	c.handle_interaction(command('slow', '[]'))
	assert reply(rec) == 'left 0'
	c.handle_interaction(command('slow', '[]'))
	assert reply(rec) == 'Slow down: try again in 60 s.'
}

@[Declare(name: 'broken', description: 'Always fails')]
struct Broken {}

fn (b Broken) run(mut _ CommandContext) ! {
	return error('boom')
}

fn (b Broken) on_run_error(mut ctx CommandContext, failure IError) ! {
	ctx.write(content: 'hook: ${failure}')!
}

@[Declare(name: 'fails', description: 'Fails without a hook')]
struct Fails {}

fn (f Fails) run(mut _ CommandContext) ! {
	return error('boom')
}

fn test_run_errors_go_to_the_command_hook_or_the_default() {
	mut c, rec := recording_client()
	c.commands.add(Broken{})
	c.commands.add(Fails{})
	c.handle_interaction(command('broken', '[]'))
	assert reply(rec) == 'hook: boom'
	c.handle_interaction(command('fails', '[]'))
	assert reply(rec) == 'Something went wrong.'
	assert ephemeral(rec)
}

@[BotPerms('ban_members')]
@[Declare(name: 'banhammer', description: 'Needs to ban')]
struct Banhammer {}

fn (b Banhammer) run(mut ctx CommandContext) ! {
	ctx.write(content: 'banned')!
}

fn test_missing_bot_permissions_stop_the_command() {
	mut c, rec := recording_client()
	c.commands.add(Banhammer{})
	data := '{"id":"1","name":"banhammer","type":1}'
	c.handle_interaction(interaction(2, data, '0'))
	assert reply(rec) == 'I need these permissions here: ban_members.'
	c.handle_interaction(interaction(2, data, '4'))
	assert reply(rec) == 'banned'
	c.handle_interaction(interaction(2, data, '8')) // administrator
	assert reply(rec) == 'banned'
}

fn test_global_guards_run_before_every_command() {
	mut c, rec := recording_client()
	log := &Log{}
	c.commands.use(Mark{'global', log})
	c.commands.use(Refuse{})
	c.commands.add(Kick{})
	c.handle_interaction(command('kick', '[]'))
	assert log.lines == ['global']
	assert reply(rec) == 'Not today.'
}

@[UserMenu('User info')]
struct Info {}

fn (i Info) run(mut ctx CommandContext) ! {
	user := ctx.target_user() or { return error('no target') }
	ctx.write(content: 'info ${user.username}')!
}

fn test_a_user_menu_reads_its_target() {
	mut c, rec := recording_client()
	c.commands.add(Info{})
	assert json2.encode(c.commands.entries[0].json) == '{"type":2,"name":"User info","description":"","nsfw":false}'
	c.handle_interaction(interaction(2, '{"id":"1","name":"User info","type":2,"target_id":"7","resolved":{"users":{"7":{"id":"7","username":"ana"}}}}',
		'0'))
	assert reply(rec) == 'info ana'
}

@[Declare(name: 'local', description: 'Only in one guild')]
@[Guilds('555')]
struct Local {}

fn (l Local) run(mut ctx CommandContext) ! {
	ctx.write(content: 'local')!
}

fn test_upload_puts_each_scope() ! {
	mut c, rec := recording_client()
	c.commands.add(Kick{})
	c.commands.add(Local{})
	c.upload_commands()!
	puts := rec.requests.filter(it.method == .put)
	assert puts.map(it.url) == ['${rest.api_base}/applications/42/commands',
		'${rest.api_base}/applications/42/guilds/555/commands']
	assert puts[0].body.contains('"name":"kick"') && !puts[0].body.contains('"name":"local"')
	assert puts[1].body.contains('"name":"local"') && !puts[1].body.contains('"name":"kick"')
	c.upload_commands(guild_id: discord.Snowflake{9})!
	last := rec.requests.last()
	assert last.url == '${rest.api_base}/applications/42/guilds/9/commands'
	assert last.body.contains('"name":"kick"') && last.body.contains('"name":"local"')
}

fn test_context_methods_use_the_interaction_webhook() ! {
	mut c, rec := recording_client()
	mut ctx := &CommandContext{
		interaction: json2.decode[discord.Interaction](command('x', '[]'))!
		client:      c
	}
	ctx.defer_reply(true)!
	assert rec.requests.last().body == '{"type":5,"data":{"flags":64}}'
	ctx.write(content: 'twice') or { assert err.msg().contains('already answered') }
	ctx.edit_response(content: 'done')!
	assert rec.requests.last().method == .patch
	assert rec.requests.last().url.ends_with('/webhooks/20/tok/messages/@original')
	ctx.followup(content: 'more')!
	assert rec.requests.last().url.ends_with('/webhooks/20/tok?wait=true')
	ctx.delete_response()!
	assert rec.requests.last().method == .delete
}
