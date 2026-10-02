#+build !windows
package fff

/*
    Opening files on Linux (and other Unix-likes).

    "The default app" is what xdg-mime says handles the file's type. Its
    .desktop file says how to start it (the Exec= line), and editor_kind
    decides whether we can add a line number. Anything we cannot do better
    than, xdg-open does.

    Everything is started through `sh -c '... &'`, so the program is fully
    detached: fff does not wait for it, and it outlives fff.
*/

import "core:os"
import "core:strings"

platform_init :: proc() {}

quote_arg :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '\'')
	for c in transmute([]u8)s {
		if c == '\'' do strings.write_string(&b, "'\\''")
		else do strings.write_byte(&b, c)
	}
	strings.write_byte(&b, '\'')
	return strings.to_string(b)
}

// Start a shell command in the background. The shell itself exits at once -
// after checking the program exists, so a missing one is reported rather than
// failing silently in the background.
run_command :: proc(cmdline: string) -> bool {
	program := strings.trim_space(cmdline)
	if i := strings.index_any(program, " \t"); i >= 0 do program = program[:i]
	program = strings.trim(program, "'\"")
	full := strings.concatenate(
		{"command -v ", quote_arg(program), " >/dev/null 2>&1 || exit 127; (", cmdline, ") >/dev/null 2>&1 &"},
		context.temp_allocator,
	)
	p, err := os.process_start({command = {"/bin/sh", "-c", full}})
	if err != nil do return false
	state, werr := os.process_wait(p)
	return werr == nil && state.exit_code == 0
}

run_template :: proc(tmpl: string, path: string, line: int) -> bool {
	return run_command(expand_template(tmpl, path, line))
}

// One line of output from a short command, or "".
@(private = "file")
ask :: proc(cmd: ..string) -> string {
	state, out, _, err := os.process_exec({command = cmd}, context.temp_allocator)
	if err != nil || state.exit_code != 0 do return ""
	return strings.trim_space(string(out))
}

// The Exec= line of a .desktop file, with its %f/%F/%u/%U field codes
// removed: what is left starts the program, and the arguments go after it.
@(private = "file")
desktop_exec :: proc(id: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	data_home := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data_home == "" do data_home = strings.concatenate({home, "/.local/share"}, context.temp_allocator)
	data_dirs := os.get_env("XDG_DATA_DIRS", context.temp_allocator)
	if data_dirs == "" do data_dirs = "/usr/local/share:/usr/share"
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, data_home)
	for d in strings.split_iterator(&data_dirs, ":") do append(&dirs, d)
	append(&dirs, "/var/lib/flatpak/exports/share")
	append(&dirs, strings.concatenate({home, "/.local/share/flatpak/exports/share"}, context.temp_allocator))

	for d in dirs {
		p := strings.concatenate({d, "/applications/", id}, context.temp_allocator)
		data, err := os.read_entire_file_from_path(p, context.temp_allocator)
		if err != nil do continue
		text := string(data)
		in_entry := false
		for l in strings.split_lines_iterator(&text) {
			line := strings.trim_space(l)
			if strings.has_prefix(line, "[") do in_entry = line == "[Desktop Entry]"
			if !in_entry || !strings.has_prefix(line, "Exec=") do continue
			exec := line[len("Exec="):]
			b := strings.builder_make(context.temp_allocator)
			for i := 0; i < len(exec); i += 1 {
				if exec[i] == '%' && i + 1 < len(exec) {
					i += 1
					if exec[i] == '%' do strings.write_byte(&b, '%')
					continue
				}
				strings.write_byte(&b, exec[i])
			}
			return strings.trim_space(strings.to_string(b))
		}
	}
	return ""
}

platform_open_at_line :: proc(path: string, line: int) -> bool {
	mime := ask("xdg-mime", "query", "filetype", path)
	id := mime != "" ? ask("xdg-mime", "query", "default", mime) : ""
	// Source code often has a type nobody has registered an app for, but
	// it is text; the text editor is the right answer.
	if id == "" && (mime == "" || strings.has_prefix(mime, "text/") || strings.has_prefix(mime, "application/x-")) {
		id = ask("xdg-mime", "query", "default", "text/plain")
	}
	if id != "" {
		exec := desktop_exec(id)
		program := exec
		if i := strings.index_byte(exec, ' '); i >= 0 do program = exec[:i]
		kind := editor_kind(program)
		if kind == .Unknown do kind = editor_kind(id)
		if exec != "" && kind != .Unknown {
			return run_command(strings.concatenate({exec, " ", editor_args(kind, quote_arg(path), line)}, context.temp_allocator))
		}
	}
	return platform_open_default(path)
}

platform_open_default :: proc(path: string) -> bool {
	return run_command(strings.concatenate({"xdg-open ", quote_arg(path)}, context.temp_allocator))
}

platform_open_with_dialog :: proc(path: string) -> bool {
	return false // Linux uses the typed prompt instead; see open_in.
}
