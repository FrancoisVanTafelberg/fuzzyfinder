package fff

/*
    The main screen.

        +--------------------------------------------+-----------+
        | viewer: the selected file, at the matched  |  ignored  |
        | line, with the matched characters marked   |  folders  |
        |                                            |  and file |
        +--------------------------------------------+  types    |
        | results: the best N, best first            |           |
        +--------------------------------------------+-----------+
        | content > query_                    counts / status    |
        +--------------------------------------------------------+

    Laid out from the window's size every frame - nothing is fixed - so a
    bigger window, or a smaller font, simply shows more.
*/

import "core:fmt"
import "core:strings"
import "ignore"
import rl "vendor:raylib"

Layout :: struct {
	viewer:  rl.Rectangle,
	results: rl.Rectangle,
	search:  rl.Rectangle,
	panel:   rl.Rectangle,
}

layout :: proc() -> (l: Layout) {
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	f := &g.font
	sh := f.lh + 2 * f.pad
	pw := clamp(w * 0.22, 26 * f.cw, 52 * f.cw)
	pw = min(pw, w * 0.4)
	rh := f32(g.settings.results) * f.lh + 2 * f.pad
	rh = min(rh, (h - sh) * 0.5)
	l.search = {0, h - sh, w, sh}
	l.panel = {w - pw, 0, pw, h - sh}
	l.results = {0, h - sh - rh, w - pw, rh}
	l.viewer = {0, 0, w - pw, h - sh - rh}
	return
}

// ---------------------------------------------------------------------------
// Keeping the selection and the viewer in step with the results
// ---------------------------------------------------------------------------

Viewer :: struct {
	has:  bool,
	gen:  int, // Index.generation of `file`
	mode: Mode,
	item: u32, // which result it is showing
	file: int,
	hl:   int, // the matched line, 0-based, or -1
	top:  int, // first line shown
	left: int, // columns scrolled off the left
}

results_sync :: proc() {
	n := g.search.top.n
	g.sel = clamp(g.sel, 0, max(0, n - 1))
	// A view into an index that has been rebuilt, or one made in the other
	// mode (its `item` indexes lines, not files, or the reverse), is stale.
	if g.view.has && (g.view.gen != g.idx.generation || g.view.mode != g.search.mode) {
		g.view = {file = -1}
	}
	if n == 0 do return
	item := g.search.top.items[g.sel].item
	if g.view.has && g.view.mode == g.search.mode && g.view.item == item && g.view.gen == g.idx.generation do return
	viewer_show(g.search.mode, item)
}

viewer_rows :: proc() -> int {
	l := layout()
	body := l.viewer.height - (g.font.lh + g.font.pad)
	return max(1, int(body / g.font.lh))
}

viewer_cols :: proc() -> int {
	l := layout()
	return max(1, int((l.viewer.width - gutter_width() - 2 * g.font.pad) / g.font.cw))
}

viewer_show :: proc(mode: Mode, item: u32) {
	v := &g.view
	v.has = true
	v.gen = g.idx.generation
	v.mode = mode
	v.item = item
	v.left = 0
	switch mode {
	case .Files:
		v.file = int(item)
		v.hl = -1
		v.top = 0
	case .Content:
		ref := g.idx.lines[item]
		v.file = int(ref.file)
		v.hl = int(ref.line)
		// The matched line a third of the way down: context above, more below.
		v.top = max(0, v.hl - viewer_rows() / 3)
		// A match far to the right of a long line scrolls the view across to it.
		pos: [64]int
		text, prefix, np := match_positions(&g.search, &g.idx, item, pos[:])
		for i in 0 ..< np {
			if pos[i] < prefix do continue
			col := text_cols(text[prefix:pos[i]])
			cols := viewer_cols()
			if col > cols - 4 do v.left = max(0, col - cols / 3)
			break
		}
	}
	viewer_clamp()
}

viewer_lines :: proc() -> int {
	if !g.view.has || g.view.file < 0 || g.view.file >= len(g.idx.files) do return 0
	return len(g.idx.files[g.view.file].lines)
}

viewer_clamp :: proc() {
	g.view.top = clamp(g.view.top, 0, max(0, viewer_lines() - viewer_rows()))
}

viewer_scroll :: proc(lines: int) {
	g.view.top += lines
	viewer_clamp()
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

main_draw :: proc() {
	l := layout()
	viewer_draw(l.viewer)
	results_draw(l.results)
	panel_draw(l.panel)
	search_bar_draw(l.search)
}

gutter_width :: proc() -> f32 {
	digits := len(fmt.tprint(max(viewer_lines(), 999)))
	return f32(digits + 2) * g.font.cw
}

viewer_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	fill(r, COL_BG)
	head := rl.Rectangle{r.x, r.y, r.width, f.lh + f.pad}
	fill(head, COL_PANEL)
	body := rl.Rectangle{r.x, head.y + head.height, r.width, r.height - head.height}

	if ui_take_click(r) do g.focus = .Viewer
	if w := ui_take_wheel(body); w != 0 {
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		if shift do g.view.left = max(0, g.view.left - int(w) * 8)
		else do viewer_scroll(-int(w) * 3)
	}

	focused := g.focus == .Viewer
	hx := r.x + f.pad
	hy := head.y + f.pad / 2
	if !g.view.has || g.view.file < 0 || g.view.file >= len(g.idx.files) {
		msg := index_done(&g.idx) ? "No match." : "Reading files..."
		if len(g.idx.files) == 0 && index_done(&g.idx) do msg = "Nothing to search here."
		draw_text(msg, hx, hy, COL_DIM)
		if focused do outline(r, COL_ACCENT, 2)
		return
	}

	file := &g.idx.files[g.view.file]
	// Header: the path, and where in it we are.
	right := ""
	if file.state == .Text {
		line := g.view.hl >= 0 ? g.view.hl + 1 : g.view.top + 1
		right = fmt.tprintf("line %v of %v", line, len(file.lines))
		if g.view.left > 0 do right = fmt.tprintf("%s, col %v", right, g.view.left + 1)
	}
	rcols := text_cols(right)
	hcols := int((head.width - 2 * f.pad) / f.cw) - rcols - 2
	draw_text(fit_left(file.rel, hcols), hx, hy, COL_PATH)
	draw_text(right, r.x + r.width - f.pad - f32(rcols) * f.cw, hy, COL_DIM)

	gw := gutter_width()
	fill({body.x, body.y, gw, body.height}, COL_GUTTER)

	switch file.state {
	case .Text:
	case .Pending:
		draw_text("Reading...", body.x + gw + f.pad, body.y + f.pad, COL_DIM)
	case .Binary:
		draw_text("Binary file - not shown. Press Enter to open it.", body.x + gw + f.pad, body.y + f.pad, COL_DIM)
	case .Too_Big:
		draw_text(fmt.tprintf("Larger than %v KB (max_file_kb in settings.txt) - not read.", g.settings.max_file_kb), body.x + gw + f.pad, body.y + f.pad, COL_DIM)
	case .Unreadable:
		draw_text("Could not be read.", body.x + gw + f.pad, body.y + f.pad, COL_BAD)
	}

	if file.state == .Text {
		rows := int(body.height / f.lh)
		cols := int((body.width - gw - 2 * f.pad) / f.cw)
		tx := body.x + gw + f.pad
		// The matched characters on the matched line.
		hl_pos: [fuzzy_positions]int
		hl_n := 0
		hl_base := 0
		if g.view.hl >= 0 && g.view.mode == .Content && g.search.mode == .Content {
			_, prefix, n := match_positions(&g.search, &g.idx, g.view.item, hl_pos[:])
			hl_n = n
			hl_base = prefix
			// Positions inside the path prefix are not on this line.
			k := 0
			for i in 0 ..< hl_n do if hl_pos[i] >= prefix {
				hl_pos[k] = hl_pos[i]
				k += 1
			}
			hl_n = k
		}
		rl.BeginScissorMode(i32(body.x), i32(body.y), i32(body.width), i32(body.height))
		for row in 0 ..< rows + 1 {
			ln := g.view.top + row
			if ln >= len(file.lines) do break
			y := body.y + f32(row) * f.lh
			is_hl := ln == g.view.hl
			if is_hl {
				fill({body.x, y, body.width, f.lh}, COL_HL_LINE)
				fill({body.x, y, 3, f.lh}, COL_ACCENT)
			}
			num := fmt.tprint(ln + 1)
			draw_text(num, body.x + gw - f32(len(num) + 1) * f.cw, y, is_hl ? COL_ACCENT : COL_FAINT)
			text := line_text(file, ln)
			if is_hl {
				draw_text(text, tx, y, COL_TEXT, cols, g.view.left, hl_pos[:hl_n], hl_base)
			} else {
				draw_text(text, tx, y, COL_TEXT, cols, g.view.left)
			}
		}
		rl.EndScissorMode()

		// Scrollbar.
		total := len(file.lines)
		if total > rows && rows > 0 {
			track := rl.Rectangle{body.x + body.width - 6, body.y, 6, body.height}
			fill(track, COL_GUTTER)
			th := max(f.lh, body.height * f32(rows) / f32(total))
			ty := body.y + (body.height - th) * f32(g.view.top) / f32(max(1, total - rows))
			fill({track.x + 1, ty, 4, th}, focused ? COL_ACCENT : COL_EDGE)
			if g.view.hl >= 0 {
				my := body.y + body.height * f32(g.view.hl) / f32(total)
				fill({track.x - 2, my, 8, 2}, COL_MATCH)
			}
		}
	}

	if focused do outline(r, COL_ACCENT, 2)
}

fuzzy_positions :: 256

results_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	fill(r, COL_PANEL)
	fill({r.x, r.y, r.width, 1}, COL_EDGE)
	rows := max(1, int((r.height - 2 * f.pad) / f.lh))
	n := g.search.top.n

	// Keep the selection on screen when there are more results than rows.
	first := &g.res_first
	if g.sel < first^ do first^ = g.sel
	if g.sel >= first^ + rows do first^ = g.sel - rows + 1
	first^ = clamp(first^, 0, max(0, n - rows))

	if w := ui_take_wheel(r); w != 0 && n > 0 do g.sel = clamp(g.sel - int(w), 0, n - 1)

	cols := int((r.width - 2 * f.pad) / f.cw) - 1
	for row in 0 ..< rows {
		i := first^ + row
		if i >= n do break
		y := r.y + f.pad + f32(row) * f.lh
		rr := rl.Rectangle{r.x, y, r.width, f.lh}
		if i == g.sel {
			fill(rr, COL_SEL)
			fill({r.x, y, 3, f.lh}, COL_ACCENT)
		} else if hovered(rr) {
			fill(rr, COL_PANEL_HI)
		}
		item := g.search.top.items[i].item

		if ui_take_click(rr) {
			// A second click on the same row soon after is a double-click.
			now := rl.GetTime()
			g.sel = i
			if g.click_row == i && now - g.click_time < 0.4 do open_selected()
			g.click_time = now
			g.click_row = i
		}
		if ui_take_right(rr) {
			g.sel = i
			context_menu_open(g.ui.mouse, i)
		}

		result_row_draw(item, r.x + f.pad + f.cw, y, cols)
	}
	if n == 0 && len(g.query) > 0 && !search_busy(&g.search, &g.idx) {
		draw_text("No matches.", r.x + f.pad + f.cw, r.y + f.pad, COL_DIM)
	}
}

// One result: path, line number, text - the matched characters marked.
result_row_draw :: proc(item: u32, x, y: f32, cols: int) {
	pos: [fuzzy_positions]int
	text, prefix, np := match_positions(&g.search, &g.idx, item, pos[:])
	hl := pos[:np]
	f := &g.font
	switch g.search.mode {
	case .Files:
		draw_text(text, x, y, COL_PATH, cols, 0, hl)
	case .Content:
		ref := g.idx.lines[item]
		file := &g.idx.files[ref.file]
		pl := min(len(file.rel), len(text)) // the candidate may have been cut short
		c := draw_text(text[:pl], x, y, COL_PATH, cols, 0, hl)
		num := fmt.tprintf(":%v: ", ref.line + 1)
		c += draw_text(num, x + f32(c) * f.cw, y, COL_NUM, cols - c)
		// The line without its indentation: the indentation is noise here,
		// and the viewer shows it in place.
		body := text[prefix:]
		trimmed := strings.trim_left(body, " \t")
		skipped := len(body) - len(trimmed)
		draw_text(trimmed, x + f32(c) * f.cw, y, COL_TEXT, cols - c, 0, hl, prefix + skipped)
	}
}

search_bar_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	fill(r, COL_GUTTER)
	fill({r.x, r.y, r.width, 1}, COL_EDGE)
	if ui_take_click(r) do g.focus = .Search
	focused := g.focus == .Search
	y := r.y + f.pad
	x := r.x + f.pad

	prompt := fmt.tprintf("%s > ", MODE_NAME[g.mode])
	x += f32(draw_text(prompt, x, y, focused ? COL_ACCENT : COL_DIM)) * f.cw

	// What is on the right decides how much room the query gets.
	right: string
	right_col := COL_DIM
	if rl.GetTime() - g.status_time < STATUS_SECONDS && g.status_len > 0 {
		right = status_text()
		right_col = g.status_bad ? COL_BAD : COL_GOOD
	} else {
		total := search_items(&g.idx, g.mode)
		right = fmt.tprintf("%s / %s", thousands(g.search.matched), thousands(total))
		if g.mode == .Content do right = fmt.tprintf("%s   %s files", right, thousands(len(g.idx.files)))
		if !index_done(&g.idx) {
			right = fmt.tprintf("%s   reading %v%%", right, int(index_progress(&g.idx) * 100))
		} else if search_busy(&g.search, &g.idx) {
			right = fmt.tprintf("%s   searching", right)
		}
	}
	right = fit(right, int(r.width / f.cw / 2))
	rw := text_width(right)
	draw_text(right, r.x + r.width - f.pad - rw, y, right_col)

	qcols := int((r.x + r.width - f.pad - rw - 2 * f.cw - x) / f.cw)
	q := string(g.query[:])
	// Scroll the query so the cursor stays visible.
	cur_col := text_cols(q[:g.cursor])
	skip := max(0, cur_col - qcols + 1)
	draw_text(q, x, y, COL_TEXT, qcols, skip)
	if len(q) == 0 && !focused {
		draw_text("(Tab to type)", x, y, COL_FAINT)
	}
	if focused {
		cx := x + f32(cur_col - skip) * f.cw
		fill({cx, y + 2, 2, f.lh - 4}, COL_ACCENT)
		outline(r, COL_ACCENT, 2)
	}
}

// ---------------------------------------------------------------------------
// The ignore panel
// ---------------------------------------------------------------------------

panel_draw :: proc(r: rl.Rectangle) {
	f := &g.font
	fill(r, COL_PANEL)
	fill({r.x, r.y, 1, r.height}, COL_EDGE)
	x := r.x + f.pad
	w := r.width - 2 * f.pad
	cols := int(w / f.cw)

	// The key legend sits at the bottom; the lists scroll above it.
	legend := [?][2]string {
		{"Up/Down", "select result"},
		{"Enter", "open at line"},
		{"Tab", "search / viewer"},
		{"W / S", "viewer line"},
		{"E / D", "viewer half page"},
		{"Alt+C/F", "content / files"},
		{"Right-click", "more"},
		{"Esc", "menu"},
	}
	lh := f.lh
	legend_h := f32(len(legend)) * lh + 2 * f.pad
	legend_y := r.y + r.height - legend_h
	list := rl.Rectangle{r.x, r.y, r.width, legend_y - r.y}

	if wv := ui_take_wheel(list); wv != 0 do g.panel_scroll -= wv * lh * 3
	rl.BeginScissorMode(i32(list.x), i32(list.y), i32(list.width), i32(list.height))
	y := r.y + f.pad - g.panel_scroll
	draw_text("Ignored", x, y, COL_ACCENT)
	y += lh * 1.5

	section :: proc(title: string, rules: ^ignore.Rules, x, y: ^f32, w: f32, cols: int, global: bool) {
		f := &g.font
		draw_text(title, x^, y^, COL_DIM)
		y^ += f.lh
		if len(rules.folders) == 0 && len(rules.types) == 0 {
			draw_text("  (none)", x^, y^, COL_FAINT)
			y^ += f.lh
		}
		remove_folder, remove_type := -1, -1
		for e, i in rules.folders {
			if panel_row(e, x^, y^, w, cols, COL_TEXT) do remove_folder = i
			y^ += f.lh
		}
		for e, i in rules.types {
			if panel_row(fmt.tprintf("*.%s", e), x^, y^, w, cols, COL_TEXT) do remove_type = i
			y^ += f.lh
		}
		if remove_folder >= 0 || remove_type >= 0 {
			what := remove_folder >= 0 ? rules.folders[remove_folder] : fmt.tprintf("*.%s", rules.types[remove_type])
			set_status("no longer ignoring %s", what)
			ignore.remove_folder(rules, remove_folder)
			ignore.remove_type(rules, remove_type)
			if global do settings_save(&g.settings, g.settings_path)
			reindex()
		}
		y^ += f.lh * 0.5
	}
	section("All searches", &g.settings.global, &x, &y, w, cols, true)
	section("This search only", &g.session, &x, &y, w, cols, false)
	draw_text(fit("Right-click a result to add.", cols), x, y, COL_FAINT)
	y += lh
	content_h := y + g.panel_scroll - r.y
	rl.EndScissorMode()
	g.panel_scroll = clamp(g.panel_scroll, 0, max(0, content_h - list.height))

	fill({r.x, legend_y, r.width, 1}, COL_EDGE)
	ly := legend_y + f.pad
	kw := 0
	for k in legend do kw = max(kw, len(k[0]))
	for k in legend {
		draw_text(k[0], x, ly, COL_ACCENT)
		draw_text(fit(k[1], cols - kw - 1), x + f32(kw + 1) * f.cw, ly, COL_DIM)
		ly += lh
	}
}

// A row with an x at its end. True if the x was clicked.
panel_row :: proc(label: string, x, y, w: f32, cols: int, col: rl.Color) -> bool {
	f := &g.font
	row := rl.Rectangle{x - f.pad / 2, y, w + f.pad, f.lh}
	hot := hovered(row)
	if hot do fill(row, COL_PANEL_HI)
	draw_text(fit(label, cols - 3), x + f.cw, y, col)
	xr := rl.Rectangle{x + w - f.lh, y, f.lh, f.lh}
	if hot {
		over := hovered(xr)
		if over do fill(xr, COL_BUTTON_HOT)
		text_centered("×", xr, over ? COL_BAD : COL_DIM)
	}
	return ui_take_click(xr)
}

