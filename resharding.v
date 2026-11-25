module veyfert

import time

// Resharding moves the bot to the shard count Discord recommends while it runs, as Seyfert
// does. When every shard runs in this process, the client asks Discord every `interval`; once
// the guilds fill `percentage` of what the current shards hold (2500 guilds each), it connects
// the recommended number of shards next to the running ones. Those load their guilds without
// passing on any event, then take over, and the old shards close.
pub struct Resharding {
pub:
	interval   time.Duration = 8 * time.hour // how often to check; 0 turns resharding off
	percentage int           = 80            // how full the shards must be, in percent
}

// reshard_needed tells whether moving from `current` shards to `recommended` is worth it.
// Discord recommends about one shard per 1000 guilds and a shard holds 2500, so `recommended`
// shards mean the current ones are recommended * 1000 / (current * 2500) full.
fn reshard_needed(current int, recommended int, percentage int) bool {
	if current <= 0 || recommended <= current {
		return false
	}
	return f64(recommended) * 1000 * 100 / (f64(current) * 2500) >= f64(percentage)
}

// resharder checks every `interval` whether to reshard, until `run` ends.
fn (mut c Client) resharder() {
	step := if c.resharding.interval < time.second { c.resharding.interval } else { time.second }
	mut last := time.now()
	for !c.is_halting() {
		time.sleep(step)
		if time.since(last) < c.resharding.interval || c.is_halting() {
			continue
		}
		last = time.now()
		c.reshard_if_needed() or { c.logger.warn('resharding: ${err}') }
	}
}

// reshard_if_needed asks Discord how many shards it recommends, and reshards when it is worth it.
fn (mut c Client) reshard_if_needed() ! {
	info := c.rest.get[GatewayBot]('/gateway/bot')!
	c.shards_mu.rlock()
	current := c.total_shards
	c.shards_mu.runlock()
	if !reshard_needed(current, info.shards, c.resharding.percentage) {
		return
	}
	limit := info.session_start_limit
	if limit.remaining < info.shards {
		return error('Discord recommends ${info.shards} shards, but only ${limit.remaining} identifies are left until it resets them in ${limit.reset_after} ms')
	}
	if limit.max_concurrency > 0 {
		c.identify_queue.set_concurrency(limit.max_concurrency)
	}
	c.reshard(info.shards, if c.gateway_url != '' { c.gateway_url } else { info.url })!
}

// reshard connects `total` shards next to the running ones. They identify and load their guilds
// without passing on events; once all have, they take over and the old shards close. When they
// do not get there in time, or the client stops, they close instead.
fn (mut c Client) reshard(total int, url string) ! {
	mut fresh := []&Shard{}
	for id in 0 .. total {
		fresh << &Shard{
			id:          id
			total:       total
			client:      c
			gateway_url: url
			standby:     true
		}
	}
	c.mu.lock()
	if c.halting {
		c.mu.unlock()
		return error('the client is stopping')
	}
	c.standby = fresh
	c.standby_loaded = map[int]bool{}
	c.mu.unlock()
	c.logger.info('resharding: connecting ${total} shards')
	mut threads := []thread !{}
	for mut s in fresh {
		threads << spawn s.run()
	}
	// Each identify waits its turn in the queue; then the guilds take a while to arrive.
	deadline := time.now().add(c.identify_queue.interval * (total + 1) + 5 * time.minute)
	for {
		c.mu.lock()
		if c.halting || time.now() > deadline {
			reason := if c.halting {
				'the client is stopping'
			} else {
				'the new shards did not load their guilds in time'
			}
			c.standby = []&Shard{}
			c.mu.unlock()
			for mut s in fresh {
				s.stop()
			}
			threads.wait() or {}
			return error(reason)
		}
		if c.standby_loaded.len == total {
			// `run` waits for the new shards from now on, before the old ones close.
			c.running << threads
			c.standby = []&Shard{}
			c.ready_shards = map[int]bool{}
			for s in fresh {
				c.ready_shards[s.id] = true
			}
			c.shards_mu.lock()
			mut old := c.shards.clone()
			c.shards = fresh
			c.total_shards = total
			c.shards_mu.unlock()
			c.mu.unlock()
			for mut s in fresh {
				s.take_over()
			}
			for mut s in old {
				s.stop()
			}
			c.logger.info('resharding: ${total} shards took over from ${old.len}')
			return
		}
		c.mu.unlock()
		time.sleep(100 * time.millisecond)
	}
}

// standby_shard_loaded is called when a shard that resharding connected has all its guilds.
fn (mut c Client) standby_shard_loaded(shard int) {
	c.mu.lock()
	c.standby_loaded[shard] = true
	c.mu.unlock()
}

// halt ends resharding: the resharder stops, and shards still loading close.
fn (mut c Client) halt() {
	c.mu.lock()
	c.halting = true
	mut standby := c.standby.clone()
	c.mu.unlock()
	for mut s in standby {
		s.stop()
	}
}

fn (mut c Client) is_halting() bool {
	c.mu.lock()
	defer {
		c.mu.unlock()
	}
	return c.halting
}

// current_shards is a copy of the shard list, which resharding replaces.
fn (c &Client) current_shards() []&Shard {
	c.shards_mu.rlock()
	defer {
		c.shards_mu.runlock()
	}
	return c.shards.clone()
}
