package fff

/*
    Noticing when fff is slow, and writing down why.

    fff.log sits next to settings.txt (Esc menu: Settings shows the folder).
    It is started afresh each run and only ever has lines worth reading:

        slow frame      a frame that took over SLOW_FRAME, and where it went
        slow read       a file that took a reader over a second
        stuck           the watchdog's reports, below

    THE WATCHDOG is a thread of its own that looks in ten times a second.

      - The main thread ticks `heartbeat` every frame and says which part of
        the frame it is in (`phase`). If the heartbeat has not moved for
        STUCK_AFTER, the main thread is stuck - the window is not being drawn
        and input is not being read - and the watchdog writes down the phase
        it is stuck in, and again when it recovers.
      - Each reader says which file it is on and since when. A reader on one
        file for STUCK_AFTER * 5 is written down with the file's path: that
        is how a cloud placeholder, a network share or a virus scanner shows
        itself.

    The watchdog cannot DRAW anything: only the main thread can draw to the
    window or read its input. It can only notice and write down. Since all
    the heavy work moved to background threads the main thread should never
    be stuck; the watchdog is how we find out if it ever is.
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

SLOW_FRAME :: 150 * time.Millisecond
STUCK_AFTER :: time.Second

Main_Phase :: enum i32 {
	Input,
	Work,
	Draw,
	Present,
	Idle, // asleep until there is input: not stuck, just nothing to do
}

MAIN_PHASE_NAME := [Main_Phase]string {
	.Input   = "reading input",
	.Work    = "updating",
	.Draw    = "drawing",
	.Present = "presenting the frame",
	.Idle    = "idle",
}

Watch :: struct {
	heartbeat: int, // atomic
	phase:     Main_Phase, // atomic
	quit:      bool, // atomic
	thread:    ^thread.Thread,
	// The index the watchdog may look into, guarded by idx_mu: the main
	// thread holds idx_mu while it frees an old index.
	idx_mu:    sync.Mutex,
	idx:       ^Index,
}

// ---------------------------------------------------------------------------
// The log
// ---------------------------------------------------------------------------

@(private = "file")
Log :: struct {
	mu:    sync.Mutex,
	file:  ^os.File,
	start: time.Tick,
}

// The one piece of package-level state: the log is written from every
// thread, and is set up before anything else and closed after.
@(private = "file")
the_log: Log

log_open :: proc(settings_path: string) {
	dir, _ := os.split_path(settings_path)
	path := dir != "" ? strings.concatenate({dir, ODIN_OS == .Windows ? "\\" : "/", "fff.log"}, context.temp_allocator) : "fff.log"
	if dir != "" do os.make_directory_all(dir)
	f, err := os.open(path, {.Write, .Create, .Trunc})
	if err != nil do return
	the_log.file = f
	the_log.start = time.tick_now()
	log_line("fff started")
}

log_close :: proc() {
	sync.lock(&the_log.mu)
	defer sync.unlock(&the_log.mu)
	if the_log.file != nil do os.close(the_log.file)
	the_log.file = nil
}

// One line, with the time since start. Safe from any thread.
log_line :: proc(format: string, args: ..any) {
	if the_log.file == nil do return
	// Stack buffers only: this runs on threads whose temp allocator nobody
	// ever frees.
	buf: [1024]u8
	msg := fmt.bprintf(buf[:], format, ..args)
	t := time.duration_seconds(time.tick_since(the_log.start))
	out: [1100]u8
	line := fmt.bprintf(out[:], "[%9.3f] %s\n", t, msg)
	sync.lock(&the_log.mu)
	defer sync.unlock(&the_log.mu)
	if the_log.file != nil do os.write_string(the_log.file, line)
}

// ---------------------------------------------------------------------------
// The watchdog
// ---------------------------------------------------------------------------

watch_start :: proc(w: ^Watch) {
	w.thread = thread.create_and_start_with_poly_data(w, watch_thread)
}

watch_stop :: proc(w: ^Watch) {
	sync.atomic_store(&w.quit, true)
	thread.join(w.thread)
	thread.destroy(w.thread)
}

// The main thread, at the start of each part of its frame.
watch_phase :: proc(w: ^Watch, p: Main_Phase) {
	sync.atomic_store(&w.phase, p)
	if p == .Input do sync.atomic_add(&w.heartbeat, 1)
}

// Which index the watchdog looks at. Main thread only.
watch_set_index :: proc(w: ^Watch, idx: ^Index) {
	sync.lock(&w.idx_mu)
	w.idx = idx
	sync.unlock(&w.idx_mu)
}

@(private = "file")
watch_thread :: proc(w: ^Watch) {
	last := sync.atomic_load(&w.heartbeat)
	still := time.tick_now() // when the heartbeat last moved
	reported := false
	reported_on: [MAX_INDEX_THREADS]i64 // the `since` of the job last reported, per slot

	for !sync.atomic_load(&w.quit) {
		time.sleep(100 * time.Millisecond)

		hb := sync.atomic_load(&w.heartbeat)
		if hb != last {
			if reported {
				log_line("main thread recovered after %v", time.tick_since(still))
				reported = false
			}
			last = hb
			still = time.tick_now()
		} else if sync.atomic_load(&w.phase) == .Idle {
			still = time.tick_now() // waiting for input is not being stuck
		} else if !reported && time.tick_since(still) > STUCK_AFTER {
			log_line("main thread stuck %s for %v", MAIN_PHASE_NAME[sync.atomic_load(&w.phase)], time.tick_since(still))
			reported = true
		}

		// The readers: anyone on one file for a long time? The walkers: on one
		// folder?
		sync.lock(&w.idx_mu)
		if idx := w.idx; idx != nil {
			now := time.tick_now()._nsec
			for slot in 0 ..< idx.walkers + idx.readers {
				cur := sync.atomic_load(&idx.current[slot])
				since := sync.atomic_load(&idx.since[slot])
				if cur < 0 || since == 0 do continue
				if reported_on[slot] == since do continue
				if time.Duration(now - since) <= STUCK_AFTER * 5 do continue
				if slot < idx.walkers {
					log_line("walker %v stuck: %v listing %s", slot, time.Duration(now - since), index_walker_dir(idx, cur))
				} else {
					f := index_file(idx, cur)
					log_line("reader %v stuck: %v on %s (%v KB)", slot - idx.walkers, time.Duration(now - since), f.rel, max(f.size, 0) / 1024)
				}
				reported_on[slot] = since
			}
		}
		sync.unlock(&w.idx_mu)
		free_all(context.temp_allocator)
	}
}
