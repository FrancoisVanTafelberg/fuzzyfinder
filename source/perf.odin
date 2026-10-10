package fff

/*
    The metrics panel (F3): where the time goes, measured.

    TWO SOURCES, because they answer different questions:

      fff's own counters    What each thread did and for how long, how many
                            folders were listed and files read. Only fff knows
                            which thread was walking, reading or searching.

      the OS                CPU time for the whole process and the machine,
                            resident memory, and bytes read. These include what
                            fff's counters cannot see: raylib, the GPU driver,
                            the allocator. perf_windows.odin / perf_linux.odin.

    Everything is added up over half a second and then shown as rates and
    averages, so the panel holds still enough to read.

    THE THREADS ROW is one column per background thread, its busy share of
    the last half second: the walker (W), the readers, and the search workers.
    The main thread is the stacked bar above it - with the work moved off it,
    nearly all of a frame should be "wait": presenting, and sleeping until
    the next one.
*/

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

// The main thread's frame, in three parts.
Phase :: enum u8 {
	Logic, // input, and taking what the other threads have ready
	Draw,
	Wait, // presenting, and the frame cap / vsync
}

PHASE_NAME := [Phase]string {
	.Logic = "update",
	.Draw  = "draw",
	.Wait  = "wait",
}

// One reading of the OS counters. A field the platform cannot supply has its
// `ok` false and is shown as "-".
Os_Sample :: struct {
	proc_cpu:  time.Duration, // CPU time used by this process, all threads
	sys_busy:  time.Duration, // CPU time used by the whole machine
	sys_total: time.Duration, // ...out of this much
	mem:       i64, // resident / working set, bytes
	io_read:   i64, // bytes read by this process, all files
	ok_cpu:    bool,
	ok_sys:    bool,
	ok_mem:    bool,
	ok_io:     bool,
}

PERF_SAMPLE_SECONDS :: 0.5
PERF_HISTORY :: 64
// How often an idle fff redraws while the panel is showing.
PERF_IDLE_FPS :: 20 // also the worst-case delay before the first keystroke is seen

Thread_Kind :: enum u8 {
	Walker,
	Reader,
	Search,
}

THREAD_COL := [Thread_Kind]rl.Color {
	.Walker = {214, 230, 170, 255},
	.Reader = {168, 196, 128, 255},
	.Search = {112, 176, 150, 255},
}

MAX_COLUMNS :: MAX_INDEX_THREADS + MAX_WORKERS

Perf_Shown :: struct {
	fps:        f32,
	frame_ms:   f32,
	phase_ms:   [Phase]f32, // per frame
	columns:    int,
	kind:       [MAX_COLUMNS]Thread_Kind,
	busy_pct:   [MAX_COLUMNS]f32,
	readers:    int,
	searchers:  int,
	cpu_proc:   f32, // % of the whole machine
	cpu_sys:    f32,
	mem_proc:   i64,
	mem_index:  i64,
	mem_limit:  i64, // the index's text limit, 0 = none
	over_limit: int, // files left unread because of it
	io_rate:    f64, // bytes/s, from the OS
	read_rate:  f64, // bytes/s, fff's own
	files_rate: f64,
	dirs_rate:  f64,
	os:         Os_Sample, // for the ok flags
	valid:      bool,
}

Perf :: struct {
	logic:        time.Duration,
	draw:         time.Duration,
	wait:         time.Duration,
	frames:       int,
	window_start: time.Tick,
	os_prev:      Os_Sample,
	// The counters as they were at the last sample, to take differences.
	prev_idx:     ^Index,
	prev_loaded:  int,
	prev_dirs:    int,
	prev_read:    i64,
	prev_ibusy:   [MAX_INDEX_THREADS]i64,
	prev_sbusy:   [MAX_WORKERS]i64,
	shown:        Perf_Shown,
	cpu_hist:     [PERF_HISTORY]f32,
	hist_at:      int,
	hist_n:       int,
}

perf_init :: proc(p: ^Perf) {
	p^ = {}
	p.window_start = time.tick_now()
	p.os_prev = os_sample()
}

// End of a frame: if half a second has gone by, turn the totals into rates.
perf_frame_end :: proc(p: ^Perf, idx: ^Index, sr: ^Searcher) {
	p.frames += 1
	el := time.tick_since(p.window_start)
	if time.duration_seconds(el) < PERF_SAMPLE_SECONDS do return

	secs := time.duration_seconds(el)
	ns := f64(el)
	s := &p.shown
	frames := f32(max(1, p.frames))
	s.fps = frames / f32(secs)
	s.frame_ms = f32(secs * 1000) / frames
	per_frame :: proc(d: time.Duration, frames: f32) -> f32 {return f32(time.duration_milliseconds(d)) / frames}
	s.phase_ms[.Logic] = per_frame(p.logic, frames)
	s.phase_ms[.Draw] = per_frame(p.draw, frames)
	s.phase_ms[.Wait] = per_frame(p.wait, frames)

	// A new index starts its counters at zero.
	if idx != p.prev_idx {
		p.prev_idx = idx
		p.prev_loaded, p.prev_dirs, p.prev_read = 0, 0, 0
		p.prev_ibusy = {}
	}
	col := 0
	pct :: proc(now, before: i64, ns: f64) -> f32 {return clamp(f32(f64(now - before) / ns * 100), 0, 100)}
	if idx != nil {
		loaded := sync.atomic_load(&idx.loaded)
		dirs := sync.atomic_load(&idx.dirs)
		read := sync.atomic_load(&idx.read_bytes)
		s.files_rate = f64(loaded - p.prev_loaded) / secs
		s.dirs_rate = f64(dirs - p.prev_dirs) / secs
		s.read_rate = f64(read - p.prev_read) / secs
		p.prev_loaded, p.prev_dirs, p.prev_read = loaded, dirs, read
		for t in 0 ..= idx.readers {
			b := sync.atomic_load(&idx.busy_ns[t])
			s.kind[col] = t == 0 ? .Walker : .Reader
			s.busy_pct[col] = pct(b, p.prev_ibusy[t], ns)
			p.prev_ibusy[t] = b
			col += 1
		}
		s.readers = idx.readers
		s.mem_limit = idx.max_text_bytes
		s.over_limit = sync.atomic_load(&idx.over_limit)
	}
	s.searchers = worker_count()
	for w in 0 ..< s.searchers {
		b := sync.atomic_load(&sr.busy_ns[w])
		s.kind[col] = .Search
		s.busy_pct[col] = pct(b, p.prev_sbusy[w], ns)
		p.prev_sbusy[w] = b
		col += 1
	}
	s.columns = col

	now := os_sample()
	prev := p.os_prev
	cores := f64(max(1, os.get_processor_core_count()))
	s.os = now
	if now.ok_cpu && prev.ok_cpu {
		s.cpu_proc = f32(clamp(f64(now.proc_cpu - prev.proc_cpu) / (ns * cores) * 100, 0, 100))
	}
	if now.ok_sys && prev.ok_sys && now.sys_total > prev.sys_total {
		s.cpu_sys = f32(clamp(f64(now.sys_busy - prev.sys_busy) / f64(now.sys_total - prev.sys_total) * 100, 0, 100))
	}
	s.mem_proc = now.mem
	if now.ok_io && prev.ok_io do s.io_rate = f64(max(0, now.io_read - prev.io_read)) / secs
	s.mem_index = index_memory(idx)
	s.valid = true

	p.cpu_hist[p.hist_at] = s.cpu_proc
	p.hist_at = (p.hist_at + 1) % PERF_HISTORY
	p.hist_n = min(p.hist_n + 1, PERF_HISTORY)

	p.os_prev = now
	p.logic, p.draw, p.wait = 0, 0, 0
	p.frames = 0
	p.window_start = time.tick_now()
}

bytes_text :: proc(b: f64) -> string {
	switch {
	case b >= 1 << 30:
		return fmt.tprintf("%.2f GB", b / (1 << 30))
	case b >= 1 << 20:
		return fmt.tprintf("%.1f MB", b / (1 << 20))
	case b >= 1 << 10:
		return fmt.tprintf("%.0f KB", b / (1 << 10))
	}
	return fmt.tprintf("%.0f B", b)
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------

PHASE_COL := [Phase]rl.Color {
	.Logic = {168, 196, 128, 255},
	.Draw  = {150, 160, 145, 255},
	.Wait  = {44, 52, 40, 255},
}

// Lines of text the panel needs; the charts count as lines.
perf_panel_lines :: proc() -> int {
	return 14 // title, 6 rows, cpu history, 3 for the main thread, 3 for threads
}

perf_panel_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	p := &g.perf
	s := &p.shown
	x := r.x + f.pad
	w := r.width - 2 * f.pad
	cols := int(w / f.cw)
	y := r.y + f.pad
	lh := f.lh

	draw_text("Performance", x, y, COL_ACCENT)
	draw_text("F3", x + w - 2 * f.cw, y, COL_FAINT)
	y += lh
	if !s.valid {
		draw_text("measuring...", x, y, COL_FAINT)
		return
	}

	pct :: proc(ok: bool, v: f32) -> string {return ok ? fmt.tprintf("%.0f%%", v) : "-"}

	line :: proc(label, value: string, x, y: f32, cols: int, col := COL_TEXT) {
		draw_text(label, x, y, COL_DIM)
		draw_text(fit(value, cols - 6), x + 6 * g.font.cw, y, col)
	}
	line("fps", fmt.tprintf("%.0f   frame %.1f ms", s.fps, s.frame_ms), x, y, cols)
	y += lh
	line("cpu", fmt.tprintf("fff %s   all %s", pct(s.os.ok_cpu, s.cpu_proc), pct(s.os.ok_sys, s.cpu_sys)), x, y, cols)
	y += lh
	// CPU history: one bar per half second, newest on the right.
	{
		hh := lh - 4
		fill({x, y + 2, w, hh}, COL_GUTTER)
		bw := w / PERF_HISTORY
		bars := min(p.hist_n, PERF_HISTORY)
		for i in 0 ..< bars {
			v := p.cpu_hist[(p.hist_at - bars + i + PERF_HISTORY * 2) % PERF_HISTORY]
			bh := hh * v / 100
			fill({x + w - f32(bars - i) * bw, y + 2 + hh - bh, max(1, bw - 1), bh}, THREAD_COL[.Reader])
		}
	}
	y += lh
	// Memory, and the index's limit when it is close to it or has hit it.
	{
		mem := s.os.ok_mem ? bytes_text(f64(s.mem_proc)) : "-"
		val := fmt.tprintf("fff %s   index %s", mem, bytes_text(f64(s.mem_index)))
		col := COL_TEXT
		if s.mem_limit > 0 && s.mem_index > s.mem_limit * 9 / 10 {
			val = fmt.tprintf("%s of %s", val, bytes_text(f64(s.mem_limit)))
			col = COL_BAD
		}
		line("mem", val, x, y, cols, col)
	}
	y += lh
	io := s.os.ok_io ? fmt.tprintf("%s/s", bytes_text(s.io_rate)) : "-"
	line("disk", fmt.tprintf("os %s   fff %s/s", io, bytes_text(s.read_rate)), x, y, cols)
	y += lh
	line("index", fmt.tprintf("%s files/s   %s dirs/s", thousands(int(s.files_rate)), thousands(int(s.dirs_rate))), x, y, cols)
	y += lh

	// Main thread: where each frame went, as one stacked bar.
	draw_text("main thread, ms / frame", x, y, COL_DIM)
	y += lh
	{
		total := f32(0)
		for v in s.phase_ms do total += v
		bx := x
		bar := rl.Rectangle{x, y + 2, w, lh - 4}
		fill(bar, COL_GUTTER)
		if total > 0 do for ph in Phase {
			bw := w * s.phase_ms[ph] / total
			fill({bx, bar.y, bw, bar.height}, PHASE_COL[ph])
			bx += bw
		}
	}
	y += lh
	{
		cx := x
		for ph in Phase {
			label := fmt.tprintf("%s %.1f", PHASE_NAME[ph], s.phase_ms[ph])
			need := f32(text_cols(label) + 3) * f.cw
			fill({cx, y + lh / 2 - f.cw / 2, f.cw, f.cw}, PHASE_COL[ph])
			draw_text(label, cx + 1.5 * f.cw, y, COL_DIM)
			cx += need
		}
	}
	y += lh

	// Background threads: one column each, busy share of the last half second.
	draw_text(
		fit(fmt.tprintf("threads: walker, %v readers, %v search", s.readers, s.searchers), cols),
		x,
		y,
		COL_DIM,
	)
	y += lh
	{
		ch := lh * 2 - 4
		area := rl.Rectangle{x, y + 2, w, ch}
		fill(area, COL_GUTTER)
		n := max(s.columns, 1)
		gap := f32(2)
		cw := (w - gap * f32(n - 1)) / f32(n)
		for i in 0 ..< s.columns {
			v := s.busy_pct[i]
			bh := ch * v / 100
			cx := x + f32(i) * (cw + gap)
			fill({cx, area.y + ch - bh, cw, bh}, THREAD_COL[s.kind[i]])
			label := fmt.tprintf("%.0f", v)
			if s.kind[i] == .Walker do label = "W"
			if f32(text_cols(label)) * f.cw <= cw {
				draw_text(label, cx + (cw - text_width(label)) / 2, area.y, COL_DIM)
			}
		}
		fill({x, area.y + ch / 2, w, 1}, with_alpha(COL_EDGE, 90)) // 50%
	}
}
