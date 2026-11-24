module plugins

import sync
import time
import veyfert

// Scheduler is a plugin that runs functions on an interval while the client runs:
//   mut jobs := &veyfert.Scheduler{}
//   jobs.every(time.hour, fn (mut c veyfert.Client) ! { ... })
//   bot.install(mut jobs)!
@[heap]
pub struct Scheduler {
mut:
	jobs    []ScheduledJob
	mu      &sync.Mutex = sync.new_mutex()
	stopped bool
}

struct ScheduledJob {
	interval time.Duration
	f        fn (mut c veyfert.Client) ! @[required]
}

pub fn (mut s Scheduler) every(interval time.Duration, f fn (mut c veyfert.Client) !) {
	s.jobs << ScheduledJob{interval, f}
}

pub fn (s &Scheduler) name() string {
	return 'scheduler'
}

pub fn (mut s Scheduler) setup(mut c veyfert.Client) ! {
	for job in s.jobs {
		spawn s.repeat(job, mut c)
	}
}

pub fn (mut s Scheduler) teardown(mut _ veyfert.Client) ! {
	s.mu.lock()
	s.stopped = true
	s.mu.unlock()
}

fn (mut s Scheduler) is_stopped() bool {
	s.mu.lock()
	defer {
		s.mu.unlock()
	}
	return s.stopped
}

fn (mut s Scheduler) repeat(job ScheduledJob, mut c veyfert.Client) {
	for {
		// Sleep in steps, so a teardown ends the loop within 50 ms.
		deadline := time.now().add(job.interval)
		for time.now() < deadline {
			if s.is_stopped() {
				return
			}
			time.sleep(50 * time.millisecond)
		}
		if s.is_stopped() {
			return
		}
		job.f(mut c) or { c.logger.error('scheduled job: ${err}') }
	}
}
