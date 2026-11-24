module veyfert

import json2
import time
import veyfert.discord

@[discord.Event('TEST_EVENT')]
struct TestEvent {
	n int
}

fn pool_client() &Client {
	mut c := new_client(token: 'test', workers: 2)
	c.logger.set_level(.fatal)
	c.start_workers()
	return c
}

fn test_emit_reaches_typed_listeners() {
	mut c := pool_client()
	got := chan int{cap: 4}
	c.on[TestEvent](fn [got] (e TestEvent, mut _ Client) ! {
		got <- e.n
	})
	c.emit(TestEvent{ n: 7 })
	select {
		n := <-got {
			assert n == 7
		}
		1000 * time.millisecond {
			assert false, 'the listener did not run'
		}
	}
}

fn test_once_runs_a_single_time() {
	mut c := pool_client()
	got := chan int{cap: 4}
	c.once[TestEvent](fn [got] (e TestEvent, mut _ Client) ! {
		got <- e.n
	})
	c.emit(TestEvent{ n: 1 })
	c.emit(TestEvent{ n: 2 })
	time.sleep(200 * time.millisecond)
	assert got.len == 1
	assert <-got == 1
}

fn test_wait_for_returns_the_first_match() {
	mut c := pool_client()
	spawn fn [mut c] () {
		time.sleep(50 * time.millisecond)
		c.emit(TestEvent{ n: 1 })
		c.emit(TestEvent{ n: 2 })
	}()
	e := c.wait_for[TestEvent](fn (e TestEvent) bool {
		return e.n == 2
	}, time.second) or {
		assert false, 'wait_for timed out'
		return
	}
	assert e.n == 2
}

fn test_wait_for_times_out() {
	mut c := pool_client()
	started := time.now()
	if _ := c.wait_for[TestEvent](fn (_ TestEvent) bool {
		return true
	}, 100 * time.millisecond)
	{
		assert false, 'nothing was emitted'
	}
	assert time.now() - started >= 90 * time.millisecond
}

fn test_identify_queue_spaces_shards_of_a_bucket() {
	mut q := &IdentifyQueue{
		interval:        100 * time.millisecond
		max_concurrency: 2
	}
	start := time.now()
	q.wait(0) // bucket 0
	q.wait(1) // bucket 1
	assert time.now() - start < 50 * time.millisecond, 'different buckets wait for each other'
	q.wait(2) // bucket 0 again
	assert time.now() - start >= 90 * time.millisecond, 'one bucket identified twice within the interval'
}

fn test_presence_payload_matches_the_gateway_shape() {
	p := discord.Presence{
		activities: [discord.Activity{
			name: 'V'
			kind: .listening
		}]
	}
	assert json2.encode(Payload[PresencePayload]{ op: 3, d: gateway_presence(p) }) == '{"op":3,"d":{"since":null,"activities":[{"name":"V","type":2}],"status":"online","afk":false}}'
}
