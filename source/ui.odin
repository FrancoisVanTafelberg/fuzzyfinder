package fff

/*
    Drawing: the palette, the font, and a handful of immediate-mode widgets.

    Same shape as the Music Box's ui.odin - a button is a rectangle that
    returns true on the frame it was clicked, and the first widget to see a
    click consumes it - but drawn at the window's real resolution with a real
    monospace face rather than into a pixel canvas with raylib's built-in one.
    Code has to be readable at any size, and everything here scales from one
    number: the font size in the Esc menu.

    THE FONT IS INSIDE THE EXE. JetBrains Mono (SIL Open Font License, see
    source/fonts/OFL.txt) is #load-ed at compile time, so fff.exe needs no
    font files beside it and looks the same on every machine.
*/

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

@(rodata)
FONT_TTF := #load("fonts/JetBrainsMono-Regular.ttf")

COL_BG :: rl.Color{22, 24, 30, 255}
COL_PANEL :: rl.Color{29, 32, 41, 255}
COL_PANEL_HI :: rl.Color{38, 42, 54, 255}
COL_GUTTER :: rl.Color{26, 28, 36, 255}
COL_EDGE :: rl.Color{56, 61, 78, 255}
COL_TEXT :: rl.Color{216, 220, 228, 255}
COL_DIM :: rl.Color{132, 138, 158, 255}
COL_FAINT :: rl.Color{84, 90, 108, 255}
COL_ACCENT :: rl.Color{255, 196, 84, 255}
COL_MATCH :: rl.Color{255, 160, 64, 255}
COL_PATH :: rl.Color{122, 176, 236, 255}
COL_NUM :: rl.Color{126, 196, 140, 255}
COL_SEL :: rl.Color{48, 57, 84, 255}
COL_HL_LINE :: rl.Color{66, 56, 30, 255}
COL_BUTTON :: rl.Color{44, 49, 66, 255}
COL_BUTTON_HOT :: rl.Color{62, 70, 96, 255}
COL_BUTTON_ON :: rl.Color{92, 76, 36, 255}
COL_GOOD :: rl.Color{120, 214, 140, 255}
COL_BAD :: rl.Color{246, 102, 102, 255}
COL_SCRIM :: rl.Color{0, 0, 0, 150}

TAB_WIDTH :: 4

Font :: struct {
	font:   rl.Font,
	px:     i32,
	cw:     f32, // advance of one cell: the face is monospace
	lh:     f32, // line height
	pad:    f32, // the unit every gap is measured in
	loaded: bool,
}

// What the face is asked for. JetBrains Mono has far more, but raylib looks
// glyphs up by a linear scan, so the atlas holds what source code and its
// comments actually use: ASCII and Latin first (the scan is short for them),
// then punctuation, arrows, box drawing and a few symbols.
@(private = "file")
font_codepoints :: proc() -> []rune {
	out := make([dynamic]rune, 0, 1024, context.temp_allocator)
	ranges := [?][2]rune {
		{0x20, 0x7E}, // ASCII
		{0xA0, 0x17F}, // Latin-1, Latin Extended-A
		{0x2010, 0x2027}, // dashes, quotes, bullet, ellipsis
		{0x2030, 0x203A},
		{0x20AC, 0x20AC}, // euro
		{0x2190, 0x21FF}, // arrows
		{0x2200, 0x22FF}, // maths
		{0x2500, 0x259F}, // box drawing, blocks
		{0x25A0, 0x25FF}, // shapes
		{0x2713, 0x2717}, // ticks and crosses
	}
	for r in ranges do for c := r[0]; c <= r[1]; c += 1 do append(&out, c)
	return out[:]
}

font_load :: proc(f: ^Font, px: i32) {
	if f.loaded do rl.UnloadFont(f.font)
	cps := font_codepoints()
	f.font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_TTF), i32(len(FONT_TTF)), px, raw_data(cps), i32(len(cps)))
	rl.SetTextureFilter(f.font.texture, .BILINEAR)
	f.px = px
	adv := f32(0)
	if f.font.glyphCount > 0 {
		i := rl.GetGlyphIndex(f.font, 'M')
		adv = f32(f.font.glyphs[i].advanceX)
		if adv <= 0 do adv = f.font.recs[i].width
	}
	f.cw = adv > 0 ? adv : f32(px) * 0.6
	f.lh = f32(i32(f32(px) * 1.4 + 0.5))
	f.pad = f32(max(4, px / 3))
	f.loaded = true
}

font_unload :: proc(f: ^Font) {
	if f.loaded do rl.UnloadFont(f.font)
	f.loaded = false
}

// ---------------------------------------------------------------------------
// Mouse and clicks
// ---------------------------------------------------------------------------

Ui_State :: struct {
	mouse:   rl.Vector2,
	clicked: bool, // left button went down this frame and nobody has taken it
	right:   bool,
	wheel:   f32,
	down:    bool,
}

ui_begin :: proc() {
	g.ui.mouse = rl.GetMousePosition()
	g.ui.clicked = rl.IsMouseButtonPressed(.LEFT)
	g.ui.right = rl.IsMouseButtonPressed(.RIGHT)
	g.ui.wheel = rl.GetMouseWheelMove()
	g.ui.down = rl.IsMouseButtonDown(.LEFT)
}

hovered :: proc(r: rl.Rectangle) -> bool {
	return rl.CheckCollisionPointRec(g.ui.mouse, r)
}

ui_take_click :: proc(r: rl.Rectangle) -> bool {
	if g.ui.clicked && hovered(r) {
		g.ui.clicked = false
		return true
	}
	return false
}

ui_take_right :: proc(r: rl.Rectangle) -> bool {
	if g.ui.right && hovered(r) {
		g.ui.right = false
		return true
	}
	return false
}

ui_take_wheel :: proc(r: rl.Rectangle) -> f32 {
	if g.ui.wheel != 0 && hovered(r) {
		w := g.ui.wheel
		g.ui.wheel = 0
		return w
	}
	return 0
}

ui_take_all :: proc() {
	g.ui.clicked = false
	g.ui.right = false
	g.ui.wheel = 0
}

// ---------------------------------------------------------------------------
// Shapes and text
// ---------------------------------------------------------------------------

fill :: proc(r: rl.Rectangle, c: rl.Color) {
	rl.DrawRectangleRec(r, c)
}

outline :: proc(r: rl.Rectangle, c: rl.Color, thick: f32 = 1) {
	rl.DrawRectangleLinesEx(r, thick, c)
}

// Columns a string takes, with tabs expanded.
text_cols :: proc(s: string) -> int {
	col := 0
	for r in s do col = r == '\t' ? (col / TAB_WIDTH + 1) * TAB_WIDTH : col + 1
	return col
}

text_width :: proc(s: string) -> f32 {
	return f32(text_cols(s)) * g.font.cw
}

// The one way text reaches the screen.
//
// Monospace, so a column is a cell and positions are arithmetic. Tabs expand
// to the next multiple of TAB_WIDTH. `skip` columns are scrolled off the
// left, and nothing past `max_cols` is drawn. `hl` lists BYTE offsets (into
// `s`, minus `hl_base`) to draw in `hl_col` with an underline - the matched
// characters. Returns the columns drawn.
draw_text :: proc(
	s: string,
	x, y: f32,
	col: rl.Color,
	max_cols := max(int),
	skip := 0,
	hl: []int = nil,
	hl_base := 0,
	hl_col := COL_MATCH,
) -> int {
	f := &g.font
	c := 0
	hi := 0
	ty := y + (f.lh - f32(f.px)) / 2
	for i := 0; i < len(s); {
		r, size := utf8.decode_rune_in_string(s[i:])
		w := 1
		if r == '\t' do w = (c / TAB_WIDTH + 1) * TAB_WIDTH - c
		vis := c - skip
		if vis >= max_cols do break

		is_hl := false
		for hi < len(hl) && hl[hi] - hl_base < i do hi += 1
		if hi < len(hl) && hl[hi] - hl_base == i do is_hl = true

		if vis >= 0 && r != ' ' && r != '\t' {
			px := x + f32(vis) * f.cw
			if r == utf8.RUNE_ERROR || r < 0x20 do r = '?'
			rl.DrawTextCodepoint(f.font, r, {px, ty}, f32(f.px), is_hl ? hl_col : col)
			if is_hl do rl.DrawRectangleRec({px, ty + f32(f.px) + 1, f.cw, max(1, f32(f.px) / 12)}, hl_col)
		}
		c += w
		i += size
	}
	return max(0, c - skip)
}

draw_label :: proc(s: string, x, y: f32, col := COL_TEXT) {
	draw_text(s, x, y, col)
}

// Text cut to fit `cols` columns, with a trailing ellipsis.
fit :: proc(s: string, cols: int) -> string {
	if cols <= 0 do return ""
	if text_cols(s) <= cols do return s
	b := strings.builder_make(context.temp_allocator)
	c := 0
	for r in s {
		if c >= cols - 1 do break
		strings.write_rune(&b, r)
		c += 1
	}
	strings.write_rune(&b, '…')
	return strings.to_string(b)
}

// Text cut from the LEFT, for paths: the end of a path is the part that says
// which file it is.
fit_left :: proc(s: string, cols: int) -> string {
	if cols <= 0 do return ""
	n := text_cols(s)
	if n <= cols do return s
	runes := utf8.string_to_runes(s, context.temp_allocator)
	keep := runes[max(0, len(runes) - (cols - 1)):]
	return strings.concatenate({"…", utf8.runes_to_string(keep, context.temp_allocator)}, context.temp_allocator)
}

text_centered :: proc(s: string, r: rl.Rectangle, col := COL_TEXT) {
	cols := int(r.width / g.font.cw)
	t := fit(s, cols)
	draw_text(t, r.x + (r.width - text_width(t)) / 2, r.y + (r.height - g.font.lh) / 2, col)
}

button :: proc(r: rl.Rectangle, label: string, on := false, enabled := true) -> bool {
	hot := enabled && hovered(r)
	bg := on ? COL_BUTTON_ON : (hot ? COL_BUTTON_HOT : COL_BUTTON)
	if !enabled do bg = COL_PANEL
	fill(r, bg)
	outline(r, on ? COL_ACCENT : COL_EDGE)
	text_centered(label, r, enabled ? (on ? COL_ACCENT : COL_TEXT) : COL_FAINT)
	return enabled && ui_take_click(r)
}

// A value with - and + either side. Returns -1, 0 or +1. The wheel over it
// steps too.
stepper :: proc(r: rl.Rectangle, shown: string, enabled := true) -> int {
	bw := r.height * 1.4
	step := 0
	if button({r.x, r.y, bw, r.height}, "-", false, enabled) do step = -1
	mid := rl.Rectangle{r.x + bw, r.y, r.width - 2 * bw, r.height}
	fill(mid, COL_GUTTER)
	outline(mid, COL_EDGE)
	text_centered(shown, mid, enabled ? COL_TEXT : COL_FAINT)
	if button({r.x + r.width - bw, r.y, bw, r.height}, "+", false, enabled) do step = 1
	if enabled {
		if w := ui_take_wheel(r); w != 0 do step = w > 0 ? 1 : -1
	}
	return step
}

with_alpha :: proc(c: rl.Color, a: u8) -> rl.Color {
	return {c.r, c.g, c.b, a}
}
