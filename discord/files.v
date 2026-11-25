module discord

import encoding.base64
import net.http
import net.http.mime
import os

// File is an attachment sent as multipart/form-data, with the JSON body as `payload_json`.
pub struct File {
pub:
	name         string
	data         []u8
	content_type string = 'application/octet-stream'
}

// file_from_base64 makes a file from base64 data, plain or as a data URI
// (`data:image/png;base64,…`), whose type then wins over `content_type`.
pub fn file_from_base64(name string, data string, content_type string) !File {
	mut kind := content_type
	mut payload := data.trim_space()
	if payload.starts_with('data:') {
		header := payload.all_before(',')
		if !header.ends_with(';base64') {
			return error('veyfert: the data URI is not base64')
		}
		kind = header.all_after('data:').all_before(';')
		payload = payload.all_after(',')
	}
	bytes := base64.decode(payload)
	if bytes.len == 0 && payload != '' {
		return error('veyfert: the data is not base64')
	}
	return File{
		name:         name
		data:         bytes
		content_type: if kind == '' { 'application/octet-stream' } else { kind }
	}
}

// data_uri is the file as Discord takes images and sounds in JSON bodies: `data:<type>;base64,…`.
pub fn (f File) data_uri() string {
	return 'data:${f.content_type};base64,${base64.encode(f.data)}'
}

// file_from_path reads a file to attach, typed by its extension.
pub fn file_from_path(path string) !File {
	ext := os.file_ext(path).trim_left('.').to_lower()
	content_type := mime.get_mime_type(ext)
	return File{
		name:         os.file_name(path)
		data:         os.read_bytes(path)!
		content_type: if content_type != '' { content_type } else { 'application/octet-stream' }
	}
}

// file_from_url downloads a file to attach under `name`.
pub fn file_from_url(url string, name string) !File {
	resp := http.get(url)!
	if resp.status_code >= 300 {
		return error('veyfert: downloading ${url}: HTTP ${resp.status_code}')
	}
	return File{
		name:         name
		data:         resp.body.bytes()
		content_type: resp.header.get(.content_type) or { 'application/octet-stream' }
	}
}
