package fff

/*
    Display modes, and the window sizes the Esc menu offers.

    Lifted from the Music Box's rlu/display.odin (itself from Animal Kingdoms),
    with the virtual canvas taken out: fff has none. Everything is laid out
    against the window's real size every frame, so a bigger window shows more
    lines rather than bigger pixels, and "resolution" here simply means the
    size of the window.

    The rules kept from there:
      - the resolution is a WINDOWED setting; borderless and fullscreen take the
        monitor, and the menu dims the size while in them;
      - only sizes that fit the monitor are offered;
      - a remembered window position is checked against the monitors that
        exist now, so an unplugged screen cannot strand the window;
      - a new size in windowed mode is centred (Bob, 28 September, Animal
        Kingdoms: the title bar must never end up off screen).
*/

import rl "vendor:raylib"

Display_Mode :: enum {
	Windowed,
	Borderless,
	Fullscreen,
}

DISPLAY_MODE_ID := [Display_Mode]string {
	.Windowed   = "windowed",
	.Borderless = "borderless",
	.Fullscreen = "fullscreen",
}

DISPLAY_MODE_LABEL := [Display_Mode]string {
	.Windowed   = "Windowed",
	.Borderless = "Borderless",
	.Fullscreen = "Fullscreen",
}

display_mode_from_string :: proc(s: string) -> (Display_Mode, bool) {
	for name, m in DISPLAY_MODE_ID do if name == s do return m, true
	return .Windowed, false
}

// Small enough for a corner of a laptop screen, big enough that the four
// panes still have room to be useful.
WINDOW_MIN_W :: 640
WINDOW_MIN_H :: 400

Resolution :: struct {
	w, h: i32,
	note: string,
}

// Sorted by area, smallest first: the stepper walks it in order.
RESOLUTIONS := [?]Resolution {
	{800, 600, ""},
	{1024, 640, ""},
	{1024, 768, ""},
	{1280, 720, ""},
	{1280, 800, ""},
	{1366, 768, "common laptop"},
	{1440, 900, ""},
	{1600, 900, ""},
	{1680, 1050, ""},
	{1920, 1080, ""},
	{1920, 1200, ""},
	{2560, 1080, "ultrawide"},
	{2560, 1440, ""},
	{2560, 1600, ""},
	{3440, 1440, "ultrawide"},
	{3840, 2160, "4K"},
}

// The resolutions that fit a monitor this size. Never empty.
resolutions_for :: proc(mw, mh: i32, out: []Resolution) -> int {
	n := 0
	for r in RESOLUTIONS {
		if r.w > mw || r.h > mh do continue
		if n >= len(out) do break
		out[n] = r
		n += 1
	}
	if n == 0 && len(out) > 0 {
		out[0] = RESOLUTIONS[0]
		n = 1
	}
	return n
}

largest_fitting :: proc(w, h: i32) -> Resolution {
	best := RESOLUTIONS[0]
	for r in RESOLUTIONS do if r.w <= w && r.h <= h do best = r
	return best
}

// The entry nearest to w x h - nearest, because the window may have been
// dragged to a size that is not in the list.
resolution_index :: proc(list: []Resolution, w, h: i32) -> int {
	best, best_d := 0, max(int)
	for r, i in list {
		d := abs(int(r.w) - int(w)) + abs(int(r.h) - int(h))
		if d < best_d {
			best_d = d
			best = i
		}
	}
	return best
}

Monitor :: struct {
	x, y, w, h: i32,
}

WINDOW_UNPLACED :: i32(-1)
MAX_MONITORS :: 16

monitors_now :: proc(out: []Monitor) -> int {
	n := 0
	for i in 0 ..< int(rl.GetMonitorCount()) {
		if n >= len(out) do break
		p := rl.GetMonitorPosition(i32(i))
		out[n] = {i32(p.x), i32(p.y), rl.GetMonitorWidth(i32(i)), rl.GetMonitorHeight(i32(i))}
		n += 1
	}
	return n
}

// Where to put a w x h window given where it was last time: the saved spot if
// its centre is on a monitor that exists now (nudged fully onto it), else
// centred on the primary. Never further up or left than a monitor's corner -
// a window that does not fit should lose its bottom right, not its title bar.
window_spot :: proc(saved: [2]i32, w, h: i32, monitors: []Monitor) -> [2]i32 {
	if len(monitors) == 0 do return saved
	primary := monitors[0]
	centred := [2]i32 {
		max(primary.x, primary.x + (primary.w - w) / 2),
		max(primary.y, primary.y + (primary.h - h) / 2),
	}
	if saved.x == WINDOW_UNPLACED && saved.y == WINDOW_UNPLACED do return centred
	cx, cy := saved.x + w / 2, saved.y + h / 2
	for m in monitors {
		if cx < m.x || cx >= m.x + m.w do continue
		if cy < m.y || cy >= m.y + m.h do continue
		return {max(m.x, min(saved.x, m.x + m.w - w)), max(m.y, min(saved.y, m.y + m.h - h))}
	}
	return centred
}

current_mode :: proc() -> Display_Mode {
	if rl.IsWindowFullscreen() do return .Fullscreen
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) do return .Borderless
	return .Windowed
}

// Put the window into `mode`; `w` x `h` and `at` only matter for Windowed.
set_mode :: proc(mode: Display_Mode, w, h: i32, at := [2]i32{WINDOW_UNPLACED, WINDOW_UNPLACED}) {
	// Both of raylib's switches are toggles: leave whatever we are in first.
	now := current_mode()
	if now == .Fullscreen do rl.ToggleFullscreen()
	else if now == .Borderless do rl.ToggleBorderlessWindowed()

	switch mode {
	case .Windowed:
		set_window_size(w, h, at)
	case .Borderless:
		rl.ToggleBorderlessWindowed()
		// Without a window manager the toggle's resize does not always stick.
		m := rl.GetCurrentMonitor()
		mw, mh := rl.GetMonitorWidth(m), rl.GetMonitorHeight(m)
		if mw > 0 && mh > 0 && (rl.GetScreenWidth() != mw || rl.GetScreenHeight() != mh) {
			rl.SetWindowSize(mw, mh)
			p := rl.GetMonitorPosition(m)
			rl.SetWindowPosition(i32(p.x), i32(p.y))
		}
	case .Fullscreen:
		m := rl.GetCurrentMonitor()
		rl.SetWindowSize(rl.GetMonitorWidth(m), rl.GetMonitorHeight(m))
		rl.ToggleFullscreen()
	}
}

set_window_size :: proc(w, h: i32, at := [2]i32{WINDOW_UNPLACED, WINDOW_UNPLACED}) {
	rl.SetWindowSize(w, h)
	mons: [MAX_MONITORS]Monitor
	n := monitors_now(mons[:])
	p := window_spot(at, w, h, mons[:n])
	if n > 0 do rl.SetWindowPosition(p.x, p.y)
}

window_spot_now :: proc() -> [2]i32 {
	if current_mode() != .Windowed do return {WINDOW_UNPLACED, WINDOW_UNPLACED}
	p := rl.GetWindowPosition()
	return {i32(p.x), i32(p.y)}
}

// Open the window as the settings ask: the size is stepped down to fit the
// monitor (to 90% of it on first run, so it does not open under the taskbar).
window_open :: proc(s: ^Settings, title: cstring, first_run: bool) {
	// raylib reports every glyph the face lacks; only real errors matter.
	rl.SetTraceLogLevel(.ERROR)
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .VSYNC_HINT})
	w := max(s.window_w, WINDOW_MIN_W)
	h := max(s.window_h, WINDOW_MIN_H)
	rl.InitWindow(w, h, title)
	rl.SetWindowMinSize(WINDOW_MIN_W, WINDOW_MIN_H)
	// Esc opens the menu; it must not close the window.
	rl.SetExitKey(.KEY_NULL)

	m := rl.GetCurrentMonitor()
	mw, mh := rl.GetMonitorWidth(m), rl.GetMonitorHeight(m)
	room_w := first_run ? mw * 9 / 10 : mw
	room_h := first_run ? mh * 9 / 10 : mh
	if mw > 0 && mh > 0 && (w > room_w || h > room_h) {
		r := largest_fitting(room_w, room_h)
		w, h = r.w, r.h
	}
	at := [2]i32{s.window_x, s.window_y}
	if first_run do at = {WINDOW_UNPLACED, WINDOW_UNPLACED}
	set_mode(s.display_mode, w, h, at)
}

// Push the display settings to the window, if they differ from it. A new
// windowed size is centred; a change of mode keeps the remembered corner.
display_apply :: proc(s: ^Settings) {
	now := current_mode()
	size := [2]i32{rl.GetScreenWidth(), rl.GetScreenHeight()}
	resized := s.display_mode == .Windowed && now == .Windowed && (size.x != s.window_w || size.y != s.window_h)
	if s.display_mode == now && !resized do return
	at := [2]i32{s.window_x, s.window_y}
	if resized do at = {WINDOW_UNPLACED, WINDOW_UNPLACED}
	set_mode(s.display_mode, s.window_w, s.window_h, at)
}
