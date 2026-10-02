package fff

/*
    The keyboard, on the main screen.

    TWO FOCUSES, because the search line is always there and the viewer is
    scrolled with letters. Tab moves between them and the focused one has an
    amber outline:

        search focused    letters type into the query
        viewer focused    W / S one line up / down, E / D half a page,
                          Home / End the top / bottom of the file,
                          A / F scroll sideways

    Whatever has focus, these always work:

        Up / Down             move through the results (the viewer follows)
        PageUp / PageDown     the viewer, half a page
        Enter                 open the selected file at its line
        Alt+C / Alt+F         content mode / files mode
        Esc                   the menu
*/

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

key_hit :: proc(k: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)
}

ctrl_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
}

alt_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)
}

shift_down :: proc() -> bool {
	return rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
}

main_keys :: proc() {
	if rl.IsKeyPressed(.TAB) {
		g.focus = g.focus == .Search ? .Viewer : .Search
	}

	if alt_down() {
		if rl.IsKeyPressed(.C) do set_mode_search(.Content)
		if rl.IsKeyPressed(.F) do set_mode_search(.Files)
		return // Alt+letter is a command, never typing
	}

	n := g.search.top.n
	if key_hit(.UP) && n > 0 do g.sel = max(0, g.sel - 1)
	if key_hit(.DOWN) && n > 0 do g.sel = min(n - 1, g.sel + 1)
	half := max(1, viewer_rows() / 2)
	if key_hit(.PAGE_UP) do viewer_scroll(-half)
	if key_hit(.PAGE_DOWN) do viewer_scroll(half)
	if rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) do open_selected()

	switch g.focus {
	case .Viewer:
		if ctrl_down() do break
		if key_hit(.W) do viewer_scroll(-1)
		if key_hit(.S) do viewer_scroll(1)
		if key_hit(.E) do viewer_scroll(-half)
		if key_hit(.D) do viewer_scroll(half)
		if key_hit(.A) do g.view.left = max(0, g.view.left - 4)
		if key_hit(.F) do g.view.left += 4
		if rl.IsKeyPressed(.HOME) do viewer_scroll(-viewer_lines())
		if rl.IsKeyPressed(.END) do viewer_scroll(viewer_lines())
	case .Search:
		if edit_line(&g.query, &g.cursor) do g.sel = 0
	}
}

set_mode_search :: proc(m: Mode) {
	if g.mode == m do return
	g.mode = m
	g.sel = 0
	set_status("%s mode", MODE_NAME[m])
}

// One line of text being typed: the query, or the Open In command.
// Returns true if the text changed.
edit_line :: proc(buf: ^[dynamic]u8, cursor: ^int) -> bool {
	changed := false
	cursor^ = clamp(cursor^, 0, len(buf))
	ctrl := ctrl_down()

	if ctrl {
		if rl.IsKeyPressed(.V) {
			clip := string(rl.GetClipboardText())
			// One line only: a pasted newline would be a search for nothing.
			if i := strings.index_any(clip, "\r\n"); i >= 0 do clip = clip[:i]
			inject_at(buf, cursor^, ..transmute([]u8)clip)
			cursor^ += len(clip)
			changed = len(clip) > 0
		}
		if rl.IsKeyPressed(.U) && len(buf) > 0 {
			clear(buf)
			cursor^ = 0
			changed = true
		}
		if key_hit(.BACKSPACE) && cursor^ > 0 {
			// Back over any spaces, then over the word.
			to := cursor^
			for to > 0 && buf[to - 1] == ' ' do to -= 1
			for to > 0 && buf[to - 1] != ' ' do to -= 1
			remove_range(buf, to, cursor^)
			cursor^ = to
			changed = true
		}
		if key_hit(.LEFT) do cursor^ = word_left(buf[:], cursor^)
		if key_hit(.RIGHT) do cursor^ = word_right(buf[:], cursor^)
		return changed
	}

	for {
		r := rl.GetCharPressed()
		if r == 0 do break
		if r < 0x20 || r == 0x7F do continue
		enc, n := utf8.encode_rune(r)
		inject_at(buf, cursor^, ..enc[:n])
		cursor^ += n
		changed = true
	}
	if key_hit(.BACKSPACE) && cursor^ > 0 {
		_, size := utf8.decode_last_rune(buf[:cursor^])
		remove_range(buf, cursor^ - size, cursor^)
		cursor^ -= size
		changed = true
	}
	if key_hit(.DELETE) && cursor^ < len(buf) {
		_, size := utf8.decode_rune(buf[cursor^:])
		remove_range(buf, cursor^, cursor^ + size)
		changed = true
	}
	if key_hit(.LEFT) && cursor^ > 0 {
		_, size := utf8.decode_last_rune(buf[:cursor^])
		cursor^ -= size
	}
	if key_hit(.RIGHT) && cursor^ < len(buf) {
		_, size := utf8.decode_rune(buf[cursor^:])
		cursor^ += size
	}
	if rl.IsKeyPressed(.HOME) do cursor^ = 0
	if rl.IsKeyPressed(.END) do cursor^ = len(buf)
	return changed
}

@(private = "file")
word_left :: proc(b: []u8, at: int) -> int {
	i := at
	for i > 0 && b[i - 1] == ' ' do i -= 1
	for i > 0 && b[i - 1] != ' ' do i -= 1
	return i
}

@(private = "file")
word_right :: proc(b: []u8, at: int) -> int {
	i := at
	for i < len(b) && b[i] == ' ' do i += 1
	for i < len(b) && b[i] != ' ' do i += 1
	return i
}

// The selected result's file, and its line (1-based; 1 in files mode).
selected_target :: proc() -> (file: int, line: int, ok: bool) {
	if g.search.top.n == 0 do return -1, 0, false
	item := g.search.top.items[clamp(g.sel, 0, g.search.top.n - 1)].item
	switch g.search.mode {
	case .Files:
		return int(item), 1, true
	case .Content:
		ref := g.idx.lines[item]
		return int(ref.file), int(ref.line) + 1, true
	}
	return -1, 0, false
}

open_selected :: proc() {
	file, line, ok := selected_target()
	if !ok do return
	f := &g.idx.files[file]
	open_at_line(abs_path(f), line, f.rel)
}
