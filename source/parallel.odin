package fff

/*
    Fan work out over the cores and wait for all of it: the search thread's
    rounds (search.odin) are split this way. Each slot's working time is
    measured for the metrics panel (perf.odin).

    It runs on the SEARCH thread, never on the main thread: waiting here
    is fine because nothing on screen depends on it.
*/

import "core:os"
import "core:thread"
import "core:time"

MAX_WORKERS :: 16

worker_count :: proc() -> int {
	return clamp(os.get_processor_core_count(), 1, MAX_WORKERS)
}

// Time spent working, per slot, added to by every `parallel` call that is
// handed one. Nil to not measure (tools/bench).
Busy :: [MAX_WORKERS]time.Duration

@(private = "file")
Slot :: struct {
	data:   rawptr,
	work:   proc(data: rawptr, worker: int),
	worker: int,
	took:   time.Duration,
}

@(private = "file")
run_slot :: proc(s: ^Slot) {
	// Slot 0 runs on the calling thread, which has its own priority already.
	if s.worker != 0 do thread_lower_priority()
	start := time.tick_now()
	s.work(s.data, s.worker)
	s.took = time.tick_since(start)
}

// Run work(data, i) for i in 0 ..< n - worker 0 on this thread - and wait for
// all of them.
parallel :: proc(workers: int, data: rawptr, work: proc(data: rawptr, worker: int), busy: ^Busy = nil) {
	n := clamp(workers, 1, MAX_WORKERS)
	slots: [MAX_WORKERS]Slot
	for i in 0 ..< n do slots[i] = {data = data, work = work, worker = i}
	threads: [MAX_WORKERS]^thread.Thread
	for i in 1 ..< n do threads[i] = thread.create_and_start_with_poly_data(&slots[i], run_slot)
	run_slot(&slots[0])
	// A thread that could not be created simply did no work: the others
	// claim what it would have, so nothing is lost but speed.
	for i in 1 ..< n {
		if threads[i] == nil do continue
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
	if busy != nil do for i in 0 ..< n do busy[i] += slots[i].took
}
