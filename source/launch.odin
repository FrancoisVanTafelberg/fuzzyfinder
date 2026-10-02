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

// Enter.
open_at_line :: proc(path: string, line: int, rel: string) {
	if g.settings.editor != "" {
		if run_template(g.settings.editor, path, line) {
			set_status("opened %s:%v", rel, line)
		} else {
			set_error("could not run the editor command in settings.txt")
		}
		return
	}
	if platform_open_at_line(path, line) do set_status("opened %s:%v", rel, line)
	else do set_error("could not open %s", rel)
}

// "Open In System Default": the default app, no line.
open_default :: proc(path: string, rel: string) {
	if platform_open_default(path) do set_status("opened %s", rel)
	else do set_error("could not open %s", rel)
}

// "Open In...": the system's chooser on Windows, a typed command on Linux.
open_in :: proc(path: string, line: int, rel: string) {
	when ODIN_OS == .Windows {
		if !platform_open_with_dialog(path) do set_error("could not show the Open With dialog")
	} else {
		prompt_open(path, line, rel)
	}
}
