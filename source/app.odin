package fff

/*
    fff - Fast Fuzzy Finder: the frame.

    THE MAIN THREAD ONLY READS INPUT AND DRAWS. Everything that can take time
    happens on other threads, and the main thread never waits for any of
    them:

        indexing        index.odin: a walker and several readers
        searching       search.odin: the search thread and its workers
        opening files   launch.odin: a short-lived thread per launch
        freeing an old  a short-lived thread, once its builders have finished
        index
        the watchdog    watch.odin

    Each frame it posts what it wants (the query) and takes what is ready (the
    index so far, the latest results). That is what keeps the window
    responsive on any tree, however slow its disk.

    The root of the search is the folder fff was started in, or the folder
    given as its first argument.
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "fuzzy"
import "ignore"
import rl "vendor:raylib"

APP_TITLE :: "fff - Fast Fuzzy Finder"

Focus :: enum u8 {
	Search,
	Viewer,
}

App :: struct {
	settings:      Settings,
	settings_path: string, // owned
	root:          string, // owned; absolute, '/'-separated, no trailing '/'
	font:          Font,

	idx:           ^Index,
	idx_gen:       int,
	retiring:      [dynamic]^Index, // stopped, freed once their threads end
	// Rules added since `idx` started: the walker works from a copy of the
	// rules taken then, so newly found files are checked again here.
	rules_changed: bool,
	hidden_upto:   int,
	session:       ignore.Rules, // "...from this search"
	rules_ver:     int, // bumped whenever either rule list changes

	searcher:      Searcher,
	posted:        Search_Query, // what was last asked for
	posted_id:     int,
	res:           Search_Results, // what came back
	pattern:       fuzzy.Pattern, // the query as typed, for highlighting

	query:         [dynamic]u8,
	cursor:        int, // byte offset into query
	mode:          Mode,
	focus:         Focus,
	sel:           int, // row in the results
	view:          Viewer,
	click_time:    f64, // for double-clicks on a result
	click_row:     int,
	panel_scroll:  f32,

	menu:          Menu_State, // Esc
	ctx:           Context_Menu, // right-click
	prompt:        Prompt, // Open In... on Linux

	status:        [512]u8,
	status_len:    int,
	status_time:   f64,
	status_bad:    bool,
	// Status lines posted by other threads (launches), shown next frame.
	status_mu:     sync.Mutex,
	pending:       [512]u8,
	pending_len:   int,
	pending_bad:   bool,
	launches:      int, // atomic: launches still running

	perf:          Perf, // the metrics panel (perf.odin)
	idle_fps:      bool, // running at the idle rate for the metrics panel
	watch:         Watch,
	busy_time:     time.Duration, // how long the last frame kept the main thread busy
	frame_count:   int, // the first frame uploads the font, so it is not logged as slow
	waiting:       bool, // event waiting is on: EndDrawing sleeps until input

	ui:            Ui_State,
	quit:          bool,
	first_run:     bool,
}

g: ^App

run :: proc() {
	app_init()
	for app_frame() {}
	app_shutdown()
}

app_init :: proc() {
	g = new(App)
	g.settings_path = settings_path()
	log_open(g.settings_path)
	g.first_run = settings_load(&g.settings, g.settings_path)
	g.root = resolve_root()
	log_line("searching %s", g.root)
	title := fmt.ctprintf("fff - %s", g.root)
	window_open(&g.settings, title, g.first_run)
	platform_init()
	rl.SetTargetFPS(g.settings.max_fps)

	font_load(&g.font, g.settings.font_size)
	g.view.file = -1
	g.mode = .Content
	perf_init(&g.perf)
	searcher_start(&g.searcher)
	watch_start(&g.watch)
	reindex()
}

// A frame that kept the main thread busy longer than this was a freeze:
// whatever was clicked or typed during it is dropped rather than applied to
// a screen the user could not see.
INPUT_GUARD :: 250 * time.Millisecond

app_frame :: proc() -> bool {
	frame_start := time.tick_now()
	watch_phase(&g.watch, .Input)
	ui_begin()

	if g.busy_time > INPUT_GUARD {
		// Input that piled up during a freeze: drop it.
		ui_take_all()
		log_line("dropped input queued during a %v freeze", g.busy_time)
	} else {
		app_keys()
	}
	// Characters typed this frame that nobody read must not arrive next frame.
	for rl.GetCharPressed() != 0 {}

	// --- take what the other threads have ready ---------------------------
	watch_phase(&g.watch, .Work)
	take_status()
	index_upkeep()
	search_upkeep()
	results_sync()

	// --- draw -------------------------------------------------------------
	watch_phase(&g.watch, .Draw)
	draw_start := time.tick_now()
	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)
	modal := g.menu.open || g.prompt.open
	held := g.ui
	if modal || g.busy_time > INPUT_GUARD do ui_take_all()
	// The context menu takes its clicks before the page underneath sees them.
	if g.ctx.open && !modal do context_menu_input()
	main_draw()
	if modal do g.ui = held
	if g.ctx.open do context_menu_draw()
	if g.prompt.open do prompt_draw()
	if g.menu.open do menu_draw()
	present_start := time.tick_now()
	g.perf.logic += time.tick_diff(frame_start, draw_start)
	g.perf.draw += time.tick_diff(draw_start, present_start)

	// EndDrawing presents, then waits out the frame - or, with event waiting
	// on, sleeps until there is input. That sleep is not work.
	watch_phase(&g.watch, g.waiting ? .Idle : .Present)
	rl.EndDrawing()
	presented := time.tick_since(present_start)
	g.perf.wait += presented

	busy := time.tick_diff(frame_start, present_start)
	if !g.waiting do busy += presented
	g.busy_time = busy
	g.frame_count += 1
	if busy > SLOW_FRAME && g.frame_count > 1 {
		log_line(
			"slow frame: %v (update %v, draw %v, present %v)",
			busy,
			time.tick_diff(frame_start, draw_start),
			time.tick_diff(draw_start, present_start),
			g.waiting ? time.Duration(0) : presented,
		)
	}

	settings_capture_window(&g.settings)
	perf_frame_end(&g.perf, g.idx, &g.searcher)
	free_all(context.temp_allocator)
	pace_frames()
	return !rl.WindowShouldClose() && !g.quit
}

// Keyboard, top-most layer first.
app_keys :: proc() {
	if rl.IsKeyPressed(.F3) {
		g.settings.show_metrics = !g.settings.show_metrics
		settings_save(&g.settings, g.settings_path)
	}
	if rl.IsKeyPressed(.F11) {
		g.settings.display_mode = current_mode() == .Windowed ? .Borderless : .Windowed
		display_apply(&g.settings)
	}
	switch {
	case g.prompt.open:
		prompt_keys()
	case g.menu.open:
		if rl.IsKeyPressed(.ESCAPE) do menu_close()
	case g.ctx.open:
		if rl.IsKeyPressed(.ESCAPE) do g.ctx.open = false
	case:
		if rl.IsKeyPressed(.ESCAPE) {
			g.menu.open = true
		} else {
			main_keys()
		}
	}
}

// Is anything still happening in the background that the screen should
// follow? Then keep drawing; otherwise sleep until there is input.
app_busy :: proc() -> bool {
	if !index_done(g.idx) do return true
	if g.res.id != g.posted_id || !g.res.complete do return true
	if sync.atomic_load(&g.launches) > 0 do return true
	return false
}

// Nothing moving? Then sleep until there is an input event, rather than
// redrawing the same picture 60 times a second. A status message still
// showing counts as moving. With the metrics panel showing, an idle fff keeps
// ticking - the panel is a live readout - at a few frames a second.
@(private = "file")
pace_frames :: proc() {
	animating := rl.GetTime() - g.status_time < STATUS_SECONDS
	idle := !app_busy() && !animating
	g.waiting = false
	if idle && g.settings.show_metrics {
		rl.DisableEventWaiting()
		if !g.idle_fps do rl.SetTargetFPS(PERF_IDLE_FPS)
		g.idle_fps = true
	} else {
		if g.idle_fps do rl.SetTargetFPS(g.settings.max_fps)
		g.idle_fps = false
		if idle {
			rl.EnableEventWaiting()
			g.waiting = true
		} else {
			rl.DisableEventWaiting()
		}
	}
}

app_shutdown :: proc() {
	settings_capture_window(&g.settings)
	settings_save(&g.settings, g.settings_path)
	log_line("closing")

	// Stop everything; wait a little for it, but not for ever: a reader stuck
	// on a slow file cannot be interrupted, and the process ending takes it
	// down anyway.
	searcher_stop(&g.searcher)
	all: [dynamic]^Index
	defer delete(all)
	append(&all, ..g.retiring[:])
	if g.idx != nil do append(&all, g.idx)
	for idx in all do index_stop(idx)
	deadline := time.tick_now()
	for time.tick_since(deadline) < time.Second {
		done := true
		for idx in all do if !index_threads_done(idx) do done = false
		if done do break
		time.sleep(10 * time.Millisecond)
	}
	watch_set_index(&g.watch, nil)
	watch_stop(&g.watch)

	font_unload(&g.font)
	rl.CloseWindow()
	log_close()
	// The index and the rest go with the process: freeing gigabytes of file
	// text one block at a time would only delay the exit.
}

// ---------------------------------------------------------------------------
// The index and the search, seen from the main thread
// ---------------------------------------------------------------------------

// Start the index again from nothing: on startup, and when a rule is removed
// (what it uncovers was never read). The old one is stopped and freed later.
reindex :: proc() {
	if g.idx != nil {
		index_stop(g.idx)
		append(&g.retiring, g.idx)
	}
	g.idx_gen += 1
	lists := rule_lists()
	max_text := i64(g.settings.max_index_mb) * 1024 * 1024
	if g.settings.max_index_mb == 0 do max_text = auto_index_limit()
	g.idx = index_start(g.root, g.idx_gen, i64(g.settings.max_file_kb) * 1024, max_text, lists[:], reader_count())
	watch_set_index(&g.watch, g.idx)
	g.rules_changed = false
	g.hidden_upto = 0
	g.rules_ver += 1
	g.view = {file = -1}
}

// Readers: reading is mostly waiting for the disk, so more readers than cores
// still helps - but not without limit.
reader_count :: proc() -> int {
	return clamp(worker_count(), 2, MAX_WORKERS)
}

// With max_index_mb = 0: half the machine's memory.
auto_index_limit :: proc() -> i64 {
	total := os_total_memory()
	return total > 0 ? total / 2 : 0
}

// A rule was ADDED: hide what it covers without reading anything again.
rules_added :: proc() {
	lists := rule_lists()
	g.hidden_upto, _ = index_apply_rules(g.idx, lists[:], 0)
	g.rules_changed = true
	g.rules_ver += 1
}

// Every frame: hide newly found files that a rule added after the walk
// started covers, and free old indexes whose threads have finished.
index_upkeep :: proc() {
	if g.rules_changed {
		lists := rule_lists()
		upto, hid := index_apply_rules(g.idx, lists[:], g.hidden_upto)
		g.hidden_upto = upto
		if hid do g.rules_ver += 1 // the search may have seen them: again
	}
	for i := len(g.retiring) - 1; i >= 0; i -= 1 {
		old := g.retiring[i]
		if !index_threads_done(old) || searcher_uses(&g.searcher, old) do continue
		unordered_remove(&g.retiring, i)
		// Freeing a big index is a lot of small frees: not on this thread.
		thread.create_and_start_with_poly_data(old, index_free, self_cleanup = true)
	}
}

// Every frame: ask for a new search if what is wanted changed, and take the
// latest results.
search_upkeep :: proc() {
	q := &g.posted
	text := string(g.query[:])
	if query_text(q) != text || q.mode != g.mode || q.k != int(g.settings.max_results) || q.idx != g.idx || q.rules_ver != g.rules_ver {
		q.text_len = copy(q.text[:], text)
		q.mode = g.mode
		q.k = int(g.settings.max_results)
		q.idx = g.idx
		q.rules_ver = g.rules_ver
		g.posted_id = searcher_post(&g.searcher, q)
		g.pattern = fuzzy.parse(text)
	}
	searcher_fetch(&g.searcher, &g.res)
}

// How many results there are to show: none, if they belong to an index that
// has since been replaced.
results_count :: proc() -> int {
	if g.idx == nil || g.res.gen != g.idx.generation do return 0
	return len(g.res.items)
}

searching :: proc() -> bool {
	return g.res.id != g.posted_id || !g.res.complete
}

// ---------------------------------------------------------------------------

// The folder to search: the first argument if there is one, else the
// working directory. Absolute, with '/' separators (Windows accepts them),
// and no trailing slash.
resolve_root :: proc() -> string {
	want := "."
	for a in os.args[min(1, len(os.args)):] {
		if strings.has_prefix(a, "-") do continue
		want = a
		break
	}
	abs, err := os.get_absolute_path(want, context.temp_allocator)
	if err != nil do abs, _ = os.get_working_directory(context.temp_allocator)
	b := strings.builder_make()
	for c in transmute([]u8)abs do strings.write_byte(&b, c == '\\' ? '/' : c)
	out := strings.to_string(b)
	for len(out) > 1 && strings.has_suffix(out, "/") && !strings.has_suffix(out, ":/") do out = out[:len(out) - 1]
	return out
}

// The absolute path of a file, in the OS's own separators.
abs_path :: proc(f: ^File, allocator := context.temp_allocator) -> string {
	p := strings.concatenate({g.root, "/", f.rel}, allocator)
	when ODIN_OS == .Windows {
		b := transmute([]u8)p
		for &c in b do if c == '/' do c = '\\'
	}
	return p
}

rule_lists :: proc() -> [2]^ignore.Rules {
	return {&g.settings.global, &g.session}
}

// ---------------------------------------------------------------------------

STATUS_SECONDS :: 4.0

set_status :: proc(format: string, args: ..any) {
	s := fmt.bprintf(g.status[:], format, ..args)
	g.status_len = len(s)
	g.status_time = rl.GetTime()
	g.status_bad = false
}

set_error :: proc(format: string, args: ..any) {
	set_status(format, ..args)
	g.status_bad = true
}

status_text :: proc() -> string {
	return string(g.status[:g.status_len])
}

// From any thread: a status line for the main thread to show.
post_status :: proc(bad: bool, format: string, args: ..any) {
	sync.lock(&g.status_mu)
	defer sync.unlock(&g.status_mu)
	g.pending_len = len(fmt.bprintf(g.pending[:], format, ..args))
	g.pending_bad = bad
}

@(private = "file")
take_status :: proc() {
	sync.lock(&g.status_mu)
	defer sync.unlock(&g.status_mu)
	if g.pending_len == 0 do return
	g.status_len = copy(g.status[:], g.pending[:g.pending_len])
	g.status_time = rl.GetTime()
	g.status_bad = g.pending_bad
	g.pending_len = 0
}
