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

// prefix_client has guild 30 cached: @everyone without permissions, `mods` (31) with
// administrator, and the bot (1) as a member.
fn prefix_client() (&Client, &Recorder) {
	mut c := new_client(token: 'test', prefixes: ['!', '?'])
	rec := &Recorder{}
	c.rest.transport = rec
	c.user = discord.User{
		id:       discord.Snowflake{1}
		username: 'bot'
	}
	c.dispatch(0, 'RAW_GUILD_CREATE', '{"id":"30","name":"Test","owner_id":"99","roles":[{"id":"30","name":"@everyone","permissions":"0"},{"id":"31","name":"mods","permissions":"8"}],"channels":[{"id":"40","type":0,"name":"general"}],"members":[{"user":{"id":"1","username":"bot"},"roles":["31"]},{"user":{"id":"8","username":"bob"},"roles":[]}]}')
	return c, rec
}

fn said(content string, roles string) string {
	return '{"id":"500","channel_id":"40","guild_id":"30","author":{"id":"7","username":"ana"},"member":{"roles":[${roles}]},"content":${json2.encode(content)},"timestamp":"","mentions":[{"id":"8","username":"bob"}]}'
}

fn sent(rec &Recorder) string {
	if rec.requests.len == 0 {
		return '(nothing)'
	}
	return (json2.decode[MessagePayload](rec.requests.last().body) or { return '(bad body)' }).content or {
		''
	}
}

enum Size {
	small  @[Label: 'Tiny']
	large
}

@[Aliases('e,say')]
@[Declare(name: 'echo', description: 'Repeats')]
struct Echo {
mut:
	text string @[Desc: 'What to repeat']
}

fn (e Echo) run(mut ctx CommandContext) ! {
	ctx.write(content: e.text)!
}

@[Declare(name: 'sum', description: 'Adds')]
struct Sum {
mut:
	a    int   @[Desc: 'First']
	b    int   @[Desc: 'Second']
	size ?Size @[Desc: 'Size']
}

fn (s Sum) run(mut ctx CommandContext) ! {
	ctx.write(content: '${s.a + s.b} ${s.size or { Size.large }}')!
}

@[Declare(name: 'who', description: 'Shows a member')]
struct Who {
mut:
	member discord.Member @[Desc: 'Who']
}

fn (w Who) run(mut ctx CommandContext) ! {
	ctx.write(content: '${(w.member.user or { discord.User{} }).username} ${ctx.path}')!
}

@[Declare(name: 'admin', description: 'Needs administrator')]
struct Admin {
mut:
	perms RequirePermissions = require_permissions(.administrator)
}

fn (a Admin) run(mut ctx CommandContext) ! {
	ctx.defer_reply(false)!
	ctx.edit_response(content: 'done')!
}

@[Declare(name: 'hidden', description: 'Slash only')]
@[Ignore('prefix')]
struct Hidden {}

fn (h Hidden) run(mut ctx CommandContext) ! {
	ctx.write(content: 'hidden')!
}

fn test_split_args_keeps_quoted_text_together() {
	assert split_args('  ban  "two words" -reason   spam ') == ['ban', 'two words', '-reason',
		'spam']
	assert split_args('""') == ['']
}

fn test_a_prefix_command_replies_in_the_channel() {
	mut c, rec := prefix_client()
	c.commands.add(Echo{})
	c.run_prefix(said('!echo hello   world', ''))
	assert rec.requests.len == 1
	assert rec.requests[0].url.ends_with('/channels/40/messages')
	assert rec.requests[0].body == '{"content":"hello world","message_reference":{"message_id":"500","fail_if_not_exists":false}}'
	c.run_prefix(said('?SAY hi', ''))
	assert sent(rec) == 'hi'
	c.run_prefix(said('<@1> e mention prefix', ''))
	assert sent(rec) == 'mention prefix'
	c.run_prefix(said('echo no prefix', ''))
	c.run_prefix(said('!unknown', ''))
	assert rec.requests.len == 3
	// Messages reach the command pool only when prefixes are set.
	c.dispatch(0, 'MESSAGE_CREATE', said('!echo x', ''))
	job := <-c.interaction_jobs
	assert job.command
}

fn test_options_come_in_order_or_by_name() {
	mut c, rec := prefix_client()
	c.commands.add(Sum{})
	c.run_prefix(said('!sum 1 2', ''))
	assert sent(rec) == '3 large'
	c.run_prefix(said('!sum -b 5 -a 1 -size tiny', ''))
	assert sent(rec) == '6 small'
	c.run_prefix(said('!sum one 2', ''))
	assert sent(rec) == 'Invalid options: `a` needs a whole number.'
	c.run_prefix(said('!sum 1', ''))
	assert sent(rec) == 'Invalid options: the option `b` is missing.'
}

fn test_mentions_resolve_to_members() {
	mut c, rec := prefix_client()
	c.commands.add(Who{})
	c.run_prefix(said('!who <@8>', ''))
	assert sent(rec) == 'bob who'
	c.run_prefix(said('!who 8', ''))
	assert sent(rec) == 'bob who'
}

fn test_guards_see_permissions_from_the_cache() {
	mut c, rec := prefix_client()
	c.commands.add(Admin{})
	c.run_prefix(said('!admin', ''))
	assert sent(rec) == 'You need these permissions: administrator.'
	c.run_prefix(said('!admin', '"31"'))
	// defer_reply shows the bot typing; the first edit sends the answer.
	assert rec.requests[rec.requests.len - 2].url.ends_with('/channels/40/typing')
	assert sent(rec) == 'done'
}

fn test_ignored_commands_stay_out_of_their_mode() {
	mut c, rec := prefix_client()
	c.commands.add(Hidden{})
	c.run_prefix(said('!hidden', ''))
	assert rec.requests.len == 0
	assert c.commands.entries[0].slash
}

fn test_the_cache_works_out_channel_permissions() {
	mut c, _ := prefix_client()
	c.dispatch(0, 'CHANNEL_UPDATE', '{"id":"40","type":0,"guild_id":"30","permission_overwrites":[{"id":"30","type":0,"allow":"0","deny":"2048"},{"id":"8","type":1,"allow":"2048","deny":"0"}]}')
	bob := c.cache.permissions(discord.Snowflake{30}, discord.Snowflake{8}, [], discord.Snowflake{40}) or {
		panic('no permissions')
	}
	assert bob.has(.send_messages)
	ana := c.cache.permissions(discord.Snowflake{30}, discord.Snowflake{7}, [], discord.Snowflake{40}) or {
		panic('no permissions')
	}
	assert !ana.has(.send_messages)
	owner := c.cache.permissions(discord.Snowflake{30}, discord.Snowflake{99}, [], discord.Snowflake{40}) or {
		panic('no permissions')
	}
	assert owner.has(.administrator)
}
