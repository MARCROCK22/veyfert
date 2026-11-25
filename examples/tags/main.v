module main

import json2
import os
import sync
import veyfert
import veyfert.discord

// A tags bot: saved answers that anyone can call up. /tag create opens a form, /tag show posts
// a tag and suggests names as you type, and /tag edit, /tag delete and /tag list manage them.
// From a message, `@bot t rules` posts a tag too. Tags are kept per server in a JSON file.
//
// Run it from the folder that contains veyfert:
//   DISCORD_TOKEN=... GUILD_ID=... v -path "@vlib|@vmodules|$PWD" run veyfert/examples/tags
// TAGS_FILE chooses the file (tags.json by default). For `!t rules`, enable the Message Content
// intent in the Developer Portal and add `.message_content` to the intents.

struct Tag {
	name     string
	content  string
	owner_id discord.Snowflake
	uses     int
}

// Tags holds the tags of every server. Commands run on several threads, so a mutex guards it,
// and every change is written to the file while it is held.
@[heap]
struct Tags {
	path string
mut:
	mu   &sync.Mutex = sync.new_mutex()
	tags map[string]Tag // by '<guild_id>:<name>'
}

fn load_tags(path string) !&Tags {
	mut t := &Tags{
		path: path
	}
	if os.exists(path) {
		t.tags = json2.decode[map[string]Tag](os.read_file(path)!)!
	}
	return t
}

// write saves the tags through a temporary file. The caller holds the mutex.
fn (t &Tags) write() ! {
	os.write_file('${t.path}.tmp', json2.encode(t.tags))!
	os.mv('${t.path}.tmp', t.path)!
}

fn (mut t Tags) get(guild_id discord.Snowflake, name string) ?Tag {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	tag := t.tags['${guild_id}:${name}'] or { return none }
	return tag
}

// use returns a tag and counts the use.
fn (mut t Tags) use(guild_id discord.Snowflake, name string) !Tag {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	key := '${guild_id}:${name}'
	tag := t.tags[key] or { return error('there is no tag called `${name}`') }
	t.tags[key] = Tag{
		...tag
		uses: tag.uses + 1
	}
	t.write()!
	return tag
}

// save stores `tag`, replacing the tag called `old`; with `old` empty, the name must be free.
fn (mut t Tags) save(guild_id discord.Snowflake, old string, tag Tag) ! {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	key := '${guild_id}:${tag.name}'
	if tag.name != old && key in t.tags {
		return error('there is a tag called `${tag.name}` already')
	}
	if old != '' {
		t.tags.delete('${guild_id}:${old}')
	}
	t.tags[key] = tag
	t.write()!
}

fn (mut t Tags) remove(guild_id discord.Snowflake, name string) ! {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	t.tags.delete('${guild_id}:${name}')
	t.write()!
}

// of returns the tags of a server, the most used first.
fn (mut t Tags) of(guild_id discord.Snowflake) []Tag {
	prefix := '${guild_id}:'
	t.mu.lock()
	mut list := []Tag{}
	for key, tag in t.tags {
		if key.starts_with(prefix) {
			list << tag
		}
	}
	t.mu.unlock()
	list.sort(a.uses > b.uses)
	return list
}

// tag_name turns what a member typed into a tag name: lowercase, with dashes for spaces.
fn tag_name(text string) !string {
	name := text.trim_space().to_lower().replace(' ', '-')
	if name.len == 0 || name.len > 32 || !name.bytes().all(it.is_alnum() || it == `-` || it == `_`) {
		return error('a tag name has up to 32 letters, digits, dashes and underscores')
	}
	return name
}

// may_change tells whether a member may edit or delete a tag: its owner, or a moderator.
fn may_change(author discord.User, member ?discord.Member, tag Tag) bool {
	if author.id == tag.owner_id {
		return true
	}
	m := member or { return false }
	perms := discord.Permissions.parse(m.permissions or { '0' })
	return perms.has(.manage_messages) || perms.has(.administrator)
}

// post sends a tag, never pinging anyone: a tag must not be a way to ping @everyone.
fn post(mut ctx veyfert.CommandContext, mut tags Tags, typed string) ! {
	guild_id := ctx.guild_id() or { return }
	tag := tags.use(guild_id, tag_name(typed) or { typed }) or {
		ctx.write(content: '${err.msg()}. /tag list shows them.', ephemeral: true)!
		return
	}
	ctx.write(
		content:          tag.content
		allowed_mentions: discord.AllowedMentions{
			parse: []
		}
	)!
}

// suggest answers the autocomplete of every option that names a tag.
fn suggest(mut ctx veyfert.AutocompleteContext, mut tags Tags) ! {
	guild_id := ctx.guild_id() or { return }
	typed := ctx.value.to_lower()
	ctx.respond(tags.of(guild_id).filter(it.name.contains(typed)).map(veyfert.Choice{
		name:  it.name
		value: it.name
	}))!
}

@[veyfert.Declare(name: 'show', description: 'Posts a tag')]
struct ShowTag {
	tags &Tags
mut:
	name string @[veyfert.Autocomplete; veyfert.Desc: 'Which tag'; veyfert.MaxLength: 32]
}

fn (s ShowTag) run(mut ctx veyfert.CommandContext) ! {
	mut tags := s.tags
	post(mut ctx, mut tags, s.name)!
}

fn (s ShowTag) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	mut tags := s.tags
	suggest(mut ctx, mut tags)!
}

// TagForm is the form to write a tag. It opens as 'tag:create', or as 'tag:edit:<name>' to
// change a tag, which the regular expression routes here too.
@[veyfert.CustomIdRegex('^tag:edit:')]
@[veyfert.Modal(custom_id: 'tag:create', title: 'Tag')]
struct TagForm {
	tags &Tags
mut:
	name    string @[veyfert.Label: 'Name'; veyfert.MaxLength: 32; veyfert.Placeholder: 'rules']
	content string @[veyfert.Label: 'What it says'; veyfert.MaxLength: 2000; veyfert.Paragraph]
}

fn (f TagForm) submit(mut ctx veyfert.ModalContext) ! {
	guild_id := ctx.guild_id() or { return }
	name := tag_name(f.name) or {
		ctx.write(content: 'Not saved: ${err.msg()}.', ephemeral: true)!
		return
	}
	mut tags := f.tags
	old := ctx.custom_id.all_after('tag:edit:')
	if ctx.custom_id == 'tag:create' {
		tags.save(guild_id, '', Tag{
			name:     name
			content:  f.content
			owner_id: ctx.author().id
		}) or {
			ctx.write(content: 'Not saved: ${err.msg()}.', ephemeral: true)!
			return
		}
		ctx.write(content: 'Created `${name}`. Post it with /tag show.', ephemeral: true)!
		return
	}
	tag := tags.get(guild_id, old) or {
		ctx.write(content: 'Not saved: `${old}` was deleted meanwhile.', ephemeral: true)!
		return
	}
	if !may_change(ctx.author(), ctx.member(), tag) {
		ctx.write(content: 'Only its owner and moderators can change `${old}`.', ephemeral: true)!
		return
	}
	tags.save(guild_id, old, Tag{
		...tag
		name:    name
		content: f.content
	}) or {
		ctx.write(content: 'Not saved: ${err.msg()}.', ephemeral: true)!
		return
	}
	ctx.write(content: 'Saved `${name}`.', ephemeral: true)!
}

@[veyfert.Declare(name: 'create', description: 'Creates a tag')]
struct CreateTag {
	tags &Tags
}

fn (c CreateTag) run(mut ctx veyfert.CommandContext) ! {
	ctx.modal(TagForm{
		tags: c.tags
	})!
}

@[veyfert.Declare(name: 'edit', description: 'Changes a tag')]
struct EditTag {
	tags &Tags
mut:
	name string @[veyfert.Autocomplete; veyfert.Desc: 'Which tag'; veyfert.MaxLength: 32]
}

fn (e EditTag) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut tags := e.tags
	tag := tags.get(guild_id, tag_name(e.name) or { e.name }) or {
		ctx.write(content: 'There is no tag called `${e.name}`.', ephemeral: true)!
		return
	}
	if !may_change(ctx.author(), ctx.member(), tag) {
		ctx.write(
			content:   'Only its owner and moderators can change `${tag.name}`.'
			ephemeral: true
		)!
		return
	}
	// The form opens filled in, and its ID says which tag it changes.
	ctx.modal(TagForm{
		tags:    e.tags
		name:    tag.name
		content: tag.content
	}, custom_id: 'tag:edit:${tag.name}')!
}

fn (e EditTag) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	mut tags := e.tags
	suggest(mut ctx, mut tags)!
}

@[veyfert.Declare(name: 'delete', description: 'Deletes a tag')]
struct DeleteTag {
	tags &Tags
mut:
	name string @[veyfert.Autocomplete; veyfert.Desc: 'Which tag'; veyfert.MaxLength: 32]
}

fn (d DeleteTag) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut tags := d.tags
	tag := tags.get(guild_id, tag_name(d.name) or { d.name }) or {
		ctx.write(content: 'There is no tag called `${d.name}`.', ephemeral: true)!
		return
	}
	if !may_change(ctx.author(), ctx.member(), tag) {
		ctx.write(
			content:   'Only its owner and moderators can delete `${tag.name}`.'
			ephemeral: true
		)!
		return
	}
	tags.remove(guild_id, tag.name)!
	ctx.write(content: 'Deleted `${tag.name}`.', ephemeral: true)!
}

fn (d DeleteTag) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	mut tags := d.tags
	suggest(mut ctx, mut tags)!
}

@[veyfert.Declare(name: 'list', description: 'Lists the tags of this server')]
struct ListTags {
	tags &Tags
}

fn (l ListTags) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.guild_id() or { return }
	mut tags := l.tags
	list := tags.of(guild_id)
	if list.len == 0 {
		ctx.write(content: 'No tags yet. Create one with /tag create.', ephemeral: true)!
		return
	}
	ctx.write(
		embeds:    [
			discord.Embed{
				title:       'Tags (${list.len})'
				description: list.map('`${it.name}` (${it.uses})').join(', ')#[..4000]
				color:       discord.colors.blurple
			},
		]
		ephemeral: true
	)!
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'tag', description: 'Saved answers')]
struct TagCommand {
mut:
	show   ShowTag   @[veyfert.Sub]
	create CreateTag @[veyfert.Sub]
	edit   EditTag   @[veyfert.Sub]
	delete DeleteTag @[veyfert.Sub]
	list   ListTags  @[veyfert.Sub]
}

// ShortTag is `t rules` from a message: a prefix command only, never uploaded.
@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 't', description: 'Posts a tag')]
@[veyfert.Ignore('slash')]
struct ShortTag {
	tags &Tags
mut:
	name string @[veyfert.Desc: 'Which tag']
}

fn (s ShortTag) run(mut ctx veyfert.CommandContext) ! {
	mut tags := s.tags
	post(mut ctx, mut tags, s.name)!
}

fn main() {
	path := os.getenv_opt('TAGS_FILE') or { 'tags.json' }
	tags := load_tags(path) or { panic('cannot read ${path}: ${err}') }
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		intents:  .guilds | .guild_messages
		prefixes: ['!']
	)
	bot.commands.add(TagCommand{
		show:   ShowTag{
			tags: tags
		}
		create: CreateTag{
			tags: tags
		}
		edit:   EditTag{
			tags: tags
		}
		delete: DeleteTag{
			tags: tags
		}
		list:   ListTags{
			tags: tags
		}
	})
	bot.commands.add(ShortTag{
		tags: tags
	})
	bot.modals.add(TagForm{
		tags: tags
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/tags.json'
	)!
	bot.run()!
}
