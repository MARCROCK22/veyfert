module main

import os
import time
import veyfert
import veyfert.discord

// Build from the repo root, adding the folder that contains this checkout to the module path:
//   v -path "@vlib|@vmodules|<parent of veyfert>" run examples/basic
// Set DISCORD_TOKEN, and GUILD_ID to a test server so command changes apply at once.

@[veyfert.Declare(name: 'ping', description: 'Responde con la latencia del gateway')]
struct Ping {}

fn (c Ping) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Pong! Latencia del gateway: ${ctx.client.latency().milliseconds()} ms')!
}

enum Orden {
	alfabetico  @[veyfert.Label: 'Alfabético']
	inverso     @[veyfert.Label: 'Alfabético inverso']
}

struct Catalogo {
	items []string
}

@[veyfert.Declare(name: 'buscar', description: 'Busca en un catálogo de prueba')]
struct Buscar {
	catalogo &Catalogo // sin atributo: es una dependencia y viaja con el prototipo
mut:
	// Un campo cuyo tipo es un guard corre antes de `run`; su estado llega a `run`.
	cd     veyfert.Cooldown = veyfert.cooldown(3, 20 * time.second)
	texto  string @[veyfert.Autocomplete; veyfert.Desc: 'Qué buscar'; veyfert.MaxLength: 30]
	limite ?int   @[veyfert.Desc: 'Máximo de resultados'; veyfert.Max: 10; veyfert.Min: 1]
	orden  ?Orden @[veyfert.Desc: 'Cómo ordenar los resultados']
}

fn (c Buscar) run(mut ctx veyfert.CommandContext) ! {
	mut hits := c.catalogo.items.filter(it.contains(c.texto.to_lower()))
	hits.sort()
	if c.orden or { Orden.alfabetico } == .inverso {
		hits.reverse_in_place()
	}
	hits = hits#[..c.limite or { 5 }]
	ctx.write(
		embeds: [
			discord.Embed{
				title:       'Resultados para "${c.texto}" (te quedan ${c.cd.remaining} búsquedas)'
				description: if hits.len > 0 {
					hits.map('• ${it}').join('
')
				} else {
					'Sin resultados'
				}
				color:       0x5865F2
			},
		]
	)!
}

// autocomplete sugiere entradas del catálogo mientras el usuario escribe.
fn (c Buscar) autocomplete(mut ctx veyfert.AutocompleteContext) ! {
	ctx.respond(c.catalogo.items.filter(it.contains(ctx.value.to_lower())).map(veyfert.Choice{
		name:  it
		value: it
	}))!
}

@[veyfert.Declare(name: 'yo', description: 'Pide tu miembro al gateway y muestra lo que llega')]
struct Yo {}

fn (c Yo) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.interaction.guild_id or { return error('solo funciona en servidores') }
	author := ctx.author()
	members := ctx.client.request_members(
		guild_id: guild_id
		user_ids: [author.id]
		timeout:  2 * time.second
	)!
	member := members[0] or { return error('el gateway no devolvió el miembro') }
	nick := member.nick or { author.global_name or { author.username } }
	ctx.write(
		content: 'Shard ${ctx.client.shard_id_for(guild_id)}: ${nick}, con ${member.roles.len} roles'
	)!
}

// Cualquiera puede usarlo: es un bot de prueba.
@[veyfert.Declare(name: 'reconectar', description: 'Corta la conexión del shard para comprobar que reanuda la sesión')]
struct Reconectar {}

fn (c Reconectar) run(mut ctx veyfert.CommandContext) ! {
	guild_id := ctx.interaction.guild_id or { return error('solo funciona en servidores') }
	shard := ctx.client.shard_id_for(guild_id)
	ctx.write(content: 'Corto la conexión del shard ${shard}; debería reanudar la sesión.')!
	ctx.client.reconnect(shard)!
}

// /config es un árbol: `config saludo` y el grupo `config mod` con `aviso`.
@[veyfert.Declare(name: 'saludo', description: 'Cambia el saludo del servidor')]
struct Saludo {
mut:
	texto string @[veyfert.Desc: 'El saludo nuevo'; veyfert.MaxLength: 100; veyfert.MinLength: 2]
}

fn (c Saludo) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(content: 'Saludo cambiado a «${c.texto}» (en ${ctx.path})', ephemeral: true)!
}

@[veyfert.Declare(name: 'aviso', description: 'Avisa a un miembro')]
struct Aviso {
mut:
	miembro discord.Member   @[veyfert.Desc: 'A quién avisar']
	motivo  ?string          @[veyfert.Desc: 'Por qué']
	canal   ?discord.Channel @[veyfert.Channels: 'guild_text'; veyfert.Desc: 'Dónde avisar']
}

fn (c Aviso) run(mut ctx veyfert.CommandContext) ! {
	user := c.miembro.user or { discord.User{} }
	canal := if ch := c.canal { ' en #${ch.name or { '?' }}' } else { '' }
	ctx.write(
		content: '${user.username} (${c.miembro.roles.len} roles) recibiría un aviso${canal}: ${c.motivo or { 'sin motivo' }}'
	)!
}

@[veyfert.Declare(name: 'mod', description: 'Moderación')]
struct Mod {
mut:
	// Un guard en un grupo corre antes de cada subcomando del grupo.
	permisos veyfert.RequirePermissions = veyfert.require_permissions(.manage_messages)
	aviso    Aviso @[veyfert.Sub]
}

@[veyfert.Contexts('guild')]
@[veyfert.Declare(name: 'config', description: 'Ajustes del servidor')]
struct Config {
mut:
	saludo Saludo @[veyfert.Sub]
	mod    Mod    @[veyfert.Sub]
}

@[veyfert.Declare(name: 'lento', description: 'Difiere la respuesta, la edita y manda un seguimiento')]
struct Lento {}

fn (c Lento) run(mut ctx veyfert.CommandContext) ! {
	ctx.defer_reply(false)!
	time.sleep(2 * time.second)
	ctx.edit_response(content: 'Listo tras 2 s de trabajo.')!
	ctx.followup(content: 'Y esto es un seguimiento que solo ves tú.', ephemeral: true)!
}

@[veyfert.UserMenu('Ver avatar')]
struct VerAvatar {}

fn (c VerAvatar) run(mut ctx veyfert.CommandContext) ! {
	user := ctx.target_user() or { return error('sin usuario') }
	ctx.write(content: '${user.username}: ${user.avatar_url(size: 256)}', ephemeral: true)!
}

@[veyfert.MessageMenu('Contar palabras')]
struct ContarPalabras {}

fn (c ContarPalabras) run(mut ctx veyfert.CommandContext) ! {
	msg := ctx.target_message() or { return error('sin mensaje') }
	ctx.write(content: 'Ese mensaje tiene ${msg.content.fields().len} palabras.', ephemeral: true)!
}

fn main() {
	mut bot := veyfert.new_client(
		token:    os.getenv('DISCORD_TOKEN')
		intents:  .guilds | .guild_messages
		// The same commands run from messages: `!ping`, or `@bot ping` without MESSAGE_CONTENT.
		prefixes: ['!']
		presence: discord.Presence{
			activities: [discord.Activity{
				name: 'comandos en V'
				kind: .listening
			}]
		}
	)
	catalogo := &Catalogo{
		items: ['vlang', 'v-analyzer', 'vpm', 'veb', 'vsl', 'vtl', 'discord', 'seyfert', 'veyfert']
	}
	bot.commands.add(Ping{})
	bot.commands.add(Buscar{ catalogo: catalogo })
	bot.commands.add(Yo{})
	bot.commands.add(Reconectar{})
	bot.commands.add(Config{})
	bot.commands.add(Lento{})
	bot.commands.add(VerAvatar{})
	bot.commands.add(ContarPalabras{})
	bot.on[veyfert.GuildsReady](fn (e veyfert.GuildsReady, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard}: ${e.guilds} servidores cargados')
	})
	bot.on[veyfert.BotReady](fn (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('Listo como ${e.user.username} con ${e.shards} shard(s)')
	})
	bot.on[veyfert.ShardDisconnect](fn (e veyfert.ShardDisconnect, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard} desconectado (${e.code}); reanudará: ${e.resumable}')
	})
	bot.on[veyfert.ShardReconnect](fn (e veyfert.ShardReconnect, mut c veyfert.Client) ! {
		c.logger.info('Shard ${e.shard} de vuelta; sesión reanudada: ${e.resumed}')
	})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/commands.json'
	)!
	bot.run()!
}
