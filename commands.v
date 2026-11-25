module veyfert

import json2
import time
import veyfert.discord

// Declare names a slash command and describes it. Discord wants a lowercase name of up to
// 32 characters and a description of 1 to 100. Subcommands are declared the same way.
@[attribute]
pub struct Declare {
pub:
	name        string
	description string
}

// UserMenu declares a context menu command on users, under Apps. The name may have capitals
// and spaces. Its `run` reads the user with `ctx.target_user()`.
@[attribute]
pub struct UserMenu {
pub:
	name string
}

// MessageMenu declares a context menu command on messages; `ctx.target_message()` reads it.
@[attribute]
pub struct MessageMenu {
pub:
	name string
}

// EntryPoint declares an app's primary entry point command, which launches its Activity from
// the App Launcher. Discord launches the Activity by itself, unless the struct also has
// @[veyfert.AppHandler]: then `run` answers, with `ctx.launch_activity()` for instance.
@[attribute]
pub struct EntryPoint {
pub:
	name        string
	description string
}

// AppHandler makes an entry point command send its interaction to the bot's `run`.
@[attribute]
pub struct AppHandler {}

// Sub marks a field whose type is a subcommand. A subcommand with @[Sub] fields of its own
// is a group, and Discord allows groups only directly under the command.
@[attribute]
pub struct Sub {}

// Perms hides the command from members without these permissions, until a server admin
// changes that: comma-separated `Permissions` names, such as 'ban_members,kick_members'.
@[attribute]
pub struct Perms {
pub:
	names string
}

// BotPerms are permissions the bot needs in the channel; without them the command does not
// run and `on_bot_permissions_fail` answers.
@[attribute]
pub struct BotPerms {
pub:
	names string
}

// Nsfw limits the command to age-restricted channels.
@[attribute]
pub struct Nsfw {}

// Guilds uploads the command only to these servers: comma-separated IDs.
@[attribute]
pub struct Guilds {
pub:
	ids string
}

// Contexts lists where the command can be used: guild, bot_dm, private_channel.
@[attribute]
pub struct Contexts {
pub:
	names string
}

// Integrations lists the installs the command is available in: guild_install, user_install.
@[attribute]
pub struct Integrations {
pub:
	names string
}

// Aliases are more names for a command run from a message with a prefix: comma-separated.
@[attribute]
pub struct Aliases {
pub:
	names string
}

// Ignore keeps a command off slash commands ('slash': not uploaded) or off prefix messages
// ('prefix').
@[attribute]
pub struct Ignore {
pub:
	mode string
}

// Desc turns a field into a command option and describes it (1 to 100 characters). The field
// type sets the option type, and `?T` makes the option optional.
@[attribute]
pub struct Desc {
pub:
	text string
}

// Min is the smallest value an integer or number option accepts.
// Field attributes take a single value: `v fmt` flattens multi-argument field attributes
// into a form that fails to compile with -prod.
@[attribute]
pub struct Min {
pub:
	value int
}

// Max is the largest value an integer or number option accepts.
@[attribute]
pub struct Max {
pub:
	value int
}

// MinLength is the shortest text a string option accepts (0 to 6000).
@[attribute]
pub struct MinLength {
pub:
	value int
}

// MaxLength is the longest text a string option accepts (1 to 6000).
@[attribute]
pub struct MaxLength {
pub:
	value int
}

// Channels limits a channel option to these types: comma-separated `ChannelTypes` names,
// such as 'guild_text,guild_voice', or numbers.
@[attribute]
pub struct Channels {
pub:
	types string
}

// Autocomplete marks an option whose values the command's `autocomplete` method suggests.
@[attribute]
pub struct Autocomplete {}

// Label is the text users see for an enum value used as a choice; without it, the value's name.
@[attribute]
pub struct Label {
pub:
	text string
}

// Choice is a suggestion that `AutocompleteContext.respond` sends; `value` is a string or a
// number, matching the option type.
pub struct Choice {
pub:
	name  string
	value json2.Any
}

const option_sub_command = 1
const option_sub_command_group = 2
const option_string = 3
const option_integer = 4
const option_boolean = 5
const option_user = 6
const option_channel = 7
const option_role = 8
const option_mentionable = 9
const option_number = 10
const option_attachment = 11

struct ChoiceJson {
mut:
	name               string
	value              string
	name_localizations ?map[string]string
}

struct OptionJson {
mut:
	kind                      int @[json: 'type']
	name                      string
	name_localizations        ?map[string]string
	description               string
	description_localizations ?map[string]string
	required                  bool
	choices                   ?[]ChoiceJson
	options                   ?[]OptionJson
	channel_types             ?[]int
	min_value                 ?int
	max_value                 ?int
	min_length                ?int
	max_length                ?int
	autocomplete              ?bool
}

struct CommandJson {
mut:
	kind                       int @[json: 'type']
	name                       string
	name_localizations         ?map[string]string
	description                string
	description_localizations  ?map[string]string
	options                    ?[]OptionJson
	default_member_permissions ?string
	nsfw                       bool
	contexts                   ?[]int
	integration_types          ?[]int
	handler                    ?int // entry points: 1 the app's `run`, 2 Discord launches it
}

struct Entry {
	json    CommandJson
	guilds  []string
	aliases []string
	locale  string // the CommandText field that localizes it
	slash   bool = true // uploaded and run as a slash command
	prefix  bool = true // run from messages with a prefix
}

type GuardFn = fn (mut ctx CommandContext) !

// CommandDefaults answer for the commands that do not define the matching hook method.
// Set them before `run`.
pub struct CommandDefaults {
pub mut:
	on_run_error            fn (mut ctx CommandContext, failure IError) !              = default_run_error
	on_options_error        fn (mut ctx CommandContext, failure IError) !              = default_options_error
	on_guard_error          fn (mut ctx CommandContext, reason string) !               = default_guard_error
	on_bot_permissions_fail fn (mut ctx CommandContext, missing discord.Permissions) ! = default_bot_permissions_fail
	// on_permissions_fail answers a prefix command whose author lacks its @[Perms]; Discord
	// checks those for slash commands.
	on_permissions_fail fn (mut ctx CommandContext, missing discord.Permissions) ! = default_permissions_fail
	// on_internal_error gets the errors that hooks return; by default it logs them.
	on_internal_error fn (mut ctx CommandContext, failure IError) ! = default_internal_error
}

// Commands holds the registered commands, their global guards and the default hooks.
pub struct Commands {
pub mut:
	defaults CommandDefaults
	// prefix returns the prefixes a message may start with to run a command, such as ['!'];
	// set it, or ClientOptions.prefixes, to run commands from messages.
	prefix ?fn (msg discord.Message) []string
	// args_parser replaces how prefix commands read their arguments; see ArgsParser.
	args_parser ?ArgsParser
mut:
	entries      []Entry
	invokers     map[string]Invoker
	guards       []GuardFn
	prefix_names map[string]int // command names and aliases to their entry
	observers    []fn (e CommandEvent)
	member_perms map[string]discord.Permissions // @[Perms] of each command, by its name
}

interface Invoker {
	invoke(mut ctx CommandContext, options []discord.InteractionOption)
	complete(mut ctx AutocompleteContext) !
	options_failed(mut ctx CommandContext, failure IError)
}

// add registers a command: a slash command with @[Declare], a context menu with @[UserMenu] or
// @[MessageMenu], or a command whose @[Sub] fields are its subcommands. A field whose type is a
// `Guard` runs before `run`; on a command with subcommands it runs before each of them. Other
// fields without @[Desc] are dependencies: they travel with every copy of `proto`. What the
// compiler can judge fails to compile; the rest of Discord's rules are checked here, at startup.
pub fn (mut r Commands) add[T](proto T) {
	mut cmd := CommandJson{}
	mut guilds := []string{}
	mut aliases := []string{}
	mut slash := true
	mut prefix := true
	mut locale := ''
	mut app_handler := false
	$for a in T.attributes {
		$if a is Declare {
			cmd.kind = 1
			cmd.name = a.name
			cmd.description = a.description
		} $else $if a is EntryPoint {
			cmd.kind = 4
			cmd.name = a.name
			cmd.description = a.description
		} $else $if a is AppHandler {
			app_handler = true
		} $else $if a is UserMenu {
			cmd.kind = 2
			cmd.name = a.name
		} $else $if a is MessageMenu {
			cmd.kind = 3
			cmd.name = a.name
		} $else $if a is Perms {
			cmd.default_member_permissions = parse_permissions(a.names).wire()
		} $else $if a is Nsfw {
			cmd.nsfw = true
		} $else $if a is Contexts {
			cmd.contexts = parse_names(a.names, ['guild', 'bot_dm', 'private_channel'])
		} $else $if a is Integrations {
			cmd.integration_types = parse_names(a.names, ['guild_install', 'user_install'])
		} $else $if a is Guilds {
			guilds = a.ids.split(',').map(it.trim_space()).filter(it != '')
		} $else $if a is Locale {
			locale = a.field
		} $else $if a is Aliases {
			aliases = a.names.split(',').map(it.trim_space().to_lower()).filter(it != '')
		} $else $if a is Ignore {
			match a.mode {
				'slash' { slash = false }
				'prefix' { prefix = false }
				else {
					panic('veyfert: @[veyfert.Ignore] takes "slash" or "prefix", not `${a.mode}`')
				}
			}
		}
	}
	if cmd.kind == 0 {
		panic('veyfert: ${T.name} needs @[veyfert.Declare(...)], @[veyfert.EntryPoint(...)], @[veyfert.UserMenu(...)] or @[veyfert.MessageMenu(...)]')
	}
	if cmd.kind == 4 {
		if r.entries.any(it.json.kind == 4) {
			panic('veyfert: an app has one entry point command, and ${T.name} would be a second one')
		}
		cmd.handler = if app_handler { 1 } else { 2 }
		prefix = false
	}
	if perms := cmd.default_member_permissions {
		r.member_perms[cmd.name] = discord.Permissions.parse(perms)
	}
	// An entry point that Discord launches never reaches the bot, so it needs no `run`.
	options := if cmd.kind == 4 && !app_handler {
		[]OptionJson{}
	} else {
		r.node(proto, cmd.kind, cmd.name, []GuardFn{}, discord.no_permissions(), 0)
	}
	if cmd.kind == 1 {
		cmd.options = options
	} else if options.len > 0 {
		panic('veyfert: `${cmd.name}` cannot have options; only slash commands do')
	}
	validate_command(cmd)
	if cmd.kind == 1 && prefix {
		for name in [cmd.name, ...aliases] {
			if name in r.prefix_names {
				panic('veyfert: the command name or alias `${name}` is used twice')
			}
			r.prefix_names[name] = r.entries.len
		}
	}
	r.entries << Entry{
		json:    cmd
		guilds:  guilds
		aliases: aliases
		locale:  locale
		slash:   slash
		prefix:  prefix
	}
}

// use adds a guard that runs before every command, ahead of the command's own guards.
pub fn (mut r Commands) use[G Guard](g G) {
	r.guards << guard_fn(g)
}

// node registers the commands at `path` and below, and returns the options of `path`: its
// subcommands and groups, or the options of its fields when it is a leaf.
fn (mut r Commands) node[T](proto T, kind int, path string, inherited []GuardFn, inherited_perms discord.Permissions, depth int) []OptionJson {
	mut perms := inherited_perms
	$for a in T.attributes {
		$if a is BotPerms {
			perms.set(parse_permissions(a.names))
		}
	}
	mut is_group := false
	$for field in T.fields {
		$for a in field.attributes {
			$if a is Sub {
				is_group = true
			}
		}
	}
	options := option_schema(proto)
	if !is_group {
		if !has_method[T]('run') {
			panic('veyfert: command `${path}` (${T.name}) needs a `run` method or @[veyfert.Sub] fields')
		}
		key := '${kind}:${path}'
		if key in r.invokers {
			panic('veyfert: command `${path}` is registered twice')
		}
		r.invokers[key] = Invoker(Bound[T]{
			proto:     proto
			inherited: inherited
			bot_perms: perms
		})
		return options
	}
	if depth >= 2 {
		panic('veyfert: `${path}` has subcommands, but Discord nests groups only directly under the command')
	}
	if options.len > 0 || has_method[T]('run') {
		panic('veyfert: `${path}` has subcommands, so it cannot have options or a `run` method')
	}
	mut guards := inherited.clone()
	$for field in T.fields {
		$if field.typ is Guard {
			guards << guard_fn(proto.$(field.name))
		}
	}
	mut subs := []OptionJson{}
	// ponytail: V instantiates a generic call inside `$if a is Sub` for every field type
	// (PLAN.md, risk 15); `$if field.typ is $struct` keeps that to struct fields.
	$for field in T.fields {
		$if field.typ is $struct {
			$for a in field.attributes {
				$if a is Sub {
					child := proto.$(field.name)
					name, description := declared(child)
					child_options := r.node(child, kind, '${path} ${name}', guards, perms,
						depth + 1)
					group := child_options.any(it.kind == option_sub_command)
					subs << OptionJson{
						kind:        if group {
							option_sub_command_group
						} else {
							option_sub_command
						}
						name:        name
						description: description
						options:     child_options
					}
				}
			}
		}
	}
	return subs
}

fn declared[T](_ T) (string, string) {
	$for a in T.attributes {
		$if a is Declare {
			return a.name, a.description
		}
	}
	panic('veyfert: the subcommand ${T.name} needs @[veyfert.Declare(name: ..., description: ...)]')
}

@[markused]
fn has_method[T](name string) bool {
	$for m in T.methods {
		if m.name == name {
			return true
		}
	}
	return false
}

fn guard_fn[G Guard](g G) GuardFn {
	return fn [g] [G](mut ctx CommandContext) ! {
		mut copy := g
		copy.check(mut ctx)!
	}
}

fn check_guard[G Guard](mut g G, mut ctx CommandContext) ! {
	g.check(mut ctx)!
}

// option_schema reads the options of a command from the fields of T. Required options go first,
// since Discord rejects them after optional ones.
fn option_schema[T](proto T) []OptionJson {
	mut required := []OptionJson{}
	mut optional := []OptionJson{}
	$for field in T.fields {
		mut o := OptionJson{
			name:     field.name
			required: !field.is_option
		}
		$for a in field.attributes {
			$if a is Min {
				o.min_value = a.value
			} $else $if a is Max {
				o.max_value = a.value
			} $else $if a is MinLength {
				o.min_length = a.value
			} $else $if a is MaxLength {
				o.max_length = a.value
			} $else $if a is Channels {
				o.channel_types = parse_channel_types(a.types)
			} $else $if a is Autocomplete {
				o.autocomplete = true
			}
		}
		$for a in field.attributes {
			$if a is Desc {
				$if !field.is_mut {
					$compile_error('veyfert: command options must be declared in a `mut:` section')
				}
				o.description = a.text
				$if field.is_enum {
					o.kind = option_string
					$if field.is_option {
						o.choices = enum_choices_opt(proto.$(field.name))
					} $else {
						o.choices = enum_choices(proto.$(field.name))
					}
				} $else $if field.typ is string || field.typ is ?string {
					o.kind = option_string
				} $else $if field.typ is int || field.typ is ?int || field.typ is i64 || field.typ is ?i64 {
					o.kind = option_integer
				} $else $if field.typ is f64 || field.typ is ?f64 {
					o.kind = option_number
				} $else $if field.typ is bool || field.typ is ?bool {
					o.kind = option_boolean
				} $else $if field.typ is discord.User || field.typ is ?discord.User || field.typ is discord.Member || field.typ is ?discord.Member {
					o.kind = option_user
				} $else $if field.typ is discord.Channel || field.typ is ?discord.Channel {
					o.kind = option_channel
				} $else $if field.typ is discord.Role || field.typ is ?discord.Role {
					o.kind = option_role
				} $else $if field.typ is discord.Mentionable || field.typ is ?discord.Mentionable {
					o.kind = option_mentionable
				} $else $if field.typ is discord.Attachment || field.typ is ?discord.Attachment {
					o.kind = option_attachment
				} $else {
					$compile_error('veyfert: unsupported option type; use string, int, i64, f64, bool, an enum, User, Member, Channel, Role, Mentionable, Attachment, or their ?T forms')
				}
				if o.required {
					required << o
				} else {
					optional << o
				}
			}
		}
	}
	required << optional
	return required
}

// fill_options copies the options of an interaction into the fields of `cmd`.
fn fill_options[T](mut cmd T, options []discord.InteractionOption, resolved discord.Resolved) ! {
	$for field in T.fields {
		$for a in field.attributes {
			$if a is Desc {
				if opt := find_option(options, field.name) {
					$if field.is_enum {
						name := json2.decode[string](opt.value)!
						$if field.is_option {
							cmd.$(field.name) = parse_enum_opt(cmd.$(field.name), name)!
						} $else {
							cmd.$(field.name) = int(parse_enum(cmd.$(field.name), name)!)
						}
					} $else $if field.typ is string || field.typ is ?string {
						cmd.$(field.name) = json2.decode[string](opt.value)!
					} $else $if field.typ is int || field.typ is ?int {
						cmd.$(field.name) = opt.value.int()
					} $else $if field.typ is i64 || field.typ is ?i64 {
						cmd.$(field.name) = opt.value.i64()
					} $else $if field.typ is f64 || field.typ is ?f64 {
						cmd.$(field.name) = opt.value.f64()
					} $else $if field.typ is bool || field.typ is ?bool {
						cmd.$(field.name) = opt.value == 'true'
					} $else $if field.typ is discord.User || field.typ is ?discord.User {
						cmd.$(field.name) = resolved_user(resolved, option_id(opt)!)!
					} $else $if field.typ is discord.Member || field.typ is ?discord.Member {
						cmd.$(field.name) = resolved_member(resolved, option_id(opt)!)!
					} $else $if field.typ is discord.Channel || field.typ is ?discord.Channel {
						cmd.$(field.name) = resolved.channels[option_id(opt)!] or {
							return error('the channel is missing from the interaction')
						}
					} $else $if field.typ is discord.Role || field.typ is ?discord.Role {
						cmd.$(field.name) = resolved.roles[option_id(opt)!] or {
							return error('the role is missing from the interaction')
						}
					} $else $if field.typ is discord.Mentionable || field.typ is ?discord.Mentionable {
						cmd.$(field.name) = resolved_mentionable(resolved, option_id(opt)!)!
					} $else $if field.typ is discord.Attachment || field.typ is ?discord.Attachment {
						cmd.$(field.name) = resolved.attachments[option_id(opt)!] or {
							return error('the attachment is missing from the interaction')
						}
					}
				} else if !field.is_option {
					return error('the option `${field.name}` is missing')
				}
			}
		}
	}
}

// Bound keeps the prototype of a command that runs: each interaction gets a copy.
struct Bound[T] {
	proto     T
	inherited []GuardFn // the guards of the groups above, outermost first
	bot_perms discord.Permissions
}

// invoke runs a command: bot permissions, the author's permissions (prefix commands only),
// on_before_options, options and check_options, on_before_guards, global guards, the guards of
// its groups, its own guards, `run` and on_after_run. Every failure goes to a hook, never back
// to the pool.
fn (b Bound[T]) invoke(mut ctx CommandContext, options []discord.InteractionOption) {
	mut cmd := b.proto
	if u64(b.bot_perms) != 0 {
		have := discord.Permissions.parse(ctx.interaction.app_permissions or { '0' })
		missing := unsafe { discord.Permissions(u64(b.bot_perms) & ~u64(have)) }
		if u64(missing) != 0 && !have.has(.administrator) {
			hook_bot_permissions(cmd, mut ctx, missing)
			return
		}
	}
	// Discord checks @[Perms] for interactions, after each guild's own command permissions,
	// which a check here would overrule. Messages have nobody else to check them.
	if ctx.message != none {
		required := ctx.client.commands.member_perms[ctx.path.all_before(' ')] or {
			discord.no_permissions()
		}
		if member := ctx.interaction.member {
			if u64(required) != 0 {
				have := discord.Permissions.parse(member.permissions or { '0' })
				missing := unsafe { discord.Permissions(u64(required) & ~u64(have)) }
				if u64(missing) != 0 && !have.has(.administrator) {
					hook_permissions_fail(cmd, mut ctx, missing)
					return
				}
			}
		}
	}
	if !hook_before(cmd, mut ctx, 'on_before_options') {
		return
	}
	fill_options(mut cmd, options, ctx.resolved()) or {
		hook_options_error(cmd, mut ctx, err)
		return
	}
	// check_options may reject the options, or turn them into other fields, as Seyfert's
	// option `value` callbacks do.
	$for m in T.methods {
		$if m.name == 'check_options' {
			cmd.check_options(mut ctx) or {
				hook_options_error(cmd, mut ctx, err)
				return
			}
		}
	}
	if !hook_before(cmd, mut ctx, 'on_before_guards') {
		return
	}
	for g in ctx.client.commands.guards {
		g(mut ctx) or {
			guard_failed(cmd, mut ctx, err)
			return
		}
	}
	for g in b.inherited {
		g(mut ctx) or {
			guard_failed(cmd, mut ctx, err)
			return
		}
	}
	$for field in T.fields {
		$if field.typ is Guard {
			mut g := cmd.$(field.name)
			check_guard(mut g, mut ctx) or {
				guard_failed(cmd, mut ctx, err)
				return
			}
			cmd.$(field.name) = g
		}
	}
	$for m in T.methods {
		$if m.name == 'run' {
			cmd.run(mut ctx) or {
				hook_run_error(cmd, mut ctx, err)
				hook_after_run(cmd, mut ctx, err)
				return
			}
			hook_after_run(cmd, mut ctx, none)
		}
	}
}

fn (b Bound[T]) options_failed(mut ctx CommandContext, failure IError) {
	hook_options_error(b.proto, mut ctx, failure)
}

fn (b Bound[T]) complete(mut ctx AutocompleteContext) ! {
	$for m in T.methods {
		$if m.name == 'autocomplete' {
			cmd := b.proto
			cmd.autocomplete(mut ctx)!
			return
		}
	}
	return error('${T.name} has no `autocomplete` method')
}

// The hooks call the command's method when it has one, and the client's default otherwise.
// Hook methods take the command by value and return `!`, like `run`.

fn hook_run_error[T](cmd T, mut ctx CommandContext, failure IError) {
	ctx.outcome = 'error'
	ctx.failure = failure.msg()
	$for m in T.methods {
		$if m.name == 'on_run_error' {
			cmd.on_run_error(mut ctx, failure) or { internal_error(cmd, mut ctx, 'on_run_error', err) }
			return
		}
	}
	ctx.client.commands.defaults.on_run_error(mut ctx, failure) or {
		internal_error(cmd, mut ctx, 'on_run_error', err)
	}
}

fn hook_options_error[T](cmd T, mut ctx CommandContext, failure IError) {
	ctx.outcome = 'options'
	ctx.failure = failure.msg()
	$for m in T.methods {
		$if m.name == 'on_options_error' {
			cmd.on_options_error(mut ctx, failure) or {
				internal_error(cmd, mut ctx, 'on_options_error', err)
			}
			return
		}
	}
	ctx.client.commands.defaults.on_options_error(mut ctx, failure) or {
		internal_error(cmd, mut ctx, 'on_options_error', err)
	}
}

fn hook_bot_permissions[T](cmd T, mut ctx CommandContext, missing discord.Permissions) {
	ctx.outcome = 'bot_permissions'
	ctx.failure = missing.names()
	$for m in T.methods {
		$if m.name == 'on_bot_permissions_fail' {
			cmd.on_bot_permissions_fail(mut ctx, missing) or {
				internal_error(cmd, mut ctx, 'on_bot_permissions_fail', err)
			}
			return
		}
	}
	ctx.client.commands.defaults.on_bot_permissions_fail(mut ctx, missing) or {
		internal_error(cmd, mut ctx, 'on_bot_permissions_fail', err)
	}
}

fn hook_permissions_fail[T](cmd T, mut ctx CommandContext, missing discord.Permissions) {
	ctx.outcome = 'permissions'
	ctx.failure = missing.names()
	$for m in T.methods {
		$if m.name == 'on_permissions_fail' {
			cmd.on_permissions_fail(mut ctx, missing) or {
				internal_error(cmd, mut ctx, 'on_permissions_fail', err)
			}
			return
		}
	}
	ctx.client.commands.defaults.on_permissions_fail(mut ctx, missing) or {
		internal_error(cmd, mut ctx, 'on_permissions_fail', err)
	}
}

// hook_before calls on_before_options or on_before_guards when the command has it. An error
// from either stops the command and goes to on_internal_error.
fn hook_before[T](cmd T, mut ctx CommandContext, hook string) bool {
	$for m in T.methods {
		$if m.name == 'on_before_options' {
			if hook == 'on_before_options' {
				cmd.on_before_options(mut ctx) or {
					internal_error(cmd, mut ctx, hook, err)
					return false
				}
			}
		} $else $if m.name == 'on_before_guards' {
			if hook == 'on_before_guards' {
				cmd.on_before_guards(mut ctx) or {
					internal_error(cmd, mut ctx, hook, err)
					return false
				}
			}
		}
	}
	return true
}

// hook_after_run calls on_after_run, with the error of `run` when it failed.
fn hook_after_run[T](cmd T, mut ctx CommandContext, failure ?IError) {
	$for m in T.methods {
		$if m.name == 'on_after_run' {
			cmd.on_after_run(mut ctx, failure) or { internal_error(cmd, mut ctx, 'on_after_run', err) }
		}
	}
}

// internal_error handles an error that a hook returned: the command's on_internal_error, or
// the client's default, which logs it.
fn internal_error[T](cmd T, mut ctx CommandContext, hook string, failure IError) {
	wrapped := error('${hook}: ${failure.msg()}')
	$for m in T.methods {
		$if m.name == 'on_internal_error' {
			cmd.on_internal_error(mut ctx, wrapped) or { ctx.log_hook('on_internal_error', err) }
			return
		}
	}
	ctx.client.commands.defaults.on_internal_error(mut ctx, wrapped) or {
		ctx.log_hook('on_internal_error', err)
	}
}

// guard_failed handles a guard's error: a silent stop ends the command, a deny goes to
// on_guard_error, and any other error is a failure of the command.
fn guard_failed[T](cmd T, mut ctx CommandContext, failure IError) {
	if failure is GuardStop {
		ctx.outcome = 'guard'
		ctx.failure = failure.reason
		if failure.reason == '' {
			return
		}
		$for m in T.methods {
			$if m.name == 'on_guard_error' {
				cmd.on_guard_error(mut ctx, failure.reason) or {
					internal_error(cmd, mut ctx, 'on_guard_error', err)
				}
				return
			}
		}
		ctx.client.commands.defaults.on_guard_error(mut ctx, failure.reason) or {
			internal_error(cmd, mut ctx, 'on_guard_error', err)
		}
		return
	}
	hook_run_error(cmd, mut ctx, failure)
}

fn (ctx &CommandContext) log_hook(hook string, failure IError) {
	ctx.client.logger.error('${hook} of `${ctx.path}`: ${failure}')
}

fn default_run_error(mut ctx CommandContext, failure IError) ! {
	ctx.client.logger.error('command `${ctx.path}`: ${failure}')
	ctx.reply_error('Something went wrong.')!
}

fn default_options_error(mut ctx CommandContext, failure IError) ! {
	ctx.reply_error('Invalid options: ${failure.msg()}.')!
}

fn default_guard_error(mut ctx CommandContext, reason string) ! {
	ctx.reply_error(reason)!
}

fn default_bot_permissions_fail(mut ctx CommandContext, missing discord.Permissions) ! {
	ctx.reply_error('I need these permissions here: ${missing.names()}.')!
}

fn default_permissions_fail(mut ctx CommandContext, missing discord.Permissions) ! {
	ctx.reply_error('You need these permissions here: ${missing.names()}.')!
}

fn default_internal_error(mut ctx CommandContext, failure IError) ! {
	ctx.client.logger.error('command `${ctx.path}`: ${failure}')
}

// command_path follows subcommand and group options down to the command that runs, and
// returns its path, such as 'config mod ban', and its options.
fn command_path(data discord.InteractionData) (string, []discord.InteractionOption) {
	mut path := data.name
	mut options := data.options.clone()
	for options.len == 1 && options[0].kind in [option_sub_command, option_sub_command_group] {
		path += ' ${options[0].name}'
		options = options[0].options
	}
	return path, options
}

fn (mut c Client) run_command(i discord.Interaction, inline &InlineReply) {
	data := i.data or { return }
	path, options := if data.kind == 1 { command_path(data) } else { data.name, data.options }
	invoker := c.commands.invokers['${data.kind}:${path}'] or {
		c.logger.warn('interaction for unknown command `${path}`')
		return
	}
	mut ctx := &CommandContext{
		interaction: i
		client:      c
		path:        path
		inline:      inline
	}
	started := time.now()
	invoker.invoke(mut ctx, options)
	c.commands.notify(ctx, started)
}

fn (mut c Client) run_autocomplete(i discord.Interaction, inline &InlineReply) {
	data := i.data or { return }
	path, options := command_path(data)
	invoker := c.commands.invokers['1:${path}'] or { return }
	mut focused := discord.InteractionOption{}
	for o in options {
		if o.focused {
			focused = o
		}
	}
	mut ctx := &AutocompleteContext{
		interaction: i
		client:      c
		inline:      inline
		path:        path
		focused:     focused.name
		value:       option_text(focused.value)
		options:     options
	}
	invoker.complete(mut ctx) or { c.logger.error('autocomplete of `${path}`: ${err}') }
}

fn find_option(options []discord.InteractionOption, name string) ?discord.InteractionOption {
	for o in options {
		if o.name == name {
			return o
		}
	}
	return none
}

// option_text is the value of an option as text: a string unquoted, anything else as sent.
fn option_text(raw string) string {
	if raw.starts_with('"') {
		return json2.decode[string](raw) or { raw }
	}
	return raw
}

fn option_id(o discord.InteractionOption) !string {
	return json2.decode[string](o.value)!
}

fn resolved_user(r discord.Resolved, id string) !discord.User {
	return r.users[id] or { return error('the user is missing from the interaction') }
}

// resolved_member joins the partial member Discord resolves with its user.
fn resolved_member(r discord.Resolved, id string) !discord.Member {
	m := r.members[id] or { return error('that user is not a member of this server') }
	return discord.Member{
		...m
		user: r.users[id] or { return m }
	}
}

fn resolved_mentionable(r discord.Resolved, id string) !discord.Mentionable {
	if user := r.users[id] {
		return discord.Mentionable{
			id:     user.id
			user:   user
			member: resolved_member(r, id) or { none }
		}
	}
	role := r.roles[id] or { return error('the user or role is missing from the interaction') }
	return discord.Mentionable{
		id:   role.id
		role: role
	}
}

// The enum helpers take a value so a field's type can be passed without naming it.
fn enum_choices[E](_ E) []ChoiceJson {
	return choices_of[E]()
}

fn enum_choices_opt[E](_ ?E) []ChoiceJson {
	return choices_of[E]()
}

@[markused]
fn choices_of[E]() []ChoiceJson {
	mut out := []ChoiceJson{}
	$for v in E.values {
		mut label := v.name
		$for a in v.attributes {
			$if a is Label {
				label = a.text
			}
		}
		out << ChoiceJson{
			name:  label
			value: v.name
		}
	}
	return out
}

// parse_enum and parse_enum_opt repeat their loop: a shared generic helper shows up as an
// unused function in V's notices.
fn parse_enum[E](_ E, name string) !E {
	$for v in E.values {
		if v.name == name {
			return v.value
		}
	}
	return error('`${name}` is not a valid choice')
}

fn parse_enum_opt[E](_ ?E, name string) !E {
	$for v in E.values {
		if v.name == name {
			return v.value
		}
	}
	return error('`${name}` is not a valid choice')
}

fn parse_permissions(names string) discord.Permissions {
	return discord.Permissions.from_names(names) or { panic('veyfert: ${err}: in `${names}`') }
}

// parse_names maps comma-separated names to their positions in `all`.
fn parse_names(names string, all []string) []int {
	mut out := []int{}
	for name in names.split(',').map(it.trim_space()).filter(it != '') {
		i := all.index(name)
		if i < 0 {
			panic('veyfert: unknown name `${name}`; use ${all.join(', ')}')
		}
		out << i
	}
	return out
}

fn parse_channel_types(types string) []int {
	mut out := []int{}
	for t in types.split(',').map(it.trim_space()).filter(it != '') {
		out << discord.channel_type(t) or { panic('veyfert: unknown channel type `${t}`') }
	}
	return out
}

fn validate_command(c CommandJson) {
	if c.kind == 1 || c.kind == 4 {
		check_name('command', c.name)
		check_description('command `${c.name}`', c.description)
	} else {
		n := c.name.runes().len
		if n == 0 || n > 32 {
			panic('veyfert: the menu command name `${c.name}` must have 1 to 32 characters')
		}
	}
	validate_options(c.name, c.options or { []OptionJson{} })
}

fn validate_options(path string, options []OptionJson) {
	if options.len > 25 {
		panic('veyfert: `${path}` has ${options.len} options; Discord allows 25')
	}
	mut seen := map[string]bool{}
	for o in options {
		where := '${path} ${o.name}'
		check_name('option `${where}`', o.name)
		check_description('option `${where}`', o.description)
		if o.name in seen {
			panic('veyfert: `${path}` has two options named `${o.name}`')
		}
		seen[o.name] = true
		if choices := o.choices {
			if choices.len > 25 {
				panic('veyfert: option `${where}` has ${choices.len} choices; Discord allows 25')
			}
			if o.autocomplete or { false } {
				panic('veyfert: option `${where}` is an enum, so it has choices and cannot autocomplete')
			}
		}
		if min := o.min_length {
			if min < 0 || min > 6000 {
				panic('veyfert: option `${where}`: MinLength must be 0 to 6000')
			}
		}
		if max := o.max_length {
			if max < 1 || max > 6000 {
				panic('veyfert: option `${where}`: MaxLength must be 1 to 6000')
			}
		}
		validate_options(where, o.options or { []OptionJson{} })
	}
}

fn check_name(what string, name string) {
	n := name.runes().len
	if n == 0 || n > 32 || name != name.to_lower() || name.contains(' ') {
		panic('veyfert: ${what}: the name `${name}` must be lowercase, without spaces, 1 to 32 characters')
	}
}

fn check_description(what string, text string) {
	n := text.runes().len
	if n == 0 || n > 100 {
		panic('veyfert: ${what} needs a description of 1 to 100 characters, got ${n}')
	}
}
