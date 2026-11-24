module discord

import json2

// Message flags for `MessageOptions.flags`; `ephemeral` and components v2 are set for you.
pub const message_flag_suppress_embeds = 1 << 2
pub const message_flag_ephemeral = 1 << 6
pub const message_flag_suppress_notifications = 1 << 12
pub const message_flag_components_v2 = 1 << 15

@[json_as_number]
pub enum ComponentType {
	action_row         = 1
	button             = 2
	string_select      = 3
	text_input         = 4
	user_select        = 5
	role_select        = 6
	mentionable_select = 7
	channel_select     = 8
	section            = 9
	text_display       = 10
	thumbnail          = 11
	media_gallery      = 12
	file               = 13
	separator          = 14
	container          = 17
	label              = 18
	file_upload        = 19
	radio_group        = 21
	checkbox_group     = 22
	checkbox           = 23
}

pub enum ButtonStyle {
	primary   = 1
	secondary = 2
	success   = 3
	danger    = 4
	link      = 5
	premium   = 6
}

pub enum TextInputStyle {
	short     = 1
	paragraph = 2
}

pub enum SeparatorSpacing {
	small = 1
	large = 2
}

// Emoji is a custom emoji (`id` and `name`) or a Unicode one (`name` only).
pub struct Emoji {
pub:
	id       ?Snowflake
	name     string
	animated ?bool
}

// SelectOption is an option of a string select, a radio group or a checkbox group.
pub struct SelectOption {
pub:
	label       string
	value       string
	description ?string
	emoji       ?Emoji
	default     ?bool
}

// DefaultValue preselects a user, role or channel in a select that Discord fills.
pub struct DefaultValue {
pub:
	id   Snowflake
	kind string @[json: 'type'] // 'user', 'role' or 'channel'
}

// Media is a URL to show: http(s), or attachment://name for a file sent with the message.
pub struct Media {
pub:
	url string
}

pub struct MediaItem {
pub:
	media       Media
	description ?string
	spoiler     ?bool
}

// Component is any message or modal component, flat as in Discord's JSON: `kind` says which
// fields apply. Build components with the constructors below.
pub struct Component {
pub:
	kind           ComponentType @[json: 'type']
	id             ?int
	custom_id      ?string
	style          ?int
	label          ?string
	emoji          ?Emoji
	url            ?string
	sku_id         ?Snowflake
	disabled       ?bool
	placeholder    ?string
	min_values     ?int
	max_values     ?int
	required       ?bool
	options        ?[]SelectOption
	default_values ?[]DefaultValue
	channel_types  ?[]int
	value          ?string
	min_length     ?int
	max_length     ?int
	content        ?string
	media          ?Media
	description    ?string
	spoiler        ?bool
	items          ?[]MediaItem
	file           ?Media
	divider        ?bool
	spacing        ?int
	accent_color   ?int
	default        ?bool
	file_types     ?[]string
	components     ?[]Component
	// The one child of a section (`accessory`) or of a label (`component`). V structs cannot
	// hold themselves, so the constructors store it already encoded.
	accessory ?RawJson
	component ?RawJson
}

pub fn action_row(components ...Component) Component {
	return Component{
		kind:       .action_row
		components: components
	}
}

@[params]
pub struct ButtonOptions {
pub:
	style     ButtonStyle = .secondary
	label     ?string
	emoji     ?Emoji
	custom_id ?string // what handlers route on; link and premium buttons have none
	url       ?string // a link button; the style becomes .link
	sku_id    ?Snowflake
	disabled  bool
	id        ?int
}

pub fn button(opts ButtonOptions) Component {
	return Component{
		kind:      .button
		style:     if opts.url != none { int(ButtonStyle.link) } else { int(opts.style) }
		label:     opts.label
		emoji:     opts.emoji
		custom_id: opts.custom_id
		url:       opts.url
		sku_id:    opts.sku_id
		disabled:  if opts.disabled { true } else { none }
		id:        opts.id
	}
}

@[params]
pub struct SelectMenuOptions {
pub:
	custom_id      string @[required]
	placeholder    ?string
	min_values     ?int
	max_values     ?int
	disabled       bool
	required       ?bool          // in modals
	options        []SelectOption // string selects
	default_values []DefaultValue // user, role, mentionable and channel selects
	channel_types  []int          // channel selects
	id             ?int
}

pub fn string_select(opts SelectMenuOptions) Component {
	return select_menu(.string_select, opts)
}

pub fn user_select(opts SelectMenuOptions) Component {
	return select_menu(.user_select, opts)
}

pub fn role_select(opts SelectMenuOptions) Component {
	return select_menu(.role_select, opts)
}

pub fn mentionable_select(opts SelectMenuOptions) Component {
	return select_menu(.mentionable_select, opts)
}

pub fn channel_select(opts SelectMenuOptions) Component {
	return select_menu(.channel_select, opts)
}

fn select_menu(kind ComponentType, opts SelectMenuOptions) Component {
	return Component{
		kind:           kind
		custom_id:      opts.custom_id
		placeholder:    opts.placeholder
		min_values:     opts.min_values
		max_values:     opts.max_values
		disabled:       if opts.disabled { true } else { none }
		required:       opts.required
		options:        if kind == .string_select { opts.options } else { none }
		default_values: if opts.default_values.len > 0 { opts.default_values } else { none }
		channel_types:  if opts.channel_types.len > 0 { opts.channel_types } else { none }
		id:             opts.id
	}
}

@[params]
pub struct TextInputOptions {
pub:
	custom_id   string @[required]
	style       TextInputStyle = .short
	placeholder ?string
	value       ?string // prefilled text
	required    ?bool
	min_length  ?int
	max_length  ?int
	id          ?int
}

// text_input is a modal text field; put it in a `label`.
pub fn text_input(opts TextInputOptions) Component {
	return Component{
		kind:        .text_input
		custom_id:   opts.custom_id
		style:       int(opts.style)
		placeholder: opts.placeholder
		value:       opts.value
		required:    opts.required
		min_length:  opts.min_length
		max_length:  opts.max_length
		id:          opts.id
	}
}

// text_display is markdown text, for components v2 messages and modals.
pub fn text_display(content string) Component {
	return Component{
		kind:    .text_display
		content: content
	}
}

// section shows up to 3 texts with a button or a thumbnail beside them.
pub fn section(texts []string, accessory Component) Component {
	return Component{
		kind:       .section
		components: texts.map(text_display(it))
		accessory:  RawJson{json2.encode(accessory)}
	}
}

@[params]
pub struct MediaOptions {
pub:
	description ?string // alt text
	spoiler     bool
}

pub fn thumbnail(url string, opts MediaOptions) Component {
	return Component{
		kind:        .thumbnail
		media:       Media{url}
		description: opts.description
		spoiler:     if opts.spoiler { true } else { none }
	}
}

pub fn media_gallery(items ...MediaItem) Component {
	return Component{
		kind:  .media_gallery
		items: items
	}
}

// file_component shows a file sent with the message: `url` is attachment://name.
pub fn file_component(url string, opts MediaOptions) Component {
	return Component{
		kind:    .file
		file:    Media{url}
		spoiler: if opts.spoiler { true } else { none }
	}
}

@[params]
pub struct SeparatorOptions {
pub:
	divider bool             = true
	spacing SeparatorSpacing = .small
}

pub fn separator(opts SeparatorOptions) Component {
	return Component{
		kind:    .separator
		divider: opts.divider
		spacing: int(opts.spacing)
	}
}

@[params]
pub struct ContainerOptions {
pub:
	accent_color ?int
	spoiler      bool
}

// container groups components v2 under an optional accent color, like an embed.
pub fn container(components []Component, opts ContainerOptions) Component {
	return Component{
		kind:         .container
		components:   components
		accent_color: opts.accent_color
		spoiler:      if opts.spoiler { true } else { none }
	}
}

// label titles one modal input: a text input, a select, a file upload or a choice group.
pub fn label(text string, input Component, description ?string) Component {
	return Component{
		kind:        .label
		label:       text
		description: description
		component:   RawJson{json2.encode(input)}
	}
}

@[params]
pub struct ChoiceGroupOptions {
pub:
	required   ?bool
	min_values ?int // checkbox groups and file uploads
	max_values ?int
	file_types []string // file uploads, such as ['.png', '.jpg']
}

pub fn file_upload(custom_id string, opts ChoiceGroupOptions) Component {
	return Component{
		kind:       .file_upload
		custom_id:  custom_id
		required:   opts.required
		min_values: opts.min_values
		max_values: opts.max_values
		file_types: if opts.file_types.len > 0 { opts.file_types } else { none }
	}
}

pub fn radio_group(custom_id string, options []SelectOption, opts ChoiceGroupOptions) Component {
	return Component{
		kind:      .radio_group
		custom_id: custom_id
		options:   options
		required:  opts.required
	}
}

pub fn checkbox_group(custom_id string, options []SelectOption, opts ChoiceGroupOptions) Component {
	return Component{
		kind:       .checkbox_group
		custom_id:  custom_id
		options:    options
		required:   opts.required
		min_values: opts.min_values
		max_values: opts.max_values
	}
}

pub fn checkbox(custom_id string, checked bool) Component {
	return Component{
		kind:      .checkbox
		custom_id: custom_id
		default:   if checked { true } else { none }
	}
}

// Poll is a poll to send, for `MessageOptions.poll`; `poll(...)` builds the usual one.
pub struct Poll {
pub:
	question          PollText
	answers           []PollAnswer
	allow_multiselect bool
	duration          int // hours, 1 to 768
	layout_type       ?int
}

pub struct PollAnswer {
pub:
	poll_media PollText
}

pub struct PollText {
pub:
	text  ?string
	emoji ?Emoji
}

// poll builds a poll: up to 10 answers, open for `hours` (1 to 768).
pub fn poll(question string, answers []string, hours int, multiselect bool) Poll {
	return Poll{
		question:          PollText{
			text: question
		}
		answers:           answers.map(PollAnswer{
			poll_media: PollText{
				text: it
			}
		})
		duration:          hours
		allow_multiselect: multiselect
	}
}

// AllowedMentions limits who a message pings: `parse` takes 'users', 'roles' or 'everyone',
// and `users` and `roles` list IDs.
pub struct AllowedMentions {
pub:
	parse        ?[]string
	users        ?[]Snowflake
	roles        ?[]Snowflake
	replied_user ?bool
}

const channel_type_names = {
	'guild_text':          0
	'dm':                  1
	'guild_voice':         2
	'group_dm':            3
	'guild_category':      4
	'guild_announcement':  5
	'announcement_thread': 10
	'public_thread':       11
	'private_thread':      12
	'guild_stage_voice':   13
	'guild_directory':     14
	'guild_forum':         15
	'guild_media':         16
}

// channel_type reads a channel type by name, such as 'guild_text', or by number.
pub fn channel_type(name string) ?int {
	if name.is_int() {
		return name.int()
	}
	return channel_type_names[name] or { return none }
}

pub struct Embed {
pub:
	title       ?string
	description ?string
	url         ?string
	timestamp   ?string // ISO 8601, such as time.now().format_rfc3339()
	color       ?int
	footer      ?EmbedFooter
	image       ?Media
	thumbnail   ?Media
	author      ?EmbedAuthor
	fields      []EmbedField
}

pub struct EmbedFooter {
pub:
	text     string
	icon_url ?string
}

pub struct EmbedAuthor {
pub:
	name     string
	url      ?string
	icon_url ?string
}

pub struct EmbedField {
pub:
	name   string
	value  string
	inline bool
}

// validate checks Discord's limits, so a message fails here with a clear error instead of with
// Discord's form errors. Messages are validated before they are sent.
pub fn (e Embed) validate() ! {
	mut total := 0
	total += check_length('title', e.title or { '' }, 256)!
	total += check_length('description', e.description or { '' }, 4096)!
	if footer := e.footer {
		total += check_length('footer text', footer.text, 2048)!
	}
	if author := e.author {
		total += check_length('author name', author.name, 256)!
	}
	if e.fields.len > 25 {
		return error('veyfert: an embed has ${e.fields.len} fields; Discord allows 25')
	}
	for f in e.fields {
		total += check_length('field name', f.name, 256)!
		total += check_length('field value', f.value, 1024)!
	}
	if total > 6000 {
		return error('veyfert: an embed has ${total} characters; Discord allows 6000 in total')
	}
}

fn check_length(what string, text string, max int) !int {
	n := text.runes().len
	if n > max {
		return error('veyfert: an embed ${what} has ${n} characters; Discord allows ${max}')
	}
	return n
}
