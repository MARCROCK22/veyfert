module veyfert

import json2
import log
import os
import crypto.rand as crand
import sync
import time
import v.vmod
import veyfert.cache
import veyfert.discord
import veyfert.rest

const manifest = vmod.decode(@VMOD_FILE) or { vmod.Manifest{} }

@[params]
pub struct ClientOptions {
pub:
	token               string @[required]
	intents             discord.Intents = .guilds
	shards              ?ShardRange // default: as many shards as Discord recommends
	workers             int = 4 // threads that run listeners; 1 runs them in order
	interaction_workers int = 4 // threads that run commands, apart so the 3-second deadline holds
	presence            ?discord.Presence // sent by every shard when it identifies
	compress            bool              // Discord compresses large payloads with zlib
	zstd                bool              // compress the whole connection with zstd-stream; build with -d veyfert_zstd
	gateway_url         string            // replaces Discord's gateway URL, e.g. for a proxy or tests
	cache               cache.Options
	prefixes            []string // run commands from messages that start with these, or mention the bot
	// The largest gateway message accepted. A GUILD_CREATE of a huge server can pass the 8 MiB
	// default; raise it then, or use `compress`.
	max_message_bytes int = 8 * 1024 * 1024
	// Sessions saved by a previous run (`Client.sessions`): those shards resume instead of
	// identifying.
	sessions []ShardSession
}

// Client owns the gateway connections, the REST client, and the registered commands and listeners.
@[heap; noinit]
pub struct Client {
pub mut:
	commands   Commands
	components Components
	modals     Modals
	messages   MessageShorter
	reactions  ReactionShorter
	channels   ChannelShorter
	members    MemberShorter
	roles      RoleShorter
	guilds     GuildShorter
	users      UserShorter
	threads    ThreadShorter
	webhooks   WebhookShorter
	bans       BanShorter
	emojis     EmojiShorter
	// application, monetization and interactions ask Discord for the application ID once when
	// the gateway has not given it.
	application  ApplicationShorter
	monetization MonetizationShorter
	interactions InteractionShorter
	invites      InviteShorter
	soundboard   SoundboardShorter
	stages       StageShorter
	templates    TemplateShorter
	voice_states VoiceStateShorter
	cache        &cache.Cache
	rest         rest.Rest
	logger       &log.ThreadSafeLog
mut:
	intents              discord.Intents
	compress             bool
	zstd                 bool
	presence             ?discord.Presence
	gateway_url          string
	max_message_bytes    int
	saved_sessions       []ShardSession
	shard_range          ?ShardRange
	workers              int
	interaction_workers  int
	shards               []&Shard
	total_shards         int
	identify_queue       &IdentifyQueue
	reconnect_backoff    time.Duration = time.second
	invalid_session_wait time.Duration
	// Guards the fields below, which shards, workers and callers share.
	mu             &sync.Mutex = sync.new_mutex()
	listeners      map[string][]Listener
	raw_listeners  []fn (RawEvent, mut Client) !
	collectors     map[string]map[int]Collector
	next_collector int
	member_waits   map[string]&MemberWait
	dedupe         Deduper
	ready_shards   map[int]bool
	bot_ready_sent bool
	user           discord.User
	app_id         discord.Snowflake
	// The handler pool.
	plugins           []Plugin
	interceptors      []fn (name string, raw string) ?string
	send_interceptors []fn (shard int, payload string) ?string
	jobs              chan Job
	interaction_jobs  chan Job
	workers_started   bool
}

pub fn new_client(opts ClientOptions) &Client {
	token := opts.token.trim_space()
	mut logger := log.new_thread_safe_log()
	// A bot's logs must reach files and pipes line by line, not when the process exits.
	logger.set_always_flush(true)
	mut c := &Client{
		rest:                 rest.Rest{
			token:      token
			user_agent: 'DiscordBot (https://github.com/veyfert, ${manifest.version})'
		}
		logger:               logger
		cache:                &cache.Cache{
			options: opts.cache
		}
		intents:              opts.intents
		compress:             opts.compress && !opts.zstd
		zstd:                 opts.zstd
		presence:             opts.presence
		gateway_url:          opts.gateway_url
		max_message_bytes:    opts.max_message_bytes
		saved_sessions:       opts.sessions
		shard_range:          opts.shards
		workers:              if opts.workers > 0 { opts.workers } else { 1 }
		interaction_workers:  if opts.interaction_workers > 0 {
			opts.interaction_workers
		} else {
			1
		}
		identify_queue:       &IdentifyQueue{}
		invalid_session_wait: time.Duration(1000 + (crand.int_u64(4000) or { 1500 })) * time.millisecond
		jobs:                 chan Job{cap: 1024}
		interaction_jobs:     chan Job{cap: 256}
	}
	if opts.prefixes.len > 0 {
		prefixes := opts.prefixes.clone()
		c.commands.prefix = fn [prefixes] (_ discord.Message) []string {
			return prefixes
		}
	}
	c.messages.client = c
	c.reactions.client = c
	c.channels.client = c
	c.members.client = c
	c.roles.client = c
	c.guilds.client = c
	c.users.client = c
	c.threads.client = c
	c.webhooks.client = c
	c.bans.client = c
	c.emojis.client = c
	c.application.client = c
	c.monetization.client = c
	c.interactions.client = c
	c.invites.client = c
	c.soundboard.client = c
	c.stages.client = c
	c.templates.client = c
	c.voice_states.client = c
	c.guilds.audit.client = c
	c.guilds.onboarding.client = c
	c.guilds.welcome.client = c
	c.guilds.widget.client = c
	c.guilds.moderation.client = c
	c.guilds.events.client = c
	c.guilds.stickers.client = c
	return c
}

// bot_id is the bot's user ID: the one READY gave, or asked to Discord once.
pub fn (mut c Client) bot_id() !discord.Snowflake {
	c.mu.lock()
	id := c.user.id
	c.mu.unlock()
	if id.value != 0 {
		return id
	}
	me := json2.decode[discord.User](c.rest.request(.get, '/users/@me')!)!
	c.mu.lock()
	if c.user.id.value == 0 {
		c.user = me
	}
	c.mu.unlock()
	return me.id
}

// application_id is the bot's application ID: the one READY gave, or asked to Discord once.
pub fn (mut c Client) application_id() !discord.Snowflake {
	c.mu.lock()
	id := c.app_id
	c.mu.unlock()
	if id.value != 0 {
		return id
	}
	app := json2.decode[discord.Application](c.rest.request(.get, '/applications/@me')!)!
	c.mu.lock()
	c.app_id = app.id
	c.mu.unlock()
	return app.id
}

fn (mut c Client) handle_interaction(raw string) {
	i := json2.decode[discord.Interaction](raw) or {
		c.logger.error('interaction: ${err}')
		return
	}
	c.route_interaction(i, unsafe { nil })
}

fn (mut c Client) route_interaction(i discord.Interaction, inline &InlineReply) {
	match i.kind {
		2 { c.run_command(i, inline) }
		3 { c.run_component(i, inline) }
		4 { c.run_autocomplete(i, inline) }
		5 { c.run_modal(i, inline) }
		else {}
	}
}

@[params]
pub struct UploadOptions {
pub:
	guild_id   ?discord.Snowflake // uploads every command to this test guild, where changes apply at once
	cache_path string             // when set, skips the upload if these commands were already uploaded
}

// upload_commands registers the commands with Discord, replacing the previous set of each scope:
// global commands globally and @[Guilds] commands in their servers, or all of them in `guild_id`.
pub fn (mut c Client) upload_commands(opts UploadOptions) ! {
	app := c.rest.get[discord.Application]('/oauth2/applications/@me')!
	mut scopes := map[string][]CommandJson{}
	if guild_id := opts.guild_id {
		scopes['/applications/${app.id}/guilds/${guild_id}/commands'] = c.commands.entries.filter(it.slash).map(it.json)
	} else {
		scopes['/applications/${app.id}/commands'] = []CommandJson{}
		for e in c.commands.entries.filter(it.slash) {
			if e.guilds.len == 0 {
				scopes['/applications/${app.id}/commands'] << e.json
			}
			for g in e.guilds {
				scopes['/applications/${app.id}/guilds/${g}/commands'] << e.json
			}
		}
	}
	mut stamp := ''
	for path, commands in scopes {
		stamp += '${path}
${json2.encode(commands)}
'
	}
	if opts.cache_path != '' && os.exists(opts.cache_path) {
		if os.read_file(opts.cache_path)! == stamp {
			c.logger.info('commands unchanged, upload skipped')
			return
		}
	}
	for path, commands in scopes {
		c.rest.request(.put, path, body: json2.encode(commands))!
		c.logger.info('uploaded ${commands.len} commands to ${path}')
	}
	if opts.cache_path != '' {
		os.mkdir_all(os.dir(opts.cache_path))!
		os.write_file(opts.cache_path, stamp)!
	}
}
