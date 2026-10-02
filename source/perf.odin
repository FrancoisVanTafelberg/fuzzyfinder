package fff

/*
    The metrics panel (F3): where the time goes, measured.

    TWO SOURCES, because they answer different questions:

      fff's own counters    What each thread did and for how long, how many
                            folders were listed and files read. Only fff knows
                            this - the OS sees threads come and go every frame
                            and cannot say which were walking and which were
                            searching.

      the OS                CPU time for the whole process and the machine,
                            resident memory, and bytes read. These include what
                            fff's counters cannot see: raylib, the GPU driver,
                            the allocator. perf_windows.odin / perf_linux.odin.

    Everything is added up over half a second and then shown as rates and
    averages, so the panel holds still enough to read.

    THREAD BUSY %: the share of wall-clock time each slot spent inside its
    work. Slot 0 is the main thread doing its share of a parallel job; slots
    1.. are the workers. Workers only exist inside a frame (parallel.odin), so
    a low number with indexing still running is the frame budget at work: the
    cores are idle while the frame draws and waits for vsync. That gap is the
    first item in .design/performance_improvements.md.
*/

import "core:fmt"
import "core:os"
import "core:time"
import rl "vendor:raylib"

// What the indexer and the search did, added to through a frame.
Work_Stats :: struct {
	busy:   Busy,
	slots:  int, // most parallel slots used at once
	walk:   time.Duration, // main thread, wall clock
	read:   time.Duration,
	lines:  time.Duration,
	search: time.Duration,
	dirs:   i64,
	files:  i64,
	bytes:  i64,
}

Phase :: enum u8 {
	Walk,
	Read,
	Lines,
	Search,
	Draw,
	Wait,
}

PHASE_NAME := [Phase]string {
	.Walk   = "walk",
	.Read   = "read",
	.Lines  = "lines",
	.Search = "search",
	.Draw   = "draw",
	.Wait   = "wait",
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

Perf_Shown :: struct {
	fps:        f32,
	frame_ms:   f32,
	phase_ms:   [Phase]f32, // per frame
	busy_pct:   [MAX_WORKERS]f32,
	slots:      int,
	cpu_proc:   f32, // % of the whole machine
	cpu_sys:    f32,
	mem_proc:   i64,
	mem_index:  i64,
	io_rate:    f64, // bytes/s, from the OS
	read_rate:  f64, // bytes/s, fff's own
	files_rate: f64,
	dirs_rate:  f64,
	os:         Os_Sample, // for the ok flags
	valid:      bool,
}

Perf :: struct {
	acc:          Work_Stats,
	draw:         time.Duration,
	wait:         time.Duration,
	frames:       int,
	window_start: time.Tick,
	frame_start:  time.Tick,
	os_prev:      Os_Sample,
	shown:        Perf_Shown,
	cpu_hist:     [PERF_HISTORY]f32,
	hist_at:      int,
	hist_n:       int,
}

perf_init :: proc(p: ^Perf) {
	p^ = {}
	p.window_start = time.tick_now()
	p.frame_start = p.window_start
	p.os_prev = os_sample()
}

// End of a frame: if half a second has gone by, turn the totals into rates.
perf_frame_end :: proc(p: ^Perf, idx: ^Index) {
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
	s.phase_ms[.Walk] = per_frame(p.acc.walk, frames)
	s.phase_ms[.Read] = per_frame(p.acc.read, frames)
	s.phase_ms[.Lines] = per_frame(p.acc.lines, frames)
	s.phase_ms[.Search] = per_frame(p.acc.search, frames)
	s.phase_ms[.Draw] = per_frame(p.draw, frames)
	s.phase_ms[.Wait] = per_frame(p.wait, frames)
	// Every core fff would use, busy or not: an idle column is the point.
	s.slots = max(p.acc.slots, worker_count())
	for i in 0 ..< MAX_WORKERS do s.busy_pct[i] = clamp(f32(f64(p.acc.busy[i]) / ns * 100), 0, 100)
	s.read_rate = f64(p.acc.bytes) / secs
	s.files_rate = f64(p.acc.files) / secs
	s.dirs_rate = f64(p.acc.dirs) / secs

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
	p.acc = {}
	p.draw = 0
	p.wait = 0
	p.frames = 0
	p.window_start = time.tick_now()
}

// What the index holds, counted rather than asked for: the text of every
// file, each file's line starts, the searchable line list, the file table.
index_memory :: proc(idx: ^Index) -> i64 {
	total := idx.text_bytes
	total += i64(len(idx.lines)) * size_of(Line_Ref)
	total += i64(cap(idx.files)) * size_of(File)
	for &f in idx.files do total += i64(len(f.lines)) * size_of(u32) + i64(len(f.rel))
	return total
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
	.Walk   = {96, 128, 80, 255},
	.Read   = {168, 196, 128, 255},
	.Lines  = {214, 230, 170, 255},
	.Search = {112, 176, 150, 255},
	.Draw   = {150, 160, 145, 255},
	.Wait   = {44, 52, 40, 255},
}

// Lines of text the panel needs at a given width; the charts count as lines.
perf_panel_lines :: proc() -> int {
	return 15 // title, 6 rows, cpu history, 2 + legend (up to 2) for the main thread, 3 for threads
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

	line :: proc(label, value: string, x, y: f32, cols: int) {
		draw_text(label, x, y, COL_DIM)
		draw_text(fit(value, cols - 6), x + 6 * g.font.cw, y, COL_TEXT)
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
			fill({x + w - f32(bars - i) * bw, y + 2 + hh - bh, max(1, bw - 1), bh}, PHASE_COL[.Read])
		}
	}
	y += lh
	mem := s.os.ok_mem ? bytes_text(f64(s.mem_proc)) : "-"
	line("mem", fmt.tprintf("fff %s   index %s", mem, bytes_text(f64(s.mem_index))), x, y, cols)
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
	// ...and the legend for it, wrapped to the panel.
	{
		cx := x
		for ph in Phase {
			label := fmt.tprintf("%s %.1f", PHASE_NAME[ph], s.phase_ms[ph])
			need := f32(text_cols(label) + 3) * f.cw
			if cx + need > x + w && cx > x {
				cx = x
				y += lh
			}
			fill({cx, y + lh / 2 - f.cw / 2, f.cw, f.cw}, PHASE_COL[ph])
			draw_text(label, cx + 1.5 * f.cw, y, COL_DIM)
			cx += need
		}
	}
	y += lh

	// Threads: one column per slot, its busy share of the last half second.
	avg := f32(0)
	for i in 0 ..< s.slots do avg += s.busy_pct[i]
	avg /= f32(s.slots)
	draw_text(fit(fmt.tprintf("threads %v (main + %v)   busy %.0f%%", s.slots, s.slots - 1, avg), cols), x, y, COL_DIM)
	y += lh
	{
		ch := lh * 2 - 4
		area := rl.Rectangle{x, y + 2, w, ch}
		fill(area, COL_GUTTER)
		n := s.slots
		gap := f32(2)
		cw := (w - gap * f32(n - 1)) / f32(n)
		for i in 0 ..< n {
			v := s.busy_pct[i]
			bh := ch * v / 100
			cx := x + f32(i) * (cw + gap)
			fill({cx, area.y + ch - bh, cw, bh}, i == 0 ? PHASE_COL[.Lines] : PHASE_COL[.Read])
			// Its number, where there is room: "main" for slot 0.
			label := i == 0 ? fmt.tprintf("main %.0f%%", v) : fmt.tprintf("%.0f%%", v)
			if f32(text_cols(label)) * f.cw > cw do label = fmt.tprintf("%.0f", v)
			if f32(text_cols(label)) * f.cw <= cw {
				draw_text(label, cx + (cw - text_width(label)) / 2, area.y, COL_DIM)
			}
		}
		// 50% guide
		fill({x, area.y + ch / 2, w, 1}, with_alpha(COL_EDGE, 90))
	}
}
