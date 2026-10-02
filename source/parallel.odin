package fff

/*
    Fan work out over the CPU's cores, and JOIN BEFORE RETURNING.

    That second half is the point. fff is built as a hot-reloadable library
    (see main_hot_reload), and a thread left running across a reload would be
    executing code from a library that has just been unloaded. So no thread in
    fff outlives the frame that started it: indexing and searching each take a
    slice of the frame's time budget, split it over the cores, and are joined
    before the frame draws. The frame stays responsive, and there is nothing
    in flight to go wrong when the code underneath changes.
*/

import "core:os"
import "core:thread"

MAX_WORKERS :: 16

worker_count :: proc() -> int {
	return clamp(os.get_processor_core_count(), 1, MAX_WORKERS)
}

// Run work(data, i) for i in 0 ..< n - worker 0 on this thread - and wait for
// all of them.
parallel :: proc(workers: int, data: rawptr, work: proc(data: rawptr, worker: int)) {
	n := clamp(workers, 1, MAX_WORKERS)
	if n == 1 {
		work(data, 0)
		return
	}
	threads: [MAX_WORKERS]^thread.Thread
	for i in 1 ..< n do threads[i] = thread.create_and_start_with_poly_data2(data, i, work)
	work(data, 0)
	// A thread that could not be created simply did no work: the others
	// claim what it would have, so nothing is lost but speed.
	for i in 1 ..< n {
		if threads[i] == nil do continue
		thread.join(threads[i])
		thread.destroy(threads[i])
	}
}
