package fff

/*
    What draws on top of the main screen: the right-click menu on a result,
    the Esc menu, and (on Linux) the Open In... command prompt.
*/

import "core:fmt"
import "core:strings"
import "ignore"
import rl "vendor:raylib"

// ---------------------------------------------------------------------------
// Right-click on a result
// ---------------------------------------------------------------------------

Ctx_Action :: enum u8 {
	Open_Default,
	Open_In,
	Folder_All,
	Folder_Session,
	Type_All,
	Type_Session,
}

Context_Menu :: struct {
	open: bool,
	pos:  rl.Vector2,
	file: int,
	line: int,
	gen:  int,
}

context_menu_open :: proc(at: rl.Vector2, row: int) {
	g.sel = row
	file, line, ok := selected_target()
	if !ok do return
	g.ctx = {
		open = true,
		pos  = at,
		file = file,
		line = line,
		gen  = g.idx.generation,
	}
}

// What the folder and type entries would be for this file. The folder for
// "all searches" is the parent's NAME ("rlu/", matching any folder so named);
// for "this search" it is the parent's PATH from the root ("/source/rlu/").
@(private = "file")
ctx_targets :: proc(rel: string) -> (name_entry, path_entry, type_entry: string) {
	if i := strings.last_index_byte(rel, '/'); i > 0 {
		parent := rel[:i]
		name := parent
		if j := strings.last_index_byte(parent, '/'); j >= 0 do name = parent[j + 1:]
		name_entry = fmt.tprintf("%s/", name)
		path_entry = fmt.tprintf("/%s/", parent)
	}
	buf: [64]u8
	if e := ignore.ext_of(rel, buf[:]); e != "" do type_entry = strings.clone(e, context.temp_allocator)
	return
}

@(private = "file")
Ctx_Item :: struct {
	action:  Ctx_Action,
	label:   string,
	enabled: bool,
	rect:    rl.Rectangle,
}

@(private = "file")
ctx_items :: proc() -> (items: [len(Ctx_Action)]Ctx_Item, box: rl.Rectangle) {
	f := &g.font
	if g.ctx.gen != g.idx.generation || g.ctx.file < 0 || g.ctx.file >= len(g.idx.files) {
		g.ctx.open = false
		return
	}
	rel := g.idx.files[g.ctx.file].rel
	name_e, path_e, type_e := ctx_targets(rel)
	open_in := "Open In..."
	labels := [Ctx_Action]string {
		.Open_Default   = "Open In System Default",
		.Open_In        = open_in,
		.Folder_All     = name_e != "" ? fmt.tprintf("Exclude folder %s from all searches", name_e) : "Exclude folder from all searches",
		.Folder_Session = path_e != "" ? fmt.tprintf("Exclude folder %s from this search", path_e) : "Exclude folder from this search",
		.Type_All       = type_e != "" ? fmt.tprintf("Exclude *.%s from all searches", type_e) : "Exclude file type from all searches",
		.Type_Session   = type_e != "" ? fmt.tprintf("Exclude *.%s from this search", type_e) : "Exclude file type from this search",
	}
	enabled := [Ctx_Action]bool {
		.Open_Default   = true,
		.Open_In        = true,
		.Folder_All     = name_e != "",
		.Folder_Session = path_e != "",
		.Type_All       = type_e != "",
		.Type_Session   = type_e != "",
	}
	cols := 0
	for l in labels do cols = max(cols, text_cols(l))
	w := f32(cols + 4) * f.cw
	h := f32(len(Ctx_Action)) * f.lh + 2 * f.pad + f.pad // + a separator
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	x := min(g.ctx.pos.x, sw - w - 2)
	y := min(g.ctx.pos.y, sh - h - 2)
	box = {max(0, x), max(0, y), w, h}
	ry := box.y + f.pad
	for a in Ctx_Action {
		if a == .Folder_All do ry += f.pad // separator between opening and excluding
		items[a] = {a, labels[a], enabled[a], {box.x, ry, box.width, f.lh}}
		ry += f.lh
	}
	return
}

context_menu_input :: proc() {
	items, box := ctx_items()
	if !g.ctx.open do return
	for it in items {
		if !it.enabled do continue
		if ui_take_click(it.rect) {
			g.ctx.open = false
			context_action(it.action)
			return
		}
	}
	// A click anywhere else closes the menu and is used up doing so; a
	// right-click elsewhere closes it and goes on to open the next one.
	if g.ui.clicked {
		if !hovered(box) do g.ctx.open = false
		g.ui.clicked = false
	}
	if g.ui.right && !hovered(box) do g.ctx.open = false
	ui_take_wheel(box)
}

context_menu_draw :: proc() {
	items, box := ctx_items()
	if !g.ctx.open do return
	f := &g.font
	fill({box.x + 4, box.y + 4, box.width, box.height}, {0, 0, 0, 90})
	fill(box, COL_PANEL_HI)
	outline(box, COL_EDGE)
	for it in items {
		if it.enabled && hovered(it.rect) do fill(it.rect, COL_SEL)
		draw_text(it.label, it.rect.x + 2 * f.cw, it.rect.y, it.enabled ? COL_TEXT : COL_FAINT)
		if it.action == .Folder_All do fill({box.x + f.pad, it.rect.y - f.pad / 2 - 1, box.width - 2 * f.pad, 1}, COL_EDGE)
	}
}

@(private = "file")
context_action :: proc(a: Ctx_Action) {
	f := &g.idx.files[g.ctx.file]
	name_e, path_e, type_e := ctx_targets(f.rel)
	switch a {
	case .Open_Default:
		open_default(abs_path(f), f.rel)
	case .Open_In:
		open_in(abs_path(f), g.ctx.line, f.rel)
	case .Folder_All:
		if ignore.add_folder(&g.settings.global, name_e) {
			settings_save(&g.settings, g.settings_path)
			rules_added()
			set_status("ignoring folders named %s everywhere", name_e)
		}
	case .Folder_Session:
		if ignore.add_folder(&g.session, path_e) {
			rules_added()
			set_status("ignoring %s in this search", path_e)
		}
	case .Type_All:
		if ignore.add_type(&g.settings.global, type_e) {
			settings_save(&g.settings, g.settings_path)
			rules_added()
			set_status("ignoring *.%s everywhere", type_e)
		}
	case .Type_Session:
		if ignore.add_type(&g.session, type_e) {
			rules_added()
			set_status("ignoring *.%s in this search", type_e)
		}
	}
}

// ---------------------------------------------------------------------------
// The Esc menu
// ---------------------------------------------------------------------------

Menu_State :: struct {
	open: bool,
}

menu_close :: proc() {
	g.menu.open = false
	settings_capture_window(&g.settings)
	settings_save(&g.settings, g.settings_path)
}

menu_draw :: proc() {
	f := &g.font
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	fill({0, 0, sw, sh}, COL_SCRIM)

	cols := 64
	w := min(sw - 2 * f.pad, f32(cols) * f.cw + 4 * f.pad)
	row := f.lh + f.pad
	h := min(sh - 2 * f.pad, row * 11 + 2 * f.pad)
	box := rl.Rectangle{(sw - w) / 2, (sh - h) / 2, w, h}
	fill(box, COL_PANEL)
	outline(box, COL_EDGE)
	// A click outside the box closes the menu.
	if g.ui.clicked && !hovered(box) {
		g.ui.clicked = false
		menu_close()
		return
	}

	x := box.x + 2 * f.pad
	y := box.y + f.pad
	inner := box.width - 4 * f.pad
	draw_text("fff - Fast Fuzzy Finder", x, y, COL_ACCENT)
	y += row * 1.2
	label_w := f32(14) * f.cw
	cx := x + label_w
	cw := inner - label_w
	bh := f.lh + f.pad / 2
	s := &g.settings

	// --- display mode
	draw_text("Display", x, y + f.pad / 4, COL_DIM)
	{
		bw := (cw - 2 * f.pad) / 3
		for m, i in Display_Mode {
			if button({cx + f32(i) * (bw + f.pad), y, bw, bh}, DISPLAY_MODE_LABEL[m], s.display_mode == m) && s.display_mode != m {
				s.display_mode = m
				display_apply(s)
			}
		}
	}
	y += row

	// --- resolution (windowed only)
	draw_text("Resolution", x, y + f.pad / 4, COL_DIM)
	{
		windowed := s.display_mode == .Windowed
		mon := rl.GetCurrentMonitor()
		list: [len(RESOLUTIONS)]Resolution
		n := resolutions_for(rl.GetMonitorWidth(mon), rl.GetMonitorHeight(mon), list[:])
		now_w, now_h := rl.GetScreenWidth(), rl.GetScreenHeight()
		i := resolution_index(list[:n], now_w, now_h)
		exact := list[i].w == now_w && list[i].h == now_h
		shown := fmt.tprintf("%v x %v", now_w, now_h)
		if exact && list[i].note != "" do shown = fmt.tprintf("%s  (%s)", shown, list[i].note)
		if !windowed do shown = fmt.tprintf("%v x %v  (the monitor)", now_w, now_h)
		if step := stepper({cx, y, cw, bh}, shown, windowed); step != 0 {
			// Off a listed size, the first step lands on the nearest one in
			// that direction rather than skipping past it.
			j := i + step
			if !exact {
				j = i
				if step > 0 && (list[i].w * list[i].h) <= now_w * now_h do j = i + 1
				if step < 0 && (list[i].w * list[i].h) >= now_w * now_h do j = i - 1
			}
			j = clamp(j, 0, n - 1)
			s.window_w, s.window_h = list[j].w, list[j].h
			display_apply(s)
		}
	}
	y += row

	// --- font size
	draw_text("Font size", x, y + f.pad / 4, COL_DIM)
	if step := stepper({cx, y, cw, bh}, fmt.tprintf("%v px", s.font_size)); step != 0 {
		s.font_size = clamp(s.font_size + i32(step), FONT_MIN, FONT_MAX)
		font_load(&g.font, s.font_size)
		return // everything is measured in the font; draw again next frame
	}
	y += row

	// --- result rows
	draw_text("Results", x, y + f.pad / 4, COL_DIM)
	if step := stepper({cx, y, cw, bh}, fmt.tprintf("%v rows", s.results)); step != 0 {
		s.results = clamp(s.results + i32(step), RESULTS_MIN, RESULTS_MAX)
	}
	y += row

	// --- frame cap
	draw_text("Max FPS", x, y + f.pad / 4, COL_DIM)
	{
		caps := [?]i32{30, 60, 120, 144, 165, 240, 0}
		i := 0
		for c, k in caps do if c == s.max_fps do i = k
		shown := s.max_fps == 0 ? "uncapped" : fmt.tprint(s.max_fps)
		if step := stepper({cx, y, cw, bh}, shown); step != 0 {
			s.max_fps = caps[clamp(i + step, 0, len(caps) - 1)]
			rl.SetTargetFPS(s.max_fps)
		}
	}
	y += row * 1.3

	cols_v := int(cw / f.cw)
	draw_text("Enter opens", x, y, COL_DIM)
	draw_text(fit(s.editor == "" ? "the system's default app (at the line, for known editors)" : s.editor, cols_v), cx, y, COL_TEXT)
	y += f.lh
	draw_text("Searching", x, y, COL_DIM)
	draw_text(fit_left(g.root, cols_v), cx, y, COL_TEXT)
	y += f.lh
	draw_text("Settings", x, y, COL_DIM)
	draw_text(fit_left(g.settings_path, cols_v), cx, y, COL_TEXT)
	y += f.lh * 1.6

	bw := (inner - f.pad) / 2
	if button({x, y, bw, bh}, "Resume (Esc)") do menu_close()
	if button({x + bw + f.pad, y, bw, bh}, "Quit fff") {
		menu_close()
		g.quit = true
	}
}

// ---------------------------------------------------------------------------
// Open In... on Linux: type the command
// ---------------------------------------------------------------------------
//
// Windows has a system "Open with" dialog and fff uses it. Linux has no such
// thing that every desktop shares, so fff asks for a command - "gedit",
// "code -g {file}:{line}" - and remembers the last few.

Prompt :: struct {
	open:   bool,
	text:   [dynamic]u8,
	cursor: int,
	path:   string, // owned
	rel:    string, // owned
	line:   int,
}

prompt_open :: proc(path: string, line: int, rel: string) {
	prompt_destroy()
	g.prompt.open = true
	g.prompt.path = strings.clone(path)
	g.prompt.rel = strings.clone(rel)
	g.prompt.line = line
	if len(g.settings.open_with_recent) > 0 {
		append(&g.prompt.text, g.settings.open_with_recent[0])
		g.prompt.cursor = len(g.prompt.text)
	}
}

prompt_destroy :: proc() {
	delete(g.prompt.text)
	delete(g.prompt.path)
	delete(g.prompt.rel)
	g.prompt = {}
}

prompt_keys :: proc() {
	if rl.IsKeyPressed(.ESCAPE) {
		prompt_destroy()
		return
	}
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		prompt_run(strings.clone(string(g.prompt.text[:]), context.temp_allocator))
		return
	}
	edit_line(&g.prompt.text, &g.prompt.cursor)
}

@(private = "file")
prompt_run :: proc(cmd: string) {
	c := strings.trim_space(cmd)
	if c == "" do return
	if run_template(c, g.prompt.path, g.prompt.line) {
		remember_open_with(&g.settings, c)
		settings_save(&g.settings, g.settings_path)
		set_status("opened %s with %s", g.prompt.rel, c)
	} else {
		set_error("could not run: %s", c)
	}
	prompt_destroy()
}

prompt_draw :: proc() {
	f := &g.font
	sw, sh := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())
	fill({0, 0, sw, sh}, COL_SCRIM)
	recent := g.settings.open_with_recent[:]
	w := min(sw - 2 * f.pad, 80 * f.cw)
	h := f.lh * f32(5 + len(recent)) + 3 * f.pad
	box := rl.Rectangle{(sw - w) / 2, (sh - h) / 3, w, h}
	fill(box, COL_PANEL)
	outline(box, COL_EDGE)
	if g.ui.clicked && !hovered(box) {
		g.ui.clicked = false
		prompt_destroy()
		return
	}
	x := box.x + f.pad
	y := box.y + f.pad
	cols := int((w - 2 * f.pad) / f.cw)
	draw_text(fit_left(fmt.tprintf("Open %s with:", g.prompt.rel), cols), x, y, COL_ACCENT)
	y += f.lh * 1.2
	field := rl.Rectangle{x, y, w - 2 * f.pad, f.lh}
	fill(field, COL_GUTTER)
	outline(field, COL_ACCENT)
	t := string(g.prompt.text[:])
	cur := text_cols(t[:g.prompt.cursor])
	skip := max(0, cur - cols + 2)
	draw_text(t, x + f.cw / 2, y, COL_TEXT, cols - 1, skip)
	fill({x + f.cw / 2 + f32(cur - skip) * f.cw, y + 2, 2, f.lh - 4}, COL_ACCENT)
	y += f.lh * 1.2
	draw_text(fit("{file} and {line} are filled in; without {file} the path goes last.", cols), x, y, COL_FAINT)
	y += f.lh * 1.4
	if len(recent) > 0 {
		draw_text("Recent:", x, y, COL_DIM)
		y += f.lh
		for c in recent {
			rr := rl.Rectangle{x, y, w - 2 * f.pad, f.lh}
			if hovered(rr) do fill(rr, COL_SEL)
			draw_text(fit(c, cols - 2), x + 2 * f.cw, y, COL_TEXT)
			if ui_take_click(rr) {
				prompt_run(strings.clone(c, context.temp_allocator))
				return
			}
			y += f.lh
		}
	}
}
