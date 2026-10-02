package fff

/*
    fff - Fast Fuzzy Finder. The hot-reload boundary, and the frame.

    The arrangement is the Music Box's and Animal Kingdoms': fff is built as a
    shared library, every piece of state lives in ONE heap block (`g`), and the
    dev host hands that block back after swapping the library. The rule that
    makes it work: no package-level state that changes at runtime. Constants
    and tables are fine; anything else goes in App.

    The root of the search is the folder fff was started in, or the folder
    given as its first argument.
*/

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
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

	idx:           Index,
	session:       ignore.Rules, // "...from this search"
	rules_ver:     int, // bumped whenever either rule list changes
	search:        Search,

	query:         [dynamic]u8,
	cursor:        int, // byte offset into query
	mode:          Mode,
	focus:         Focus,
	sel:           int, // row in the results
	sel_stamp:     int, // search.stamp when sel was last validated
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

	perf:          Perf, // the metrics panel (perf.odin)
	idle_fps:      bool, // running at the idle rate for the metrics panel

	ui:            Ui_State,
	quit:          bool,
	first_run:     bool,
}

g: ^App

@(export)
game_init_window :: proc() {
	g = new(App)
	g.settings_path = settings_path()
	g.first_run = settings_load(&g.settings, g.settings_path)
	g.root = resolve_root()
	title := fmt.ctprintf("fff - %s", g.root)
	window_open(&g.settings, title, g.first_run)
	platform_init()
	rl.SetTargetFPS(g.settings.max_fps)
}

@(export)
game_init :: proc() {
	font_load(&g.font, g.settings.font_size)
	g.view.file = -1
	g.mode = .Content
	perf_init(&g.perf)
	reindex()
}

@(export)
game_update :: proc() -> bool {
	ui_begin()

	if rl.IsKeyPressed(.F3) {
		g.settings.show_metrics = !g.settings.show_metrics
		settings_save(&g.settings, g.settings_path)
	}
	if rl.IsKeyPressed(.F11) {
		g.settings.display_mode = current_mode() == .Windowed ? .Borderless : .Windowed
		display_apply(&g.settings)
	}

	// --- keyboard: the top-most layer gets it -----------------------------
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
	// Characters typed this frame that nobody read must not arrive next frame.
	for rl.GetCharPressed() != 0 {}

	// --- work: index, then search, inside a frame budget ------------------
	lists := rule_lists()
	busy := false
	if !index_done(&g.idx) {
		index_step(&g.idx, g.root, lists[:], 6 * time.Millisecond, &g.perf.acc)
		busy = true
	}
	search_step(&g.search, &g.idx, string(g.query[:]), g.mode, int(g.settings.max_results), g.rules_ver, 10 * time.Millisecond, &g.perf.acc)
	if search_busy(&g.search, &g.idx) do busy = true
	results_sync()

	// --- draw -------------------------------------------------------------
	draw_start := time.tick_now()
	rl.BeginDrawing()
	rl.ClearBackground(COL_BG)
	modal := g.menu.open || g.prompt.open
	held := g.ui
	if modal do ui_take_all()
	// The context menu takes its clicks before the page underneath sees them.
	if g.ctx.open && !modal do context_menu_input()
	main_draw()
	if modal do g.ui = held
	if g.ctx.open do context_menu_draw()
	if g.prompt.open do prompt_draw()
	if g.menu.open do menu_draw()
	wait_start := time.tick_now()
	g.perf.draw += time.tick_diff(draw_start, wait_start)
	rl.EndDrawing() // presents, then waits out the rest of the frame
	g.perf.wait += time.tick_since(wait_start)

	settings_capture_window(&g.settings)
	perf_frame_end(&g.perf, &g.idx)
	free_all(context.temp_allocator)

	// Nothing moving? Then sleep until there is an input event, rather than
	// redrawing the same picture 60 times a second. A status message that is
	// still fading counts as moving.
	//
	// With the metrics panel showing, an idle fff keeps ticking - the panel
	// is a live readout - but at a few frames a second, so the readout does
	// not mostly measure itself.
	animating := rl.GetTime() - g.status_time < STATUS_SECONDS
	idle := !busy && !animating
	if idle && g.settings.show_metrics {
		rl.DisableEventWaiting()
		if !g.idle_fps do rl.SetTargetFPS(PERF_IDLE_FPS)
		g.idle_fps = true
	} else {
		if g.idle_fps do rl.SetTargetFPS(g.settings.max_fps)
		g.idle_fps = false
		if idle do rl.EnableEventWaiting()
		else do rl.DisableEventWaiting()
	}

	return !rl.WindowShouldClose() && !g.quit
}

@(export)
game_shutdown :: proc() {
	settings_capture_window(&g.settings)
	settings_save(&g.settings, g.settings_path)
	index_destroy(&g.idx)
	search_destroy(&g.search)
	ignore.destroy(&g.session)
	delete(g.query)
	prompt_destroy()
}

@(export)
game_shutdown_window :: proc() {
	font_unload(&g.font)
	rl.CloseWindow()
	settings_destroy(&g.settings)
	delete(g.settings_path)
	delete(g.root)
	free(g)
}

@(export)
game_memory :: proc() -> rawptr {
	return g
}

@(export)
game_memory_size :: proc() -> int {
	return size_of(App)
}

@(export)
game_hot_reloaded :: proc(mem: rawptr) {
	g = (^App)(mem)
	set_status("code reloaded")
}

@(export)
game_force_reload :: proc() -> bool {
	return rl.IsKeyPressed(.F5)
}

@(export)
game_force_restart :: proc() -> bool {
	return rl.IsKeyPressed(.F6)
}

// ---------------------------------------------------------------------------

// The folder to search: the first argument if there is one, else the
// working directory. Absolute, with '/' separators (Windows accepts them),
// and no trailing slash.
resolve_root :: proc() -> string {
	// Empty inside the hot-reload library (a DLL is not handed argv); the
	// dev host changes into the folder argument instead.
	args := os.args
	want := "."
	for a in args[min(1, len(args)):] {
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

// Start the index again from nothing: on startup, and when a rule is removed
// (what it uncovers was never read).
reindex :: proc() {
	index_restart(&g.idx, i64(g.settings.max_file_kb) * 1024)
	g.rules_ver += 1
}

// A rule was ADDED: hide what it covers without reading anything again.
rules_added :: proc() {
	lists := rule_lists()
	index_apply_rules(&g.idx, lists[:])
	g.rules_ver += 1
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
