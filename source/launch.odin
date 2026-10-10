package fff

/*
    Opening files in other programs. fff itself only ever reads.

    ENTER opens the selected file in the system's default app for it, AT THE
    LINE when that app is an editor we know how to ask. There is no general
    way to tell "whatever opens .odin files" to go to line 120, so this is a
    table: find out which program the system would use, and if it is one of
    these, pass the line the way that program wants it.

        VS Code family      -g file:line           (code, codium, cursor, windsurf)
        JetBrains IDEs      --line line file
        Notepad++           -nline file
        Sublime, Zed        file:line
        gVim, Emacs, gedit  +line file
        Kate                -l line file

    Anything else opens the file without a line. `editor` in settings.txt
    overrides all of this with a command of your own.

    The platform halves are launch_windows.odin and launch_posix.odin.
*/

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

Editor_Kind :: enum u8 {
	Unknown,
	VS_Code,
	JetBrains,
	Notepad_PP,
	Colon_Line, // file:line - Sublime, Zed
	Plus_Line, // +line file - gVim, Emacs, gedit
	Kate,
}

// Which kind of editor a program is, from its file name (Windows: the exe;
// Linux: the binary, or the .desktop id).
editor_kind :: proc(program: string) -> Editor_Kind {
	name := strings.to_lower(program, context.temp_allocator)
	if i := strings.last_index_any(name, "/\\"); i >= 0 do name = name[i + 1:]
	name = strings.trim_suffix(name, ".exe")
	name = strings.trim_suffix(name, ".desktop")
	name = strings.trim_suffix(name, ".cmd")
	name = strings.trim_suffix(name, ".bat")
	// Desktop ids are often reverse-DNS ("com.visualstudio.code"): use the
	// last part, and keep the whole for the substring tests.
	last := name
	if i := strings.last_index_byte(name, '.'); i >= 0 do last = name[i + 1:]

	vs := [?]string{"code", "code - insiders", "code-insiders", "code-oss", "codium", "vscodium", "cursor", "windsurf"}
	for v in vs do if name == v || last == v do return .VS_Code
	jb := [?]string{"idea", "pycharm", "clion", "goland", "webstorm", "rider", "rustrover", "phpstorm", "rubymine", "datagrip", "studio", "jetbrains"}
	for j in jb do if strings.has_prefix(last, j) || strings.contains(name, "jetbrains") do return .JetBrains
	switch {
	case strings.contains(name, "notepad++"):
		return .Notepad_PP
	case strings.has_prefix(last, "sublime") || last == "subl" || last == "zed":
		return .Colon_Line
	case last == "gvim" || last == "emacs" || last == "runemacs" || last == "gedit" || last == "emacsclient":
		return .Plus_Line
	case last == "kate" || last == "kwrite":
		return .Kate
	}
	return .Unknown
}

// The arguments that open `file` (already quoted) at `line`.
editor_args :: proc(kind: Editor_Kind, file: string, line: int) -> string {
	switch kind {
	case .VS_Code:
		return fmt.tprintf("-g %s:%v", file, line)
	case .JetBrains:
		return fmt.tprintf("--line %v %s", line, file)
	case .Notepad_PP:
		return fmt.tprintf("-n%v %s", line, file)
	case .Colon_Line:
		return fmt.tprintf("%s:%v", file, line)
	case .Plus_Line:
		return fmt.tprintf("+%v %s", line, file)
	case .Kate:
		return fmt.tprintf("-l %v %s", line, file)
	case .Unknown:
	}
	return file
}

// Fill in a command template. {file} is quoted for the shell unless the
// template already has it inside quotes; without a {file}, the path goes on
// the end.
expand_template :: proc(tmpl: string, path: string, line: int) -> string {
	quoted := quote_arg(path)
	out := tmpl
	if strings.contains(out, "\"{file}") || strings.contains(out, "'{file}") {
		out, _ = strings.replace_all(out, "{file}", path, context.temp_allocator)
	} else if strings.contains(out, "{file}") {
		out, _ = strings.replace_all(out, "{file}", quoted, context.temp_allocator)
	} else {
		out = fmt.tprintf("%s %s", out, quoted)
	}
	out, _ = strings.replace_all(out, "{line}", fmt.tprint(line), context.temp_allocator)
	return out
}

// ---------------------------------------------------------------------------
// Launching, off the main thread
// ---------------------------------------------------------------------------
//
// Starting another program can take a while - ShellExecute talking to a
// shell extension, a command given time to fail (launch_windows.odin), the
// xdg-mime lookups on Linux - so each launch runs on a thread of its own,
// which reports back through post_status and ends.

Launch_Kind :: enum u8 {
	At_Line, // Enter: the default app, at the line for known editors
	Default, // "Open In System Default"
	With_Dialog, // "Open In..." on Windows
	Template, // a command: the `editor` setting, or "Open In..." on Linux
}

@(private = "file")
Launch :: struct {
	kind:     Launch_Kind,
	path:     string, // owned, like everything here
	rel:      string,
	template: string,
	line:     int,
}

launch_async :: proc(kind: Launch_Kind, path: string, line: int, rel: string, template := "") {
	l := new(Launch)
	l^ = {
		kind     = kind,
		path     = strings.clone(path),
		rel      = strings.clone(rel),
		template = strings.clone(template),
		line     = line,
	}
	sync.atomic_add(&g.launches, 1)
	thread.create_and_start_with_poly_data(l, launch_thread, self_cleanup = true)
}

@(private = "file")
launch_thread :: proc(l: ^Launch) {
	defer {
		delete(l.path)
		delete(l.rel)
		delete(l.template)
		free(l)
		sync.atomic_sub(&g.launches, 1)
		free_all(context.temp_allocator)
	}
	platform_init() // per thread: Windows wants COM on whichever thread calls ShellExecute
	switch l.kind {
	case .At_Line:
		if platform_open_at_line(l.path, l.line) do post_status(false, "opened %s:%v", l.rel, l.line)
		else do post_status(true, "could not open %s", l.rel)
	case .Default:
		if platform_open_default(l.path) do post_status(false, "opened %s", l.rel)
		else do post_status(true, "could not open %s", l.rel)
	case .With_Dialog:
		if !platform_open_with_dialog(l.path) do post_status(true, "could not show the Open With dialog")
	case .Template:
		if run_template(l.template, l.path, l.line) do post_status(false, "opened %s:%v", l.rel, l.line)
		else do post_status(true, "could not run: %s", l.template)
	}
}

// Enter.
open_at_line :: proc(path: string, line: int, rel: string) {
	if g.settings.editor != "" {
		launch_async(.Template, path, line, rel, g.settings.editor)
	} else {
		launch_async(.At_Line, path, line, rel)
	}
	set_status("opening %s...", rel)
}

// "Open In System Default": the default app, no line.
open_default :: proc(path: string, rel: string) {
	launch_async(.Default, path, 1, rel)
	set_status("opening %s...", rel)
}

// "Open In...": the system's chooser on Windows, a typed command on Linux.
open_in :: proc(path: string, line: int, rel: string) {
	when ODIN_OS == .Windows {
		launch_async(.With_Dialog, path, line, rel)
	} else {
		prompt_open(path, line, rel)
	}
}
