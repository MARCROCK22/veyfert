module veyfert

import json2
import veyfert.discord

struct Texts {
	hello    string                  @[required]
	farewell fn (name string) string @[required]
	ping     CommandText             @[required]
}

// Constants of a struct with function fields compile, so languages can live in consts.
const english = Texts{
	hello:    'Hello'
	farewell: fn (name string) string {
		return 'Bye, ${name}'
	}
	ping:     CommandText{
		description: 'Checks the bot'
	}
}

const spanish = Texts{
	hello:    'Hola'
	farewell: fn (name string) string {
		return 'Adiós, ${name}'
	}
	ping:     CommandText{
		name:        'latencia'
		description: 'Comprueba el bot'
		options:     {
			'mode': CommandText{
				name:        'modo'
				description: 'Cómo medir'
				choices:     {
					'fast': 'rápido'
				}
			}
		}
	}
}

fn languages() Langs[Texts] {
	mut l := Langs[Texts]{}
	l.add('en-US', english)
	l.add('es-ES', spanish)
	l.alias('es-419', 'es-ES')
	return l
}

fn test_langs_pick_the_closest_language() {
	l := languages()
	assert l.get('es-ES').hello == 'Hola'
	assert l.get('es-419').farewell('Ana') == 'Adiós, Ana'
	assert l.get('fr').hello == 'Hello' // the fallback
	mut by_language := Langs[Texts]{}
	by_language.add('es', spanish)
	by_language.add('en-US', english)
	assert by_language.get('es-MX').hello == 'Hola'
}

fn test_of_reads_the_users_or_the_guilds_locale() {
	mut l := languages()
	i := discord.Interaction{
		locale:       'es-ES'
		guild_locale: 'en-US'
	}
	assert l.of(i).hello == 'Hola'
	l.prefer_guild_locale = true
	assert l.of(i).hello == 'Hello'
}

enum Mode {
	fast
	exact
}

@[Declare(name: 'ping', description: 'Checks the bot')]
@[Locale('ping')]
struct LocalPing {
mut:
	mode ?Mode @[Desc: 'How to measure']
}

fn (p LocalPing) run(mut ctx CommandContext) ! {}

fn test_commands_take_their_translations_from_langs() {
	mut c := new_client(token: 'test')
	c.commands.add(LocalPing{})
	c.commands.localize(languages())
	text := json2.encode(c.commands.entries[0].json)
	assert text.contains('"name":"ping","name_localizations":{"es-ES":"latencia"},"description":"Checks the bot","description_localizations":{"en-US":"Checks the bot","es-ES":"Comprueba el bot"}')
	assert text.contains('"name":"mode","name_localizations":{"es-ES":"modo"},"description":"How to measure","description_localizations":{"es-ES":"Cómo medir"}')
	assert text.contains('{"name":"fast","value":"fast","name_localizations":{"es-ES":"rápido"}}')
}
