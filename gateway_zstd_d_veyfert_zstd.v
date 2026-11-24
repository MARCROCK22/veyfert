module veyfert

import compress.zstd

// zstd-stream compresses the whole connection as one stream: each binary message continues it,
// so one decompressor lives as long as the connection.

fn (mut s Shard) reset_zstd() ! {
	if !s.client.zstd {
		return
	}
	if s.zctx != unsafe { nil } {
		mut old := unsafe { &zstd.DCtx(s.zctx) }
		old.free_dctx()
	}
	s.zctx = voidptr(zstd.new_dctx()!)
}

fn (mut s Shard) unzstd(data []u8) !string {
	mut d := unsafe { &zstd.DCtx(s.zctx) }
	mut input := zstd.InBuffer{
		src:  data.data
		size: uint(data.len)
	}
	mut buf := []u8{len: 64 * 1024}
	mut out := []u8{}
	for {
		mut output := zstd.OutBuffer{
			dst:  buf.data
			size: uint(buf.len)
		}
		d.decompress_stream(&output, &input)!
		out << buf[..int(output.pos)]
		if input.pos >= input.size && output.pos < output.size {
			break
		}
	}
	return out.bytestr()
}
