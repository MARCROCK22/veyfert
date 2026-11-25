# Resharding

A shard holds up to 2500 guilds, and Discord recommends about one shard per 1000. As a bot grows,
the shard count it started with falls short. veyfert follows Discord's recommendation while the
bot runs, as Seyfert does: it connects the new shards next to the old ones, lets them load their
guilds, and only then switches over, so the bot keeps answering throughout.

```v
import os
import time
import veyfert

fn main() {
	mut bot := veyfert.new_client(
		token:      os.getenv('DISCORD_TOKEN')
		// Check every 4 hours, and reshard once the guilds fill 70% of what the shards hold.
		resharding: veyfert.Resharding{
			interval:   4 * time.hour
			percentage: 70
		}
	)
	bot.on[veyfert.BotReady](fn (e veyfert.BotReady, mut c veyfert.Client) ! {
		c.logger.info('ready on ${e.shards} shards')
	})
	bot.run()!
}
```

## Options

`ClientOptions.resharding` is a `veyfert.Resharding`:

| Field | Default | Meaning |
|---|---|---|
| `interval` | 8 hours | How often to ask Discord; `0` turns resharding off |
| `percentage` | 80 | How full the current shards must be, in percent, before resharding |

How full the shards are comes from Discord's recommendation: with `current` shards and
`recommended` from Discord, the bot has about `recommended * 1000` guilds and room for
`current * 2500`. Four shards hold 10 000 guilds; when Discord recommends 8, there are about
8000, which is 80%, so the bot moves to 8 shards.

To turn it off:

```v
mut bot := veyfert.new_client(
	token:      os.getenv('DISCORD_TOKEN')
	resharding: veyfert.Resharding{
		interval: 0
	}
)
```

## When it runs

Only when this process runs every shard: with the default shard count, or with a `ShardRange`
from 0 to `total`. A bot split among processes with ranges cannot reshard one process alone;
restart every process with the new `total` instead.

It also waits when Discord has fewer identifies left today than the new shards need (see
`session_start_limit` in `/gateway/bot`), and logs why.

## What happens

1. Every `interval`, the client asks `/gateway/bot` for the recommended count, and compares it
   with the current one.
2. When it is worth it, it creates the new shards and connects them. They identify through the
   same queue as the running ones, following `max_concurrency`.
3. The new shards receive READY and their guilds, but pass no event on: the old shards keep
   delivering events and answering commands meanwhile.
4. Once every new shard has all its guilds, they take over: the client's shard list and total
   change, `shard_id_for` uses the new total, and the old shards close.
5. `run` goes on with the new shards. `BotReady` is not sent again.

The cache stays as it was: the guilds are the same, so nothing is lost.

## When it does not work out

If the new shards do not load their guilds in time (5 minutes, plus their turn in the identify
queue), or the bot stops meanwhile, they close and the old shards carry on. The next check tries
again. A shard that Discord rejects during the switch, with a fatal close code, never loads, so
the switch is abandoned the same way.

## Logs

```
resharding: connecting 8 shards
resharding: 8 shards took over from 4
```

and `resharding: ...` warnings when a check fails or has to wait.
