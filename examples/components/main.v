module main

import os
import time
import veyfert
import veyfert.discord

// Components, modals and polls. Build it like examples/basic:
//   v -path "@vlib|@vmodules|<parent of veyfert>" run examples/components
// Uploading to GUILD_ID replaces the commands of the other example in that server.

@[veyfert.Declare(name: 'botones', description: 'Botones y un menú de selección')]
struct Botones {}

fn (c Botones) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    '¿Qué eliges?'
		components: [
			discord.action_row(discord.button(style: .success, label: 'Uno', custom_id: 'voto:uno'),
				discord.button(style: .primary, label: 'Dos', custom_id: 'voto:dos')),
			discord.action_row(discord.string_select(
				custom_id:   'voto:menu'
				placeholder: 'O elige aquí'
				options:     [discord.SelectOption{
					label: 'Tres'
					value: 'tres'
				}, discord.SelectOption{
					label: 'Cuatro'
					value: 'cuatro'
				}]
			)),
		]
	)!
}

// Voto atiende todos los custom_id que empiezan por 'voto:'.
@[veyfert.CustomIdPrefix('voto:')]
struct Voto {}

fn (h Voto) run(mut ctx veyfert.ComponentContext) ! {
	choice := if ctx.values.len > 0 { ctx.values[0] } else { ctx.custom_id.all_after(':') }
	ctx.update(content: '${ctx.author().username} eligió ${choice}', components: [])!
}

@[veyfert.Declare(name: 'confirmar', description: 'Espera tu clic dentro del propio comando')]
struct Confirmar {}

fn (c Confirmar) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		content:    '¿Seguro?'
		components: [
			discord.action_row(discord.button(
				style:     .danger
				label:     'Sí'
				custom_id: 'confirmar:si'
			),
				discord.button(label: 'No', custom_id: 'confirmar:no')),
		]
	)!
	mut click := ctx.wait_for_component(timeout: 30 * time.second) or {
		ctx.edit_response(content: 'Se acabó el tiempo.', components: [])!
		return
	}
	click.update(
		content:    if click.custom_id == 'confirmar:si' { 'Hecho.' } else { 'Cancelado.' }
		components: []
	)!
}

@[veyfert.Declare(name: 'tarjeta', description: 'Un mensaje con components v2')]
struct Tarjeta {}

fn (c Tarjeta) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		components: [
			discord.container([
				discord.section(['## veyfert', 'Components v2 desde structs de V'], discord.thumbnail('https://vlang.io/img/v-logo.png')),
				discord.separator(),
				discord.text_display('El flag IS_COMPONENTS_V2 se pone solo.'),
				discord.action_row(discord.button(label: 'V', url: 'https://vlang.io')),
			], accent_color: 0x5865F2),
		]
	)!
}

enum Animo {
	contento  @[veyfert.Label: 'Contento']
	cansado   @[veyfert.Label: 'Cansado']
}

// Opinion es un modal: los campos con Label son sus entradas, y llegan rellenos a `submit`.
@[veyfert.Modal(custom_id: 'opinion', title: 'Tu opinión')]
struct Opinion {
mut:
	texto string  @[veyfert.Label: 'Cuéntanos'; veyfert.MaxLength: 500; veyfert.Paragraph]
	email ?string @[veyfert.Desc: 'Por si quieres respuesta'; veyfert.Label: 'Email']
	animo ?Animo  @[veyfert.Label: '¿Cómo estás?']
}

fn (f Opinion) submit(mut ctx veyfert.ModalContext) ! {
	ctx.write(
		content:   'Gracias: «${f.texto}» (${f.animo or { Animo.contento }}, ${f.email or { 'sin email' }})'
		ephemeral: true
	)!
}

@[veyfert.Declare(name: 'opinar', description: 'Abre un modal')]
struct Opinar {}

fn (c Opinar) run(mut ctx veyfert.CommandContext) ! {
	ctx.modal(Opinion{})!
}

@[veyfert.Declare(name: 'encuesta', description: 'Crea una encuesta de una hora')]
struct Encuesta {
mut:
	pregunta string @[veyfert.Desc: 'La pregunta'; veyfert.MaxLength: 300]
	opciones string @[veyfert.Desc: 'Respuestas separadas por comas']
}

fn (c Encuesta) run(mut ctx veyfert.CommandContext) ! {
	ctx.write(
		poll: discord.poll(c.pregunta, c.opciones.split(',').map(it.trim_space()), 1,
			false)
	)!
}

fn main() {
	mut bot := veyfert.new_client(token: os.getenv('DISCORD_TOKEN'))
	bot.commands.add(Botones{})
	bot.commands.add(Confirmar{})
	bot.commands.add(Tarjeta{})
	bot.commands.add(Opinar{})
	bot.commands.add(Encuesta{})
	bot.components.add(Voto{})
	bot.modals.add(Opinion{})
	guild_id := os.getenv('GUILD_ID')
	bot.upload_commands(
		guild_id:   if guild_id != '' { discord.Snowflake.parse(guild_id)! } else { none }
		cache_path: '.veyfert/components.json'
	)!
	bot.run()!
}
