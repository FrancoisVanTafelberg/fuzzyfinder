package fff

/*
    Settings, in SJSON - the same hand-editable format Animal Kingdoms and the
    Music Box use.

    WHERE: fff is run from whatever folder you want to search, so the settings
    cannot live next to the working directory (every project would grow a
    settings.txt) or next to the exe (Program Files is read-only). They live in
    the user's config folder:

        Windows   %APPDATA%\fff\settings.txt
        Linux     $XDG_CONFIG_HOME/fff/settings.txt  (~/.config/fff/...)

    The global ignore list is in here too: "Exclude ... from all searches"
    writes it straight away, so a crash cannot lose it. Everything else is
    written when the Esc menu closes and when fff exits.
*/

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "ignore"
import rl "vendor:raylib"

SETTINGS_FILE :: "settings.txt"

Settings :: struct {
	display_mode:     Display_Mode,
	window_w:         i32,
	window_h:         i32,
	window_x:         i32,
	window_y:         i32,
	font_size:        i32,
	results:          i32, // how many result rows
	max_fps:          i32,
	max_file_kb:      i32,
	show_metrics:     bool, // the performance panel (F3)
	// What Enter runs. "" asks the system for the file's default app and, if
	// that is an editor fff knows, passes it the line. Otherwise a command
	// with {file} and {line} in it, e.g. "code -g {file}:{line}".
	editor:           string, // owned
	// "Open In..." on Linux types a command; the last few are offered again.
	open_with_recent: [dynamic]string, // owned
	// "...from all searches".
	global:           ignore.Rules,
}

FONT_MIN :: 10
FONT_MAX :: 48
RESULTS_MIN :: 3
RESULTS_MAX :: 50
OPEN_WITH_RECENT_MAX :: 6

settings_defaults :: proc() -> (s: Settings) {
	s = Settings {
		display_mode = .Windowed,
		window_w     = 1600,
		window_h     = 900,
		window_x     = WINDOW_UNPLACED,
		window_y     = WINDOW_UNPLACED,
		font_size    = 18,
		results      = 10,
		max_fps      = 60,
		max_file_kb  = 4096,
		show_metrics = true,
	}
	// Version control internals: never what anyone is looking for, and a
	// .git folder can hold more bytes than the tree it sits in. Shown in the
	// panel like any other entry, so it can be removed.
	ignore.add_folder(&s.global, ".git")
	ignore.add_folder(&s.global, "node_modules")
	return
}

settings_destroy :: proc(s: ^Settings) {
	delete(s.editor)
	for r in s.open_with_recent do delete(r)
	delete(s.open_with_recent)
	ignore.destroy(&s.global)
}

settings_path :: proc(allocator := context.allocator) -> string {
	// Roaming on Windows: %APPDATA%, where per-user settings belong.
	dir, err := os.user_config_dir(context.temp_allocator, roaming = true)
	if err != nil || dir == "" do return strings.clone(SETTINGS_FILE, allocator)
	sep := ODIN_OS == .Windows ? "\\" : "/"
	return strings.concatenate({dir, sep, "fff", sep, SETTINGS_FILE}, allocator)
}

settings_load :: proc(s: ^Settings, path: string) -> (first_run: bool) {
	s^ = settings_defaults()
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil do return true

	p := json.make_parser_from_string(string(data), .SJSON, true, context.temp_allocator)
	obj, perr := json.parse_object_body(&p, .EOF)
	if perr != nil {
		fmt.eprintfln("fff: %s is malformed (%v); using defaults", path, perr)
		return
	}

	get_int :: proc(o: json.Object, key: string, out: ^i32) {
		if v, ok := o[key]; ok {
			#partial switch n in v {
			case json.Integer:
				out^ = i32(n)
			case json.Float:
				out^ = i32(n)
			}
		}
	}
	get_str :: proc(o: json.Object, key: string) -> (string, bool) {
		if v, ok := o[key]; ok {
			if str, is := v.(json.String); is do return string(str), true
		}
		return "", false
	}
	get_list :: proc(o: json.Object, key: string) -> (json.Array, bool) {
		if v, ok := o[key]; ok {
			if arr, is := v.(json.Array); is do return arr, true
		}
		return nil, false
	}

	if name, ok := get_str(obj, "display_mode"); ok {
		if m, known := display_mode_from_string(name); known do s.display_mode = m
	}
	get_int(obj, "window_w", &s.window_w)
	get_int(obj, "window_h", &s.window_h)
	get_int(obj, "window_x", &s.window_x)
	get_int(obj, "window_y", &s.window_y)
	get_int(obj, "font_size", &s.font_size)
	get_int(obj, "results", &s.results)
	get_int(obj, "max_fps", &s.max_fps)
	get_int(obj, "max_file_kb", &s.max_file_kb)
	if ed, ok := get_str(obj, "editor"); ok do s.editor = strings.clone(ed)
	if v, ok := obj["show_metrics"]; ok {
		if b, is := v.(json.Boolean); is do s.show_metrics = bool(b)
	}

	if arr, ok := get_list(obj, "open_with_recent"); ok {
		for e in arr do if str, is := e.(json.String); is && len(str) > 0 && len(s.open_with_recent) < OPEN_WITH_RECENT_MAX {
			append(&s.open_with_recent, strings.clone(string(str)))
		}
	}
	// A list in the file REPLACES the default, so a removed .git/ stays
	// removed.
	if arr, ok := get_list(obj, "ignore_folders"); ok {
		for f in s.global.folders do delete(f)
		clear(&s.global.folders)
		for e in arr do if str, is := e.(json.String); is do ignore.add_folder(&s.global, string(str))
	}
	if arr, ok := get_list(obj, "ignore_types"); ok {
		for t in s.global.types do delete(t)
		clear(&s.global.types)
		for e in arr do if str, is := e.(json.String); is do ignore.add_type(&s.global, string(str))
	}

	s.window_w = max(s.window_w, WINDOW_MIN_W)
	s.window_h = max(s.window_h, WINDOW_MIN_H)
	s.font_size = clamp(s.font_size, FONT_MIN, FONT_MAX)
	s.results = clamp(s.results, RESULTS_MIN, RESULTS_MAX)
	s.max_fps = clamp(s.max_fps, 0, 1000)
	s.max_file_kb = clamp(s.max_file_kb, 16, 1024 * 1024)
	return
}

settings_save :: proc(s: ^Settings, path: string) {
	b := strings.builder_make(context.temp_allocator)
	w :: proc(b: ^strings.Builder, key: string, value: string) {
		fmt.sbprintf(b, "%-17s= %s\n", key, value)
	}
	q :: proc(v: string) -> string {
		// SJSON strings: escape the two characters that would end them.
		out := strings.builder_make(context.temp_allocator)
		strings.write_byte(&out, '"')
		for c in transmute([]u8)v {
			if c == '"' || c == '\\' do strings.write_byte(&out, '\\')
			strings.write_byte(&out, c)
		}
		strings.write_byte(&out, '"')
		return strings.to_string(out)
	}
	list :: proc(items: []string) -> string {
		out := strings.builder_make(context.temp_allocator)
		strings.write_string(&out, "[")
		for it, i in items {
			if i > 0 do strings.write_string(&out, ", ")
			strings.write_string(&out, q(it))
		}
		strings.write_string(&out, "]")
		return strings.to_string(out)
	}

	fmt.sbprintln(&b, "// fff (Fast Fuzzy Finder) settings. Safe to edit by hand.")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// window")
	ids := DISPLAY_MODE_ID
	w(&b, "display_mode", q(ids[s.display_mode]))
	w(&b, "window_w", fmt.tprint(s.window_w))
	w(&b, "window_h", fmt.tprint(s.window_h))
	w(&b, "window_x", fmt.tprint(s.window_x))
	w(&b, "window_y", fmt.tprint(s.window_y))
	w(&b, "max_fps", fmt.tprint(s.max_fps))
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// view")
	w(&b, "font_size", fmt.tprint(s.font_size))
	w(&b, "results", fmt.tprint(s.results))
	w(&b, "show_metrics", s.show_metrics ? "true" : "false")
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// search - files larger than this (in KB) are listed but not read")
	w(&b, "max_file_kb", fmt.tprint(s.max_file_kb))
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// what Enter opens the file with. \"\" = the system's default app for the file;")
	fmt.sbprintln(&b, "// otherwise a command, where {file} and {line} are filled in, e.g.")
	fmt.sbprintln(&b, "//   editor = \"code -g {file}:{line}\"")
	w(&b, "editor", q(s.editor))
	w(&b, "open_with_recent", list(s.open_with_recent[:]))
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "// ignored in every search. Folders: \"name/\" matches a folder of that")
	fmt.sbprintln(&b, "// name anywhere (* and ? allowed). Types: extensions, without the dot.")
	w(&b, "ignore_folders", list(s.global.folders[:]))
	w(&b, "ignore_types", list(s.global.types[:]))

	dir, _ := os.split_path(path)
	if dir != "" do os.make_directory_all(dir)
	if err := os.write_entire_file(path, transmute([]u8)strings.to_string(b)); err != nil {
		fmt.eprintfln("fff: could not write %s: %v", path, err)
	}
}

// The live window, read back into the settings so the next run opens where
// this one ended. Every frame, and only while windowed (the size of a
// borderless window is the monitor's, which is not a choice to remember).
settings_capture_window :: proc(s: ^Settings) {
	if current_mode() != .Windowed do return
	s.window_w = rl.GetScreenWidth()
	s.window_h = rl.GetScreenHeight()
	at := window_spot_now()
	s.window_x, s.window_y = at.x, at.y
}

remember_open_with :: proc(s: ^Settings, cmd: string) {
	for r, i in s.open_with_recent do if r == cmd {
		delete(r)
		ordered_remove(&s.open_with_recent, i)
		break
	}
	inject_at(&s.open_with_recent, 0, strings.clone(cmd))
	for len(s.open_with_recent) > OPEN_WITH_RECENT_MAX {
		delete(pop(&s.open_with_recent))
	}
}
