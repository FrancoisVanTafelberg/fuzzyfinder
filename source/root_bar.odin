package fff

/*
    The folder bar, just above the search line: which folder fff searches,
    and changing it.

        dir  [↑]  E:/.workspace/fuzzyfinder                 [▼] [Browse...]

    ↑           the parent folder
    the path    click it (or Ctrl+L) to type a path: Tab completes a folder
                name, Enter switches, Esc gives up. Relative paths are from
                the current folder; ~ is the home folder.
    ▼           the folders searched recently (kept in settings.txt)
    Browse...   the system's folder picker, on a thread of its own

    Switching drops the index and reads the new folder from scratch. The
    "this search only" ignore rules go too: they are paths in the old tree.
*/

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

RECENT_ROOTS_MAX :: 10

Root_Bar :: struct {
	buf:     [dynamic]u8, // the path being typed
	cursor:  int,
	editing: bool,
	recent:  bool, // the recent folders list is open
	// Browse...: the picker thread hands its answer over here.
	mu:      sync.Mutex,
	picking: bool, // atomic
	picked:  string, // guarded by mu; owned
	problem: string, // guarded by mu; owned
	done:    bool, // guarded by mu
}

// ---------------------------------------------------------------------------
// Switching
// ---------------------------------------------------------------------------

// A path as typed or picked, made absolute (relative to the current root),
// '/'-separated, without a trailing '/' (except "/" and "C:/").
root_normalize :: proc(text: string, allocator := context.temp_allocator) -> string {
	t := strings.trim_space(text)
	t = strings.trim(t, "\"'")
	if t == "" do return ""
	if t == "~" || strings.has_prefix(t, "~/") || strings.has_prefix(t, "~\\") {
		home := os.get_env("HOME", context.temp_allocator)
		when ODIN_OS == .Windows do if home == "" do home = os.get_env("USERPROFILE", context.temp_allocator)
		if home != "" do t = strings.concatenate({home, t[1:]}, context.temp_allocator)
	}
	if !path_is_absolute(t) do t = strings.concatenate({g.root, "/", t}, context.temp_allocator)
	when ODIN_OS == .Windows do if len(t) == 2 && t[1] == ':' do t = strings.concatenate({t, "/"}, context.temp_allocator)
	abs, err := os.get_absolute_path(t, context.temp_allocator)
	if err != nil do abs = t
	b := transmute([]u8)strings.clone(abs, allocator)
	for &c in b do if c == '\\' do c = '/'
	out := string(b)
	for len(out) > 1 && strings.has_suffix(out, "/") && !strings.has_suffix(out, ":/") do out = out[:len(out) - 1]
	return out
}

@(private = "file")
path_is_absolute :: proc(p: string) -> bool {
	if len(p) == 0 do return false
	if p[0] == '/' || p[0] == '\\' do return true
	return len(p) >= 2 && p[1] == ':'
}

// Search `path` from now on. False (and a red status) if it is not a folder.
set_root :: proc(path: string) -> bool {
	abs := root_normalize(path)
	if abs == "" do return false
	if !os.is_dir(abs) {
		set_error("not a folder: %s", abs)
		return false
	}
	recent_add(abs)
	settings_save(&g.settings, g.settings_path)
	if abs == g.root do return true
	delete(g.root)
	g.root = strings.clone(abs)
	// "This search only" rules are paths in the old tree.
	ignore_session_clear()
	rl.SetWindowTitle(fmt.ctprintf("fff - %s", g.root))
	log_line("searching %s", g.root)
	g.sel = 0
	reindex()
	set_status("searching %s", g.root)
	return true
}

// The parent of the current root, or "" at the top of a drive.
root_parent :: proc() -> string {
	r := g.root
	if r == "/" || (len(r) == 3 && strings.has_suffix(r, ":/")) do return ""
	i := strings.last_index_byte(r, '/')
	if i < 0 do return ""
	if i == 0 do return "/"
	if i == 2 && r[1] == ':' do return r[:3] // "C:/"
	return r[:i]
}

recent_add :: proc(path: string) {
	rs := &g.settings.recent_roots
	for r, i in rs do if r == path {
		delete(r)
		ordered_remove(rs, i)
		break
	}
	inject_at(rs, 0, strings.clone(path))
	for len(rs) > RECENT_ROOTS_MAX do delete(pop(rs))
}

// ---------------------------------------------------------------------------
// Typing a path
// ---------------------------------------------------------------------------

root_edit_begin :: proc() {
	rb := &g.root_bar
	rb.editing = true
	rb.recent = false
	g.focus = .Root
	clear(&rb.buf)
	append(&rb.buf, g.root)
	if g.root != "/" && !strings.has_suffix(g.root, ":/") do append(&rb.buf, '/')
	rb.cursor = len(rb.buf)
}

// Enter switches to what was typed; Esc, or a click elsewhere, keeps the
// folder as it was.
root_edit_end :: proc(apply: bool) {
	rb := &g.root_bar
	if !rb.editing do return
	text := strings.clone(string(rb.buf[:]), context.temp_allocator)
	rb.editing = false
	if g.focus == .Root do g.focus = .Search
	if apply do set_root(text)
}

// Tab: complete the folder name being typed. One match is filled in whole
// (with a '/' after it); several are filled in as far as they agree, and
// listed in the status line.
root_complete :: proc() {
	rb := &g.root_bar
	text := string(rb.buf[:rb.cursor])
	sep := max(strings.last_index_byte(text, '/'), strings.last_index_byte(text, '\\'))
	dir_part := text[:sep + 1]
	partial := text[sep + 1:]
	base := dir_part == "" ? g.root : root_normalize(dir_part)

	scratch: Path_Scratch
	defer path_scratch_destroy(&scratch)
	entries := make([dynamic]Dir_Entry, context.temp_allocator)
	list_dir(&scratch, base, &entries)
	matches := make([dynamic]string, context.temp_allocator)
	for e in entries {
		if e.kind != .Dir do continue
		if name_has_prefix(e.name, partial) do append(&matches, e.name)
	}
	if len(matches) == 0 {
		set_error("no folder starting %q in %s", partial, base)
		return
	}
	slice.sort(matches[:])
	fill := matches[0]
	if len(matches) > 1 {
		// As far as they all agree.
		n := len(fill)
		for m in matches[1:] {
			k := 0
			for k < n && k < len(m) && fold_eq(fill[k], m[k]) do k += 1
			n = k
		}
		fill = fill[:n]
		shown := strings.join(matches[:min(len(matches), 8)], "  ", context.temp_allocator)
		if len(matches) > 8 do shown = fmt.tprintf("%s  ... (%v)", shown, len(matches))
		set_status("%s", shown)
	} else {
		fill = strings.concatenate({fill, "/"}, context.temp_allocator)
	}
	if len(fill) < len(partial) do return
	// Replace the partial name with the completion (its case wins).
	remove_range(&rb.buf, sep + 1, rb.cursor)
	inject_at(&rb.buf, sep + 1, ..transmute([]u8)fill)
	rb.cursor = sep + 1 + len(fill)
}

@(private = "file")
fold_eq :: proc(a, b: u8) -> bool {
	when ODIN_OS == .Windows {
		lower :: proc(c: u8) -> u8 {return c >= 'A' && c <= 'Z' ? c + 32 : c}
		return lower(a) == lower(b)
	} else {
		return a == b
	}
}

@(private = "file")
name_has_prefix :: proc(name, prefix: string) -> bool {
	if len(prefix) > len(name) do return false
	for i in 0 ..< len(prefix) do if !fold_eq(name[i], prefix[i]) do return false
	return true
}

// ---------------------------------------------------------------------------
// Browse...
// ---------------------------------------------------------------------------

@(private = "file")
Pick_Job :: struct {
	start: string, // owned
}

root_browse :: proc() {
	rb := &g.root_bar
	if sync.atomic_load(&rb.picking) do return
	sync.atomic_store(&rb.picking, true)
	job := new(Pick_Job)
	job.start = strings.clone(g.root)
	thread.create_and_start_with_poly_data(job, pick_thread, self_cleanup = true)
}

@(private = "file")
pick_thread :: proc(job: ^Pick_Job) {
	rb := &g.root_bar
	defer {
		delete(job.start)
		free(job)
		free_all(context.temp_allocator)
	}
	path, ok, problem := pick_folder(job.start)
	sync.lock(&rb.mu)
	if ok do rb.picked = path
	if problem != "" do rb.problem = strings.clone(problem)
	rb.done = true
	sync.unlock(&rb.mu)
	sync.atomic_store(&rb.picking, false)
}

// Every frame: a folder picked in the dialog becomes the root.
root_bar_upkeep :: proc() {
	rb := &g.root_bar
	sync.lock(&rb.mu)
	done := rb.done
	picked, problem := rb.picked, rb.problem
	rb.done = false
	rb.picked, rb.problem = "", ""
	sync.unlock(&rb.mu)
	if !done do return
	if problem != "" do set_error("%s", problem)
	if picked != "" do set_root(picked)
	delete(picked)
	delete(problem)
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

@(private = "file")
Root_Layout :: struct {
	up, path, recent, browse: rl.Rectangle,
	label_x:                  f32,
}

@(private = "file")
root_layout :: proc(r: rl.Rectangle) -> (l: Root_Layout) {
	f := &g.font
	h := f.lh
	y := r.y + (r.height - h) / 2
	x := r.x + f.pad
	l.label_x = x
	x += 4 * f.cw
	l.up = {x, y, 3 * f.cw, h}
	x += l.up.width + f.cw
	bw := 11 * f.cw
	l.browse = {r.x + r.width - f.pad - bw, y, bw, h}
	l.recent = {l.browse.x - f.cw - 3 * f.cw, y, 3 * f.cw, h}
	l.path = {x, y, max(0, l.recent.x - f.cw - x), h}
	return
}

root_bar_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	rb := &g.root_bar
	// Focus moved away by a click elsewhere: keep the folder as it was.
	if rb.editing && g.focus != .Root do root_edit_end(false)

	fill(r, COL_PANEL)
	fill({r.x, r.y, r.width, 1}, COL_RULE)
	l := root_layout(r)
	draw_text("dir", l.label_x, l.up.y, COL_DIM)

	parent := root_parent()
	if button(l.up, "↑", false, parent != "") do set_root(parent)

	editing := g.focus == .Root
	if !editing && ui_take_click(l.path) {
		root_edit_begin()
		editing = true
	}
	fill(l.path, COL_GUTTER)
	hot := !editing && hovered(l.path)
	outline(l.path, editing ? COL_ACCENT : (hot ? COL_EDGE : COL_RULE), editing ? 2 : 1)
	cols := int((l.path.width - f.cw) / f.cw)
	tx := l.path.x + f.cw * 0.5
	if editing {
		s := string(rb.buf[:])
		cur := text_cols(s[:rb.cursor])
		skip := max(0, cur - cols + 1)
		draw_text(s, tx, l.path.y, COL_TEXT, cols, skip)
		fill({tx + f32(cur - skip) * f.cw, l.path.y + 2, 2, f.lh - 4}, COL_ACCENT)
	} else {
		draw_text(fit_left(g.root, cols), tx, l.path.y, COL_PATH)
	}

	if button(l.recent, "▼", rb.recent) do rb.recent = !rb.recent
	picking := sync.atomic_load(&rb.picking)
	if button(l.browse, picking ? "Browsing..." : "Browse...", picking, !picking) {
		root_edit_end(false)
		rb.recent = false
		root_browse()
	}
}

// The recent folders, as a list opening upwards from the ▼ button. Like the
// context menu, it takes its clicks before the page underneath.
@(private = "file")
recent_items :: proc() -> (box: rl.Rectangle, rows: [dynamic]string) {
	f := &g.font
	rows = make([dynamic]string, context.temp_allocator)
	for r in g.settings.recent_roots do if r != g.root do append(&rows, r)
	l := root_layout(layout().root)
	cols := 24
	for r in rows do cols = max(cols, text_cols(r) + 4)
	sw := f32(rl.GetScreenWidth())
	w := min(f32(cols) * f.cw, sw * 0.7)
	n := max(len(rows), 1)
	h := f32(n) * f.lh + 2 * f.pad
	x := clamp(l.recent.x + l.recent.width - w, 2, sw - w - 2)
	box = {x, l.recent.y - h - 4, w, h}
	return
}

root_recent_input :: proc() {
	box, rows := recent_items()
	f := &g.font
	for r, i in rows {
		row := rl.Rectangle{box.x, box.y + f.pad + f32(i) * f.lh, box.width, f.lh}
		if ui_take_click(row) {
			g.root_bar.recent = false
			set_root(r)
			return
		}
	}
	l := root_layout(layout().root)
	if g.ui.clicked && !hovered(box) && !hovered(l.recent) {
		g.root_bar.recent = false
		g.ui.clicked = false
	}
	ui_take_wheel(box)
}

root_recent_draw :: proc() {
	box, rows := recent_items()
	f := &g.font
	fill({box.x + 4, box.y + 4, box.width, box.height}, {0, 0, 0, 90})
	fill(box, COL_PANEL_HI)
	outline(box, COL_EDGE)
	cols := int(box.width / f.cw) - 2
	if len(rows) == 0 {
		draw_text("(no other recent folders)", box.x + f.cw, box.y + f.pad, COL_FAINT)
		return
	}
	for r, i in rows {
		row := rl.Rectangle{box.x, box.y + f.pad + f32(i) * f.lh, box.width, f.lh}
		if hovered(row) do fill(row, COL_SEL)
		draw_text(fit_left(r, cols), row.x + f.cw, row.y, COL_TEXT)
	}
}
