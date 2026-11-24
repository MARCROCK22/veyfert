module plugins

import sync
import time
import veyfert

@[heap]
struct Ticks {
mut:
	mu &sync.Mutex = sync.new_mutex()
	n  int
}

fn (mut t Ticks) add() {
	t.mu.lock()
	t.n++
	t.mu.unlock()
}

fn (mut t Ticks) count() int {
	t.mu.lock()
	defer {
		t.mu.unlock()
	}
	return t.n
}

fn test_the_scheduler_repeats_until_teardown() ! {
	mut c := veyfert.new_client(token: 'test')
	mut ticks := &Ticks{}
	mut jobs := &Scheduler{}
	jobs.every(20 * time.millisecond, fn [mut ticks] (mut _ veyfert.Client) ! {
		ticks.add()
	})
	c.install(mut jobs)!
	// Wait for two runs rather than a fixed time: -race slows every thread down.
	deadline := time.now().add(5 * time.second)
	for ticks.count() < 2 && time.now() < deadline {
		time.sleep(10 * time.millisecond)
	}
	assert ticks.count() >= 2
	jobs.teardown(mut c)!
	// A run that had already started may still finish; none may start after it.
	time.sleep(300 * time.millisecond)
	seen := ticks.count()
	time.sleep(300 * time.millisecond)
	assert ticks.count() == seen
}
