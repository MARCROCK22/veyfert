module veyfert

// Without -d veyfert_zstd, zstd is not compiled in, so bots that do not use it do not pay for it.

fn (mut s Shard) reset_zstd() ! {
	if s.client.zstd {
		return error('veyfert: ClientOptions.zstd needs the zstd decompressor: build with -d veyfert_zstd')
	}
}

fn (mut s Shard) unzstd(_ []u8) !string {
	return error('veyfert: a zstd frame arrived, but zstd is not compiled in (-d veyfert_zstd)')
}
