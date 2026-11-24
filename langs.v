module veyfert

import veyfert.discord

// Langs maps locales to a struct of texts T. Make T's fields @[required]: then a language that
// forgets a text does not compile. Fields may be functions, for texts with values in them.
pub struct Langs[T] {
pub mut:
	fallback            string = 'en-US'
	prefer_guild_locale bool // answer in the server's language rather than the user's
mut:
	by_locale map[string]T
	aliases   map[string]string
}

pub fn (mut l Langs[T]) add(locale string, texts T) {
	l.by_locale[locale] = texts
}

// alias makes `locale` use the texts of `target`, such as 'es-419' those of 'es-ES'.
pub fn (mut l Langs[T]) alias(locale string, target string) {
	l.aliases[locale] = target
}

// get returns the texts of `locale`: its own, its alias's, its language's ('es' for 'es-ES'),
// or the fallback's.
pub fn (l &Langs[T]) get(locale string) T {
	for candidate in [locale, l.aliases[locale] or { '' }, locale.all_before('-'), l.fallback] {
		if candidate != '' {
			if texts := l.by_locale[candidate] {
				return texts
			}
		}
	}
	for _, texts in l.by_locale {
		return texts
	}
	panic('veyfert: Langs has no languages')
}

// of returns the texts for whoever triggered an interaction: `langs.of(ctx.interaction)`.
pub fn (l &Langs[T]) of(i discord.Interaction) T {
	locale := if l.prefer_guild_locale {
		i.guild_locale or { i.locale or { '' } }
	} else {
		i.locale or { i.guild_locale or { '' } }
	}
	return l.get(locale)
}

// CommandText localizes a command: its name and description, and its options and subcommands
// by name. `choices` maps enum values to their labels.
pub struct CommandText {
pub:
	name        string
	description string
	options     map[string]CommandText
	choices     map[string]string
}

// Locale names the CommandText field of the Langs struct that localizes a command, for
// `Commands.localize`.
@[attribute]
pub struct Locale {
pub:
	field string
}

// localize adds the translations of `langs` to the commands with @[Locale]. Call it after
// adding the commands and before uploading them; the locales must be Discord's, such as
// 'es-ES', 'en-US' or 'pt-BR'.
pub fn (mut r Commands) localize[T](langs Langs[T]) {
	for mut e in r.entries {
		if e.locale == '' {
			continue
		}
		for locale, texts in langs.by_locale {
			text := command_text(texts, e.locale) or {
				panic('veyfert: the Langs struct has no CommandText field `${e.locale}`')
			}
			if text.name != '' {
				if e.json.kind == 1 {
					check_name('the ${locale} name of `${e.json.name}`', text.name)
				}
				e.json.name_localizations = with_locale(e.json.name_localizations, locale,
					text.name)
			}
			if text.description != '' {
				e.json.description_localizations = with_locale(e.json.description_localizations,
					locale, text.description)
			}
			if mut options := e.json.options {
				localize_options(mut options, text, locale)
				e.json.options = options
			}
		}
	}
}

fn command_text[T](texts T, field string) ?CommandText {
	$for f in T.fields {
		$if f.typ is CommandText {
			if f.name == field {
				return texts.$(f.name)
			}
		}
	}
	return none
}

fn localize_options(mut options []OptionJson, text CommandText, locale string) {
	for mut o in options {
		t := text.options[o.name] or { continue }
		if t.name != '' {
			check_name('the ${locale} name of option `${o.name}`', t.name)
			o.name_localizations = with_locale(o.name_localizations, locale, t.name)
		}
		if t.description != '' {
			o.description_localizations = with_locale(o.description_localizations, locale,
				t.description)
		}
		if mut choices := o.choices {
			for mut ch in choices {
				if label := t.choices[ch.value] {
					ch.name_localizations = with_locale(ch.name_localizations, locale, label)
				}
			}
			o.choices = choices
		}
		if mut sub := o.options {
			localize_options(mut sub, t, locale)
			o.options = sub
		}
	}
}

fn with_locale(m ?map[string]string, locale string, text string) map[string]string {
	mut out := (m or { map[string]string{} }).clone()
	out[locale] = text
	return out
}
