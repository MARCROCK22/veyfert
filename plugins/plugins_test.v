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
	time.sleep(200 * time.millisecond)
	jobs.teardown(mut c)!
	time.sleep(100 * time.millisecond)
	seen := ticks.count()
	assert seen >= 2
	time.sleep(150 * time.millisecond)
	assert ticks.count() == seen
}
