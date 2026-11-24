#!/usr/bin/env -S v

// Generates models_gen.v and rest_gen.v from Discord's OpenAPI spec, pinned to one commit.
// Usage, from the repo root: v run tools/gen_api.vsh [path to openapi.json]
// Without a path, it downloads the pinned spec.

import json2
import net.http
import strings
import os

const spec_commit = '3a21a01249a763cd47f1dfec3da91c5ba71bb974'
const keywords = ['type', 'default', 'fn', 'module', 'match', 'none', 'return', 'struct', 'interface',
	'enum', 'const', 'import', 'in', 'is', 'or', 'go', 'spawn', 'select', 'lock', 'rlock', 'shared',
	'atomic', 'asm', 'assert', 'break', 'continue', 'defer', 'else', 'false', 'true', 'for', 'if',
	'mut', 'pub', 'unsafe', 'sizeof', 'typeof', 'nil', 'static', 'volatile', 'union', 'isreftype',
	'implements']
// Names that already mean something in V or in the hand-written code of the module.
const builtin_types = ['Error', 'IError', 'MessageError', 'Option', 'Result', 'Map', 'Array', 'String',
	'Any']
// Methods of the hand-written Api type, which generated names must not take.
const api_methods = ['http', 'new']

struct TypeRef {
	typ      string
	nullable bool
	raw      bool
}

struct Field {
	json string
mut:
	name string
	t    TypeRef
}

struct Gen {
mut:
	all     map[string]json2.Any // every schema, by spec name
	names   map[string]string    // object schema -> V struct name
	fields  map[string][]Field   // V struct name -> fields
	reqd    map[string]map[string]bool
	taken   map[string]bool
	renamed []string
	raw     int
	skipped []string
}

fn obj(a json2.Any) map[string]json2.Any {
	return if a is map[string]json2.Any { a } else { map[string]json2.Any{} }
}

fn list(a json2.Any) []json2.Any {
	return if a is []json2.Any { a } else { []json2.Any{} }
}

fn text(a json2.Any) string {
	return if a is string { a } else { '' }
}

fn key(o map[string]json2.Any, k string) json2.Any {
	return o[k] or { json2.Any(json2.null) }
}

fn types_of(o map[string]json2.Any) []string {
	t := key(o, 'type')
	return if t is string { [t] } else { list(t).map(text(it)) }
}

fn is_enum(o map[string]json2.Any) bool {
	alts := list(key(o, 'oneOf'))
	return alts.len > 0 && 'const' in obj(alts[0])
}

fn ref_name(o map[string]json2.Any) string {
	return text(key(o, '\$ref')).all_after_last('/')
}

fn ident(name string) string {
	if name.starts_with('_') {
		inner := ident(name.trim_left('_'))
		return if inner == '' { '' } else { '${inner}_' }
	}
	if name.len == 0 || !(name[0].is_letter() || name[0] == `_`) {
		return ''
	}
	for c in name {
		if !(c.is_letter() || c.is_digit() || c == `_`) || (c >= `A` && c <= `Z`) {
			return ''
		}
	}
	return if name in keywords { '${name}_' } else { name }
}

fn pascal(snake string) string {
	return snake.split('_').map(it.capitalize()).join('')
}

// declared_types lists the types the hand-written files of the module declare.
fn declared_types(dir string) map[string]bool {
	mut out := map[string]bool{}
	for t in builtin_types {
		out[t] = true
	}
	for f in os.ls(dir) or { [] } {
		if !f.ends_with('.v') || f.ends_with('_gen.v') || f.ends_with('_test.v') {
			continue
		}
		for line in os.read_lines(os.join_path(dir, f)) or { [] } {
			for kw in ['struct ', 'enum ', 'interface ', 'type '] {
				for prefix in ['pub ', ''] {
					if line.starts_with(prefix + kw) {
						out[line.all_after(prefix + kw).split_any(' {[=')[0]] = true
					}
				}
			}
		}
	}
	return out
}

fn raw_ref(nullable bool) TypeRef {
	return TypeRef{
		typ:      'discord.RawJson'
		raw:      true
		nullable: nullable
	}
}

fn (g &Gen) ref_type(name string) TypeRef {
	match name {
		'SnowflakeType' {
			return TypeRef{
				typ: 'discord.Snowflake'
			}
		}
		'Int53Type' {
			return TypeRef{
				typ: 'i64'
			}
		}
		'UInt32Type' {
			return TypeRef{
				typ: 'u32'
			}
		}
		else {}
	}
	sch := obj(g.all[name] or { return raw_ref(false) })
	if is_enum(sch) {
		// Fields keep the wire type: Discord adds enum values, and json2 rejects unknown ones.
		if 'integer' in types_of(sch) {
			return TypeRef{
				typ: if text(key(sch, 'format')) == 'int64' { 'i64' } else { 'int' }
			}
		}
		return TypeRef{
			typ: 'string'
		}
	}
	if vname := g.names[name] {
		return TypeRef{
			typ: vname
		}
	}
	return raw_ref(false)
}

fn (g &Gen) type_of(o map[string]json2.Any) TypeRef {
	if '\$ref' in o {
		return g.ref_type(ref_name(o))
	}
	types := types_of(o)
	nullable := 'null' in types
	if !is_enum(o) {
		for k in ['oneOf', 'anyOf'] {
			if k in o {
				alts := list(key(o, k))
				rest := alts.filter(types_of(obj(it)) != ['null'])
				if rest.len == 1 {
					t := g.type_of(obj(rest[0]))
					return TypeRef{
						...t
						nullable: nullable || t.nullable || rest.len < alts.len
					}
				}
				return raw_ref(nullable)
			}
		}
	}
	if 'allOf' in o {
		parts := list(key(o, 'allOf'))
		if parts.len == 1 {
			t := g.type_of(obj(parts[0]))
			return TypeRef{
				...t
				nullable: nullable || t.nullable
			}
		}
		return raw_ref(nullable)
	}
	kinds := types.filter(it != 'null')
	if kinds.len != 1 {
		return raw_ref(nullable)
	}
	format := text(key(o, 'format'))
	typ := match kinds[0] {
		'string' {
			if format == 'snowflake' { 'discord.Snowflake' } else { 'string' }
		}
		'integer' {
			if format == 'int64' { 'i64' } else { 'int' }
		}
		'number' {
			'f64'
		}
		'boolean' {
			'bool'
		}
		'array' {
			item := g.type_of(obj(key(o, 'items')))
			if item.raw {
				return raw_ref(nullable)
			}
			'[]${item.typ}'
		}
		'object' {
			if 'additionalProperties' in o {
				val := g.type_of(obj(key(o, 'additionalProperties')))
				if !val.raw {
					return TypeRef{
						typ:      'map[string]${val.typ}'
						nullable: nullable
					}
				}
			}
			return raw_ref(nullable)
		}
		else {
			return raw_ref(nullable)
		}
	}
	return TypeRef{
		typ:      typ
		nullable: nullable
	}
}

// collect gathers the properties of an object schema, through allOf compositions.
fn (g &Gen) collect(o map[string]json2.Any, mut fields []Field, mut required map[string]bool) {
	for part in list(key(o, 'allOf')) {
		pm := obj(part)
		if '\$ref' in pm {
			g.collect(obj(g.all[ref_name(pm)] or { json2.Any(json2.null) }), mut fields, mut
				required)
		} else {
			g.collect(pm, mut fields, mut required)
		}
	}
	for r in list(key(o, 'required')) {
		required[text(r)] = true
	}
	for name, p in obj(key(o, 'properties')) {
		if !fields.any(it.json == name) {
			fields << Field{
				json: name
				t:    g.type_of(obj(p))
			}
		}
	}
}

// reaches tells whether struct `from` holds `target` by value, directly or through others.
fn (g &Gen) reaches(from string, target string, mut seen map[string]bool) bool {
	if from == target {
		return true
	}
	if seen[from] {
		return false
	}
	seen[from] = true
	for f in g.fields[from] or { []Field{} } {
		if !f.t.raw && f.t.typ in g.fields && g.reaches(f.t.typ, target, mut seen) {
			return true
		}
	}
	return false
}

// field_line writes a field. In a PATCH body a nullable field is `?Nullable[T]`: none leaves
// the value as it is, and `{is_null: true}` clears it.
fn field_line(f Field, required bool, patch bool) string {
	typ := if patch && f.t.nullable {
		'?discord.Nullable[${f.t.typ}]'
	} else if !required || f.t.nullable {
		'?${f.t.typ}'
	} else {
		f.t.typ
	}
	attr := if f.name != f.json { " @[json: '${f.json}']" } else { '' }
	return '\t${f.name} ${typ}${attr}'
}

spec_text := if os.args.len > 1 {
	os.read_file(os.args[1])!
} else {
	http.get('https://raw.githubusercontent.com/discord/discord-api-spec/${spec_commit}/specs/openapi.json')!.body
}
spec := obj(json2.decode[json2.Any](spec_text)!)
root := @VMODROOT
header := '// Code generated by tools/gen_api.vsh from discord/discord-api-spec@${spec_commit[..7]}. DO NOT EDIT.\n\nmodule api\n'
api_dir := os.join_path(root, 'rest', 'api')
mut g := Gen{
	taken: declared_types(api_dir)
}
g.all = obj(key(obj(key(spec, 'components')), 'schemas'))

// Name the object schemas, renaming those that clash with V or with hand-written types.
for name, sch in g.all {
	o := obj(sch)
	if is_enum(o) || ('properties' !in o && 'allOf' !in o) {
		continue
	}
	mut vname := name
	if !name[0].is_capital() || vname in g.taken {
		vname = '${name}Model'
		g.renamed << '${name} -> ${vname}'
	}
	g.names[name] = vname
}
for name, vname in g.names {
	mut fields := []Field{}
	mut required := map[string]bool{}
	g.collect(obj(g.all[name] or { json2.Any(json2.null) }), mut fields, mut required)
	mut used := map[string]bool{}
	mut kept := []Field{}
	for mut f in fields {
		mut n := if f.json == 'type' { 'kind' } else { ident(f.json) }
		if n == '' {
			g.skipped << 'field ${name}.${f.json}'
			continue
		}
		for (n in used) {
			n += '_'
		}
		used[n] = true
		f.name = n
		kept << f
	}
	g.fields[vname] = kept
	g.reqd[vname] = required.clone()
}
// A struct cannot hold itself by value: such fields become RawJson.
for sname in g.fields.keys() {
	mut fs := g.fields[sname] or { []Field{} }
	for i, f in fs {
		if !f.t.raw && f.t.typ in g.fields {
			mut seen := map[string]bool{}
			if g.reaches(f.t.typ, sname, mut seen) {
				fs[i] = Field{
					...f
					t: raw_ref(f.t.nullable)
				}
			}
		}
	}
	g.fields[sname] = fs
}

// The bodies of PATCH operations, which need explicit nulls.
mut patch_bodies := map[string]bool{}
for _, item in obj(key(spec, 'paths')) {
	content := obj(key(obj(key(obj(key(obj(item), 'patch')), 'requestBody')), 'content'))
	schema := obj(key(obj(key(content, 'application/json')), 'schema'))
	if vname := g.names[ref_name(schema)] {
		patch_bodies[vname] = true
	}
}

mut models := strings.new_builder(1 << 20)
models.writeln('${header}\nimport veyfert.discord\n')
for _, vname in g.names {
	models.writeln('pub struct ${vname} {')
	fs := g.fields[vname] or { []Field{} }
	if fs.len > 0 {
		models.writeln('pub:')
	}
	req := (g.reqd[vname] or { map[string]bool{} }).clone()
	for f in fs {
		models.writeln(field_line(f, f.json in req, vname in patch_bodies))
		if f.t.raw {
			g.raw++
		}
	}
	models.writeln('}\n')
}
mut enums := 0
for name, sch in g.all {
	o := obj(sch)
	if !is_enum(o) || 'integer' !in types_of(o) {
		continue
	}
	vname := if name in g.taken { '${name}Enum' } else { name }
	mut members := []string{}
	mut seen := map[string]bool{}
	mut values := map[i64]bool{}
	mut duplicate := false
	mut wide := false
	for alt in list(key(o, 'oneOf')) {
		am := obj(alt)
		value := key(am, 'const').i64()
		mut member := text(key(am, 'title')).to_lower().bytes().map(if it.is_letter() || it.is_digit() {
			it
		} else {
			`_`
		}).bytestr()
		if member == '' || !member[0].is_letter() {
			member = 'v_${member}'
		}
		if member in keywords {
			member += '_'
		}
		for (member in seen) {
			member += '_'
		}
		seen[member] = true
		duplicate = duplicate || value in values
		values[value] = true
		wide = wide || value > 2147483647 || value < -2147483648
		members << '\t${member} = ${value}'
	}
	if duplicate {
		models.writeln('@[_allow_multiple_values]')
	}
	models.writeln('pub enum ${vname}${if wide { ' as i64' } else { '' }} {\n${members.join('\n')}\n}\n')
	enums++
}

mut rest := strings.new_builder(1 << 20)
rest.writeln('${header}\nimport json2\nimport net.urllib\nimport veyfert.discord\nimport veyfert.rest\n')
mut ops := 0
for path, item in obj(key(spec, 'paths')) {
	im := obj(item)
	for method in ['get', 'post', 'put', 'patch', 'delete'] {
		if method !in im {
			continue
		}
		op := obj(key(im, method))
		op_id := text(key(op, 'operationId'))
		mut fname := ident(op_id)
		if fname == '' {
			g.skipped << 'operation ${method} ${path}'
			continue
		}
		if fname in api_methods {
			fname += '_'
		}
		mut params := list(key(im, 'parameters'))
		params << list(key(op, 'parameters'))
		mut path_types := map[string]string{}
		mut query := []Field{}
		mut query_required := map[string]bool{}
		for p in params {
			pm := obj(p)
			pname := text(key(pm, 'name'))
			t := g.type_of(obj(key(pm, 'schema')))
			match text(key(pm, 'in')) {
				'path' {
					path_types[pname] = if t.raw { 'string' } else { t.typ }
				}
				'query' {
					n := if pname == 'type' { 'kind' } else { ident(pname) }
					if n == '' || t.raw || t.typ.starts_with('[]') || t.typ.starts_with('map[') {
						g.skipped << 'query ${op_id}.${pname}'
						continue
					}
					query << Field{
						json: pname
						name: n
						t:    t
					}
					if key(pm, 'required') is bool && key(pm, 'required') as bool {
						query_required[pname] = true
					}
				}
				else {}
			}
		}
		mut args := []string{}
		mut vpath := path
		for seg in path.split('/') {
			if seg.starts_with('{') && seg.ends_with('}') {
				pname := seg[1..seg.len - 1]
				vn := ident(pname)
				pt := path_types[pname] or { 'string' }
				args << '${vn} ${pt}'
				expr := if pt == 'string' { '\${urllib.path_escape(${vn})}' } else { '\${${vn}}' }
				vpath = vpath.replace(seg, expr)
			}
		}
		mut body_expr := "''"
		content := obj(key(obj(key(op, 'requestBody')), 'content'))
		if 'application/json' in content {
			bt := g.type_of(obj(key(obj(key(content, 'application/json')), 'schema')))
			args << 'body ${bt.typ}'
			body_expr = 'json2.encode(body)'
		} else if content.len > 0 {
			g.skipped << 'operation ${op_id} (body ${content.keys()})'
			continue
		}
		mut ret := ''
		responses := obj(key(op, 'responses'))
		for code in ['200', '201', '202'] {
			if code in responses {
				rc := obj(key(obj(key(responses, code)), 'content'))
				if 'application/json' in rc {
					ret = g.type_of(obj(key(obj(key(rc, 'application/json')), 'schema'))).typ
				}
				break
			}
		}
		opts_type := if query.len > 0 { '${pascal(op_id)}Options' } else { 'rest.CallOptions' }
		if query.len > 0 {
			rest.writeln('@[params]\npub struct ${opts_type} {\n\trest.CallOptions\npub:')
			for f in query {
				rest.writeln(field_line(f, f.json in query_required, false))
			}
			rest.writeln('}\n')
		}
		args << 'opts ${opts_type}'
		rest.writeln('// ${fname}: ${method.to_upper()} ${path}')
		rest.writeln('pub fn (mut a Api) ${fname}(${args.join(', ')}) !${ret} {')
		mut query_expr := "''"
		if query.len > 0 {
			rest.writeln('\tmut q := []string{}')
			for f in query {
				optional := f.json !in query_required || f.t.nullable
				source := if optional { 'v' } else { 'opts.${f.name}' }
				value := if f.t.typ == 'string' {
					'urllib.query_escape(${source})'
				} else {
					'${source}.str()'
				}
				if optional {
					rest.writeln("\tif v := opts.${f.name} {\n\t\tq << '${f.json}=\${${value}}'\n\t}")
				} else {
					rest.writeln("\tq << '${f.json}=\${${value}}'")
				}
			}
			query_expr = "q.join('&')"
		}
		call := "a.http.request(.${method}, '${vpath}', body: ${body_expr}, query: ${query_expr}, reason: opts.reason, files: opts.files)!"
		if ret == '' {
			rest.writeln('\t${call}\n}\n')
		} else {
			rest.writeln('\ttext := ${call}\n\treturn json2.decode[${ret}](text)!\n}\n')
		}
		ops++
	}
}

models_path := os.join_path(api_dir, 'models_gen.v')
rest_path := os.join_path(api_dir, 'rest_gen.v')
os.write_file(models_path, models.str())!
os.write_file(rest_path, rest.str())!
fmt := os.exec([@VEXE, 'fmt', '-w', models_path, rest_path])
if fmt.exit_code != 0 {
	eprintln('v fmt failed:\n${fmt.output}')
}
println('structs: ${g.names.len}, integer enums: ${enums}, RawJson fields: ${g.raw}, endpoints: ${ops}')
println('renamed: ${g.renamed}')
println('skipped (${g.skipped.len}): ${g.skipped}')
