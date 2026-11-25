module veyfert

import json2
import strconv
import time
import veyfert.discord

// Prefix commands run the same command types from messages, such as `!ban @ana -reason spam`.
// Options come in schema order, or by name with `-name value`; the last string option takes
// the rest of the line. Users, roles and channels may be mentions or IDs, and attachment
// options take the message's attachments in order. Guild messages need the MESSAGE_CONTENT
// intent, except those that mention the bot.

// split_args splits a command line on spaces, keeping "quoted text" as one argument.
fn split_args(line string) []string {
	mut out := []string{}
	mut current := []rune{}
	mut quoted := false
	mut started := false
	for r in line.runes() {
		if r == `"` {
			quoted = !quoted
			started = true
		} else if r.str().is_blank() && !quoted {
			if started {
				out << current.string()
				current.clear()
				started = false
			}
		} else {
			current << r
			started = true
		}
	}
	if started {
		out << current.string()
	}
	return out
}

fn (mut c Client) run_prefix(raw string) {
	msg := json2.decode[discord.Message](raw) or { return }
	if msg.author.bot || msg.webhook_id != none {
		return
	}
	prefix_of := c.commands.prefix or { return }
	mut prefixes := prefix_of(msg)
	c.mu.lock()
	me := c.user
	c.mu.unlock()
	if !me.id.is_zero() {
		prefixes << ['<@${me.id}>', '<@!${me.id}>']
	}
	prefixes.sort(a.len > b.len)
	prefix := prefixes.filter(it != '' && msg.content.starts_with(it))[0] or { return }
	tokens := split_args(msg.content[prefix.len..])
	if tokens.len == 0 {
		return
	}
	index := c.commands.prefix_names[tokens[0].to_lower()] or { return }
	entry := c.commands.entries[index]
	if guild_id := msg.guild_id {
		if entry.guilds.len > 0 && guild_id.str() !in entry.guilds {
			return
		}
		if contexts := entry.json.contexts {
			if 0 !in contexts {
				return
			}
		}
	} else if contexts := entry.json.contexts {
		if 1 !in contexts {
			return
		}
	}
	mut path := entry.json.name
	mut schema := entry.json.options or { []OptionJson{} }
	mut args := tokens[1..].clone()
	for args.len > 0 {
		sub := schema.filter(it.kind in [option_sub_command, option_sub_command_group]
			&& it.name == args[0].to_lower())
		if sub.len == 0 {
			break
		}
		path += ' ${sub[0].name}'
		schema = sub[0].options or { []OptionJson{} }
		args = args[1..].clone()
	}
	if schema.any(it.kind in [option_sub_command, option_sub_command_group]) {
		return // a group without its subcommand
	}
	invoker := c.commands.invokers['1:${path}'] or { return }
	mut ctx := &CommandContext{
		interaction: c.message_interaction(msg, entry.json.name, []discord.InteractionOption{},
			discord.Resolved{})
		message:     msg
		client:      c
		path:        path
	}
	options, resolved := c.prefix_options(schema, args, msg) or {
		invoker.options_failed(mut ctx, err)
		return
	}
	ctx = &CommandContext{
		interaction: c.message_interaction(msg, entry.json.name, options, resolved)
		message:     msg
		client:      c
		path:        path
	}
	started := time.now()
	invoker.invoke(mut ctx, options)
	c.commands.notify(ctx, started)
}

// message_interaction stands in for the interaction a prefix command lacks, with the
// permissions the cache can work out.
fn (mut c Client) message_interaction(msg discord.Message, name string, options []discord.InteractionOption, resolved discord.Resolved) discord.Interaction {
	c.mu.lock()
	me := c.user
	c.mu.unlock()
	mut member := ?discord.Member(none)
	mut app_permissions := '0'
	if guild_id := msg.guild_id {
		m := msg.member or { discord.Member{} }
		perms := c.cache.permissions(guild_id, msg.author.id, m.roles, msg.channel_id) or {
			discord.no_permissions()
		}
		member = discord.Member{
			...m
			user:        msg.author
			guild_id:    guild_id
			permissions: perms.wire()
		}
		if bot := c.cache.member(guild_id, me.id) {
			app_permissions = (c.cache.permissions(guild_id, me.id, bot.roles, msg.channel_id) or {
				discord.no_permissions()
			}).wire()
		}
	}
	return discord.Interaction{
		id:              msg.id
		kind:            2
		data:            discord.InteractionData{
			name:     name
			kind:     1
			options:  options
			resolved: resolved
		}
		guild_id:        msg.guild_id
		channel_id:      msg.channel_id
		member:          member
		user:            if msg.guild_id == none { msg.author } else { none }
		app_permissions: app_permissions
	}
}

// default_args reads options in schema order, or by name with `-name value`; the last string
// option takes the rest of the line.
fn default_args(schema []OptionJson, args []string) map[string]string {
	names := schema.map(it.name)
	is_name := fn [names] (arg string) bool {
		return arg.len > 1 && arg[0] == `-` && arg[1..].to_lower() in names
	}
	mut values := map[string]string{}
	mut positional := []string{}
	mut i := 0
	for i < args.len {
		if is_name(args[i]) {
			key := args[i][1..].to_lower()
			i++
			mut parts := []string{}
			for i < args.len && !is_name(args[i]) {
				parts << args[i]
				i++
			}
			values[key] = parts.join(' ')
		} else {
			positional << args[i]
			i++
		}
	}
	unnamed := schema.filter(it.name !in values && it.kind != option_attachment)
	for j, o in unnamed {
		if j >= positional.len {
			break
		}
		values[o.name] = if j == unnamed.len - 1 && o.kind == option_string {
			positional[j..].join(' ')
		} else {
			positional[j]
		}
	}
	return values
}

// PrefixOption is an option a prefix command's arguments fill.
pub struct PrefixOption {
pub:
	name     string
	kind     int // 3 string, 4 integer, 5 boolean, 6 user, 7 channel, 8 role, 9 mentionable, 10 number
	required bool
}

// ArgsParser turns the arguments of a prefix command, after its name and subcommands and split
// as a shell would (quotes keep spaces), into option values by name. Values are text, as a user
// types them; mentions and IDs are resolved afterwards. Attachment options take the message's
// attachments and are not listed.
pub type ArgsParser = fn (args []string, options []PrefixOption, msg discord.Message) map[string]string

// prefix_options turns arguments into the options and resolved data an interaction carries.
fn (mut c Client) prefix_options(schema []OptionJson, args []string, msg discord.Message) !([]discord.InteractionOption, discord.Resolved) {
	values := if parse := c.commands.args_parser {
		parse(args, schema.filter(it.kind != option_attachment).map(PrefixOption{
			name:     it.name
			kind:     it.kind
			required: it.required
		}), msg)
	} else {
		default_args(schema, args)
	}
	mut users := map[string]discord.User{}
	mut members := map[string]discord.Member{}
	mut roles := map[string]discord.Role{}
	mut channels := map[string]discord.Channel{}
	mut attachments := map[string]discord.Attachment{}
	mut files := msg.attachments.clone()
	mut out := []discord.InteractionOption{}
	for o in schema {
		if o.kind == option_attachment {
			if files.len > 0 {
				attachments[files[0].id.str()] = files[0]
				out << discord.InteractionOption{
					name:  o.name
					kind:  o.kind
					value: json2.encode(files[0].id.str())
				}
				files.delete(0)
			}
			continue
		}
		text := values[o.name] or { continue }
		value := match o.kind {
			option_string {
				json2.encode(choice_value(o, text)!)
			}
			option_integer {
				if !text.is_int() {
					return error('`${o.name}` needs a whole number')
				}
				text
			}
			option_number {
				strconv.atof64(text) or { return error('`${o.name}` needs a number') }
				text
			}
			option_boolean {
				match text.to_lower() {
					'true', 'yes', 'y', 'on', '1' { 'true' }
					'false', 'no', 'n', 'off', '0' { 'false' }
					else { return error('`${o.name}` needs yes or no') }
				}
			}
			else {
				id := mention_id(text) or {
					return error('`${o.name}` needs a mention or an ID')
				}
				is_role := text.starts_with('<@&')
					|| (o.kind != option_user && c.cache.role(msg.guild_id or { discord.Snowflake{} }, discord.Snowflake.parse(id)!) != none)
				if o.kind == option_role || (o.kind == option_mentionable && is_role) {
					roles[id] = c.prefix_role(msg, id) or {
						return error('`${o.name}`: no such role')
					}
				} else if o.kind == option_channel {
					channels[id] = c.channels.fetch(discord.Snowflake.parse(id)!) or {
						return error('`${o.name}`: no such channel')
					}
				} else {
					users[id] = c.prefix_user(msg, id) or {
						return error('`${o.name}`: no such user')
					}
					if guild_id := msg.guild_id {
						if member := c.members.fetch(guild_id, discord.Snowflake.parse(id)!) {
							members[id] = member
						}
					}
				}
				json2.encode(id)
			}
		}
		out << discord.InteractionOption{
			name:  o.name
			kind:  o.kind
			value: value
		}
	}
	return out, discord.Resolved{
		users:       users
		members:     members
		roles:       roles
		channels:    channels
		attachments: attachments
	}
}

// choice_value maps a choice typed by its value or its label to its value.
fn choice_value(o OptionJson, text string) !string {
	choices := o.choices or { return text }
	for ch in choices {
		if ch.value == text || ch.name.to_lower() == text.to_lower() {
			return ch.value
		}
	}
	return error('`${o.name}` must be one of: ${choices.map(it.name).join(', ')}')
}

// mention_id reads <@id>, <@!id>, <@&id>, <#id> or a bare ID.
fn mention_id(text string) ?string {
	id := text.trim_left('<@!&#').trim_right('>')
	if id.len > 0 && id.bytes().all(it.is_digit()) {
		return id
	}
	return none
}

fn (mut c Client) prefix_user(msg discord.Message, id string) !discord.User {
	for u in msg.mentions {
		if u.id.str() == id {
			return u
		}
	}
	return c.users.fetch(discord.Snowflake.parse(id)!)
}

fn (mut c Client) prefix_role(msg discord.Message, id string) !discord.Role {
	guild_id := msg.guild_id or { return error('roles exist only in servers') }
	return c.roles.fetch(guild_id, discord.Snowflake.parse(id)!)
}
