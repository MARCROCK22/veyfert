module discord

import json2
import os

struct WithRaw {
	content    ?string
	components ?RawJson
}

fn test_raw_json_round_trips_any_value() {
	v := json2.decode[WithRaw]('{"content":"x","components":[{"type":1,"components":[]}]}') or {
		panic(err)
	}
	raw := v.components or { panic('components missing') }
	// Decoding goes through json2.Any, which sorts object keys.
	assert raw.text == '[{"components":[],"type":1}]'
	assert json2.encode(v) == '{"content":"x","components":[{"components":[],"type":1}]}'
	assert json2.encode(WithRaw{ content: 'y' }) == '{"content":"y"}'
}

fn test_cdn_urls() {
	animated := User{
		id:     Snowflake{80351110224678912}
		avatar: 'a_1269e74af4df7417b13759eae50c83dc'
	}
	assert animated.avatar_url(size: 256) == 'https://cdn.discordapp.com/avatars/80351110224678912/a_1269e74af4df7417b13759eae50c83dc.gif?size=256'
	plain := User{
		id: Snowflake{80351110224678912}
	}
	assert plain.avatar_url() == 'https://cdn.discordapp.com/embed/avatars/${(u64(80351110224678912) >> 22) % 6}.png'
}

fn test_file_from_path_reads_and_types_the_file() ! {
	path := os.join_path(os.temp_dir(), 'veyfert_test_logo.png')
	os.write_file(path, 'not really a png')!
	defer {
		os.rm(path) or {}
	}
	f := file_from_path(path)!
	assert f.name == 'veyfert_test_logo.png'
	assert f.content_type == 'image/png'
	assert f.data.bytestr() == 'not really a png'
}
