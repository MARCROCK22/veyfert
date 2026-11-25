module veyfert

import json2
import time
import veyfert.discord

// CustomId routes the buttons and selects whose custom_id is `id` to this handler: a struct
// with `run(mut ctx ComponentContext) !`, added with `Client.components.add`.
@[attribute]
pub struct CustomId {
pub:
	id string
}

// CustomIdPrefix routes the components whose custom_id starts with `prefix`; `ctx.custom_id`
// has the whole ID, so one handler serves 'vote:1', 'vote:2'...
@[attribute]
pub struct CustomIdPrefix {
pub:
	prefix string
}

// Modal declares a modal: the fields with @[Label] are its inputs, and `submit` runs with them
// filled when a user sends it. A string field is a text input, and an enum field a select.
@[attribute]
pub struct Modal {
pub:
	custom_id string
	title     string
}

// Paragraph makes a modal text input span several lines.
@[attribute]
pub struct Paragraph {}

// Placeholder is the hint an empty modal input shows.
@[attribute]
pub struct Placeholder {
pub:
	text string
}

// HandlerGuard is a guard for component and modal handlers: a field whose type implements it
// runs before `run` or `submit`, as a Guard does before a command. `stop()` ends silently, and
// `deny(reason)` answers with the reason, through `on_guard_error` when the handler has it.
pub interface HandlerGuard {
mut:
	check_handler(mut ctx InteractionContext) !
}

type HandlerGuardFn = fn (mut ctx InteractionContext) !

fn handler_guard_fn[G HandlerGuard](g G) HandlerGuardFn {
	return fn [g] [G](mut ctx InteractionContext) ! {
		mut copy := g
		copy.check_handler(mut ctx)!
	}
}

fn check_handler_guard[G HandlerGuard](mut g G, mut ctx InteractionContext) ! {
	g.check_handler(mut ctx)!
}

// ComponentContext is what a component handler receives: a click or a pick.
@[heap]
pub struct ComponentContext {
	InteractionContext
pub:
	custom_id string
	values    []string // what a select picked: option values, or user, role or channel IDs
}

// ModalContext is what a modal's `submit` receives.
@[heap]
pub struct ModalContext {
	InteractionContext
pub:
	custom_id string
}

// update edits the message of the component, or of the component that opened the modal, as
// the answer to the interaction.
pub fn (mut ctx InteractionContext) update(opts MessageOptions) ! {
	if ctx.message != none {
		return error('veyfert: a prefix command cannot answer with this; it has no interaction')
	}
	if ctx.replied {
		return error('veyfert: this interaction was already answered; use edit_response')
	}
	ctx.callback(7, message_payload(opts)!, opts.files)!
	ctx.replied = true
}

// defer_update answers without changing the message yet; `edit_response` edits it later.
pub fn (mut ctx InteractionContext) defer_update() ! {
	if ctx.message != none {
		return error('veyfert: a prefix command cannot answer with this; it has no interaction')
	}
	if ctx.replied {
		return error('veyfert: this interaction was already answered')
	}
	ctx.callback(6, MessagePayload{}, [])!
	ctx.replied = true
}

struct ModalJson {
mut:
	custom_id  string
	title      string
	components []discord.Component
}

// modal opens the modal that `form`'s type declares; fields with a value prefill their inputs.
// A modal must be the first answer to an interaction.
pub fn (mut ctx InteractionContext) modal[T](form T) ! {
	if ctx.message != none {
		return error('veyfert: a prefix command cannot answer with this; it has no interaction')
	}
	if ctx.replied {
		return error('veyfert: a modal must be the first answer to an interaction')
	}
	ctx.callback(9, modal_json(form), [])!
	ctx.replied = true
}

@[params]
pub struct WaitComponent {
pub:
	timeout    time.Duration = time.minute
	message_id ?discord.Snowflake // the message with the components; by default, this interaction's answer
	custom_id  ?string            // only this component
	anyone     bool               // accept any user, not only the author of this interaction
}

// wait_for_component waits for a click or a pick on a message's components and returns the
// context to answer it; none after `timeout`. That interaction skips the component handlers.
pub fn (mut ctx InteractionContext) wait_for_component(opts WaitComponent) ?&ComponentContext {
	message_id := opts.message_id or { (ctx.fetch_response() or { return none }).id }
	user_id := ctx.author().id
	custom_id := opts.custom_id or { '' }
	anyone := opts.anyone
	i := ctx.client.wait_interaction(fn [message_id, user_id, custom_id, anyone] (i discord.Interaction) bool {
		message := i.message or { return false }
		data := i.data or { return false }
		return i.kind == 3 && message.id == message_id
			&& (anyone || interaction_user(i).id == user_id)
			&& (custom_id == '' || data.custom_id or { '' } == custom_id)
	}, opts.timeout)?
	data := i.data or { discord.InteractionData{} }
	return &ComponentContext{
		interaction: i
		client:      ctx.client
		custom_id:   data.custom_id or { '' }
		values:      data.values
	}
}

// wait_for_modal opens `form`'s modal and waits for the author to send it. It returns the form
// filled and the context to answer the submission; none after `timeout`. That submission skips
// the modal handlers.
pub fn (mut ctx InteractionContext) wait_for_modal[T](form T, timeout time.Duration) ?(T, &ModalContext) {
	ctx.modal(form) or { return none }
	custom_id := modal_json(form).custom_id
	user_id := ctx.author().id
	i := ctx.client.wait_interaction(fn [custom_id, user_id] (i discord.Interaction) bool {
		data := i.data or { return false }
		return i.kind == 5 && data.custom_id or { '' } == custom_id
			&& interaction_user(i).id == user_id
	}, timeout)?
	data := i.data or { discord.InteractionData{} }
	mut filled := form
	fill_modal(mut filled, modal_values(data.components or { discord.RawJson{} })) or { return none }
	return filled, &ModalContext{
		interaction: i
		client:      ctx.client
		custom_id:   custom_id
	}
}

fn interaction_user(i discord.Interaction) discord.User {
	if member := i.member {
		if user := member.user {
			return user
		}
	}
	return i.user or { discord.User{} }
}

interface ComponentInvoker {
	invoke(mut ctx ComponentContext)
}

struct ComponentBound[T] {
	proto T
}

// invoke runs a component handler: on_before_guards, the global handler guards, its own guards,
// `run` and on_after_run.
fn (b ComponentBound[T]) invoke(mut ctx ComponentContext) {
	mut handler := b.proto
	if !handler_guards(mut handler, mut ctx, ctx.client.components.guards) {
		return
	}
	$for m in T.methods {
		$if m.name == 'run' {
			handler.run(mut ctx) or {
				handler_failed(handler, mut ctx, err)
				handler_after_run(handler, mut ctx, err)
				return
			}
			handler_after_run(handler, mut ctx, none)
		}
	}
}

struct PrefixRoute {
	prefix  string
	invoker ComponentInvoker
}

// Components routes buttons and selects to their handlers.
pub struct Components {
mut:
	exact    map[string]ComponentInvoker
	prefixes []PrefixRoute // longest first
	guards   []HandlerGuardFn
}

// use adds a guard that runs before every component handler, ahead of its own guards.
pub fn (mut r Components) use[G HandlerGuard](g G) {
	r.guards << handler_guard_fn(g)
}

// add registers a handler: a struct with @[CustomId] or @[CustomIdPrefix] and
// `run(mut ctx ComponentContext) !`. Its fields travel with every copy, like a command's.
pub fn (mut r Components) add[T](proto T) {
	if !has_method[T]('run') {
		panic('veyfert: the component handler ${T.name} needs a `run` method')
	}
	mut routed := false
	$for a in T.attributes {
		$if a is CustomId {
			r.exact[a.id] = ComponentInvoker(ComponentBound[T]{proto})
			routed = true
		} $else $if a is CustomIdPrefix {
			r.prefixes << PrefixRoute{a.prefix, ComponentInvoker(ComponentBound[T]{proto})}
			r.prefixes.sort(a.prefix.len > b.prefix.len)
			routed = true
		}
	}
	if !routed {
		panic('veyfert: ${T.name} needs @[veyfert.CustomId(...)] or @[veyfert.CustomIdPrefix(...)]')
	}
}

fn (r &Components) find(custom_id string) ?ComponentInvoker {
	if invoker := r.exact[custom_id] {
		return invoker
	}
	for route in r.prefixes {
		if custom_id.starts_with(route.prefix) {
			return route.invoker
		}
	}
	return none
}

interface ModalInvoker {
	invoke(mut ctx ModalContext, values map[string][]string)
}

struct ModalBound[T] {
	proto T
}

// invoke fills a modal's fields, then runs on_before_guards, the global handler guards, its own
// guards, `submit` and on_after_run.
fn (b ModalBound[T]) invoke(mut ctx ModalContext, values map[string][]string) {
	mut form := b.proto
	fill_modal(mut form, values) or {
		ctx.reply_error('Invalid form: ${err.msg()}.') or {}
		return
	}
	if !handler_guards(mut form, mut ctx, ctx.client.modals.guards) {
		return
	}
	$for m in T.methods {
		$if m.name == 'submit' {
			form.submit(mut ctx) or {
				handler_failed(form, mut ctx, err)
				handler_after_run(form, mut ctx, err)
				return
			}
			handler_after_run(form, mut ctx, none)
		}
	}
}

// Modals routes modal submissions to the types that declare them.
pub struct Modals {
mut:
	by_id  map[string]ModalInvoker
	guards []HandlerGuardFn
}

// use adds a guard that runs before every modal's `submit`, ahead of its own guards.
pub fn (mut r Modals) use[G HandlerGuard](g G) {
	r.guards << handler_guard_fn(g)
}

// add registers a modal type, whose `submit(mut ctx ModalContext) !` runs when a user sends it.
pub fn (mut r Modals) add[T](proto T) {
	if !has_method[T]('submit') {
		panic('veyfert: the modal ${T.name} needs a `submit` method')
	}
	r.by_id[modal_json(proto).custom_id] = ModalInvoker(ModalBound[T]{proto})
}

// handler_guards runs on_before_guards, the global guards and the handler's own guards; false
// means they stopped it.
fn handler_guards[T, C](mut handler T, mut ctx C, global []HandlerGuardFn) bool {
	$for m in T.methods {
		$if m.name == 'on_before_guards' {
			handler.on_before_guards(mut ctx) or {
				handler_internal_error(handler, mut ctx, 'on_before_guards', err)
				return false
			}
		}
	}
	for g in global {
		g(mut ctx.InteractionContext) or {
			handler_guard_failed(handler, mut ctx, err)
			return false
		}
	}
	$for field in T.fields {
		$if field.typ is HandlerGuard {
			mut g := handler.$(field.name)
			check_handler_guard(mut g, mut ctx.InteractionContext) or {
				handler_guard_failed(handler, mut ctx, err)
				return false
			}
			handler.$(field.name) = g
		}
	}
	return true
}

// handler_guard_failed: a silent stop ends the handler, a deny goes to on_guard_error or is
// answered, and any other error is a failure of the handler.
fn handler_guard_failed[T, C](handler T, mut ctx C, failure IError) {
	if failure is GuardStop {
		if failure.reason == '' {
			return
		}
		$for m in T.methods {
			$if m.name == 'on_guard_error' {
				handler.on_guard_error(mut ctx, failure.reason) or {
					handler_internal_error(handler, mut ctx, 'on_guard_error', err)
				}
				return
			}
		}
		ctx.reply_error(failure.reason) or {
			ctx.client.logger.error('${T.name}: the guard could not answer')
		}
		return
	}
	handler_failed(handler, mut ctx, failure)
}

// handler_failed calls the handler's `on_run_error` when it has one; otherwise it logs the error
// and tells the user something went wrong.
fn handler_failed[T, C](handler T, mut ctx C, failure IError) {
	$for m in T.methods {
		$if m.name == 'on_run_error' {
			handler.on_run_error(mut ctx, failure) or {
				handler_internal_error(handler, mut ctx, 'on_run_error', err)
			}
			return
		}
	}
	ctx.client.logger.error('${T.name}: ${failure}')
	ctx.reply_error('Something went wrong.') or {}
}

fn handler_after_run[T, C](handler T, mut ctx C, failure ?IError) {
	$for m in T.methods {
		$if m.name == 'on_after_run' {
			handler.on_after_run(mut ctx, failure) or {
				handler_internal_error(handler, mut ctx, 'on_after_run', err)
			}
		}
	}
}

// handler_internal_error handles an error that a hook returned: the handler's
// on_internal_error, or a log line.
fn handler_internal_error[T, C](handler T, mut ctx C, hook string, failure IError) {
	wrapped := error('${hook}: ${failure.msg()}')
	$for m in T.methods {
		$if m.name == 'on_internal_error' {
			handler.on_internal_error(mut ctx, wrapped) or {
				ctx.client.logger.error('on_internal_error of ${T.name}: ${err}')
			}
			return
		}
	}
	ctx.client.logger.error('${T.name}: ${wrapped}')
}

fn (mut c Client) run_component(i discord.Interaction, inline &InlineReply) {
	data := i.data or { return }
	custom_id := data.custom_id or { '' }
	invoker := c.components.find(custom_id) or {
		c.logger.warn('no handler for the component `${custom_id}`')
		return
	}
	mut ctx := &ComponentContext{
		interaction: i
		client:      c
		inline:      inline
		custom_id:   custom_id
		values:      data.values
	}
	invoker.invoke(mut ctx)
}

fn (mut c Client) run_modal(i discord.Interaction, inline &InlineReply) {
	data := i.data or { return }
	custom_id := data.custom_id or { '' }
	invoker := c.modals.by_id[custom_id] or {
		c.logger.warn('no handler for the modal `${custom_id}`')
		return
	}
	mut ctx := &ModalContext{
		interaction: i
		client:      c
		inline:      inline
		custom_id:   custom_id
	}
	invoker.invoke(mut ctx, modal_values(data.components or { discord.RawJson{} }))
}

// modal_json builds a modal from the fields of T that have @[Label], in their order.
fn modal_json[T](form T) ModalJson {
	mut m := ModalJson{}
	$for a in T.attributes {
		$if a is Modal {
			m.custom_id = a.custom_id
			m.title = a.title
		}
	}
	if m.custom_id == '' || m.title == '' {
		panic('veyfert: ${T.name} needs @[veyfert.Modal(custom_id: ..., title: ...)]')
	}
	$for field in T.fields {
		mut description := ?string(none)
		mut placeholder := ?string(none)
		mut style := discord.TextInputStyle.short
		mut min := ?int(none)
		mut max := ?int(none)
		$for a in field.attributes {
			$if a is Desc {
				description = a.text
			} $else $if a is Placeholder {
				placeholder = a.text
			} $else $if a is Paragraph {
				style = .paragraph
			} $else $if a is MinLength {
				min = a.value
			} $else $if a is MaxLength {
				max = a.value
			}
		}
		$for a in field.attributes {
			$if a is Label {
				mut input := discord.Component{}
				mut choices := []ChoiceJson{}
				$if field.is_enum {
					$if field.is_option {
						choices = enum_choices_opt(form.$(field.name))
					} $else {
						choices = enum_choices(form.$(field.name))
					}
					input = discord.string_select(
						custom_id:   field.name
						placeholder: placeholder
						required:    !field.is_option
						options:     choices.map(discord.SelectOption{
							label: it.name
							value: it.value
						})
					)
				} $else $if field.typ is string {
					value := form.$(field.name)
					input = discord.text_input(
						custom_id:   field.name
						style:       style
						placeholder: placeholder
						value:       if value != '' { value } else { none }
						required:    true
						min_length:  min
						max_length:  max
					)
				} $else $if field.typ is ?string {
					input = discord.text_input(
						custom_id:   field.name
						style:       style
						placeholder: placeholder
						value:       form.$(field.name)
						required:    false
						min_length:  min
						max_length:  max
					)
				} $else {
					$compile_error('veyfert: unsupported modal field type; use string, ?string, an enum or ?enum')
				}
				m.components << discord.label(a.text, input, description)
			}
		}
	}
	if m.components.len == 0 || m.components.len > 5 {
		panic('veyfert: the modal ${T.name} has ${m.components.len} inputs; Discord allows 1 to 5')
	}
	return m
}

// fill_modal copies the values a user sent into the fields of `form`.
fn fill_modal[T](mut form T, values map[string][]string) ! {
	$for field in T.fields {
		$for a in field.attributes {
			$if a is Label {
				got := values[field.name] or { []string{} }
				value := if got.len > 0 { got[0] } else { '' }
				$if field.is_enum {
					if value != '' {
						$if field.is_option {
							form.$(field.name) = parse_enum_opt(form.$(field.name), value)!
						} $else {
							form.$(field.name) = int(parse_enum(form.$(field.name), value)!)
						}
					} else if !field.is_option {
						return error('`${field.name}` is missing')
					}
				} $else $if field.typ is string {
					form.$(field.name) = value
				} $else $if field.typ is ?string {
					if value != '' {
						form.$(field.name) = value
					}
				}
			}
		}
	}
}

// modal_values reads a modal submission: custom_id to the values sent. Inputs come inside labels
// or, in older modals, inside action rows.
fn modal_values(components discord.RawJson) map[string][]string {
	mut out := map[string][]string{}
	if components.text != '' {
		tree := json2.decode[json2.Any](components.text) or { return out }
		collect_values(tree, mut out)
	}
	return out
}

fn collect_values(node json2.Any, mut out map[string][]string) {
	match node {
		[]json2.Any {
			for child in node {
				collect_values(child, mut out)
			}
		}
		map[string]json2.Any {
			if id := node['custom_id'] {
				if value := node['value'] {
					out[id.str()] = [value.str()]
				} else if values := node['values'] {
					out[id.str()] = values.as_array().map(it.str())
				}
			}
			if child := node['component'] {
				collect_values(child, mut out)
			}
			if children := node['components'] {
				collect_values(children, mut out)
			}
		}
		else {}
	}
}
