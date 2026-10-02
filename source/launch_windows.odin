#+build windows
package fff

/*
    Opening files on Windows.

    Programs are started with ShellExecute, which finds an exe the way the
    Run box does and never flashes a console. Commands (the `editor` setting,
    and .cmd launchers such as VS Code's `code`) go through cmd.exe started
    with CREATE_NO_WINDOW, which is the only way to run a .cmd without a
    console window appearing for a moment.

    cmd.exe and rundll32.exe are always named BY FULL PATH, from the system
    folder. fff's working directory is the folder being searched, and Windows
    looks in the working directory for a bare "cmd.exe" - a repository with a
    file of that name in it must not get it run.
*/

import "core:os"
import "core:strings"
import win "core:sys/windows"

quote_arg :: proc(s: string) -> string {
	return strings.concatenate({"\"", s, "\""}, context.temp_allocator)
}

@(private = "file")
W :: proc(s: string) -> win.wstring {
	return win.utf8_to_wstring(s, context.temp_allocator)
}

// ShellExecute may hand the work to shell extensions, which expect COM.
platform_init :: proc() {
	win.CoInitializeEx(nil, win.COINIT(0x2 | 0x4)) // APARTMENTTHREADED | DISABLE_OLE1DDE
}

@(private = "file")
system_exe :: proc(name: string) -> string {
	buf: [win.MAX_PATH]u16
	n := win.GetSystemDirectoryW(raw_data(buf[:]), u32(len(buf)))
	if n == 0 || int(n) >= len(buf) do return name
	dir, err := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), int(n), context.temp_allocator)
	if err != nil do return name
	return strings.concatenate({dir, "\\", name}, context.temp_allocator)
}

@(private = "file")
shell_open :: proc(file: string, params: string = "", verb := "open") -> bool {
	p: win.wstring = nil
	if params != "" do p = W(params)
	h := win.ShellExecuteW(nil, W(verb), W(file), p, nil, win.SW_SHOWNORMAL)
	return uintptr(h) > 32
}

// Run a command line through cmd.exe, without a console window.
//
// Waits a moment for cmd to finish: launchers like code.cmd hand over and
// exit at once, so a non-zero exit in that time ("not recognized as a
// command" is 9009) is a failure worth reporting. A command still running
// after the wait - a program cmd is waiting on - is taken as started.
run_command :: proc(cmdline: string) -> bool {
	cmd := system_exe("cmd.exe")
	full := strings.concatenate({quote_arg(cmd), " /d /s /c \"", cmdline, "\""}, context.temp_allocator)
	si := win.STARTUPINFOW {
		cb = size_of(win.STARTUPINFOW),
	}
	pi: win.PROCESS_INFORMATION
	buf := W(full) // CreateProcessW may write into its command line
	if !win.CreateProcessW(W(cmd), buf, nil, nil, false, win.CREATE_NO_WINDOW, nil, nil, &si, &pi) do return false
	defer win.CloseHandle(pi.hProcess)
	win.CloseHandle(pi.hThread)
	if win.WaitForSingleObject(pi.hProcess, 600) == win.WAIT_OBJECT_0 {
		code: win.DWORD
		if win.GetExitCodeProcess(pi.hProcess, &code) && code != 0 do return false
	}
	return true
}

run_template :: proc(tmpl: string, path: string, line: int) -> bool {
	return run_command(expand_template(tmpl, path, line))
}

// The program the system would open files with this extension in, or "".
@(private = "file")
assoc_exe :: proc(path: string) -> string {
	dot := strings.last_index_byte(path, '.')
	slash := strings.last_index_any(path, "\\/")
	if dot <= slash + 1 do return ""
	ext := path[dot:]
	buf: [win.MAX_PATH * 2]u16
	n := win.DWORD(len(buf))
	hr := win.AssocQueryStringW({.INIT_IGNOREUNKNOWN, .NOTRUNCATE}, .EXECUTABLE, W(ext), nil, raw_data(buf[:]), &n)
	if hr != 0 do return ""
	s, err := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), -1, context.temp_allocator)
	if err != nil do return ""
	return s
}

// The first of these found on PATH, for files with no association at all.
@(private = "file")
find_on_path :: proc() -> string {
	names := [?]string{"code.cmd", "code.exe", "codium.cmd", "cursor.cmd", "idea64.exe", "idea.cmd", "idea.bat", "notepad++.exe", "subl.exe", "zed.exe"}
	path_var := os.get_env("PATH", context.temp_allocator)
	for name in names {
		for dir in strings.split_iterator(&path_var, ";") {
			// Relative entries (".") would mean the folder being searched.
			if dir == "" || !os.is_absolute_path(dir) do continue
			p := strings.concatenate({strings.trim_right(dir, "\\/"), "\\", name}, context.temp_allocator)
			if os.exists(p) do return p
		}
		path_var = os.get_env("PATH", context.temp_allocator)
	}
	return ""
}

platform_open_at_line :: proc(path: string, line: int) -> bool {
	exe := assoc_exe(path)
	if exe == "" do exe = find_on_path()
	if exe == "" {
		// Nothing claims this kind of file: let Windows ask.
		return platform_open_with_dialog(path)
	}
	kind := editor_kind(exe)
	if kind == .Unknown {
		// Not an editor we can pass a line to: open it the ordinary way.
		return shell_open(path)
	}
	args := editor_args(kind, quote_arg(path), line)
	lower := strings.to_lower(exe, context.temp_allocator)
	if strings.has_suffix(lower, ".cmd") || strings.has_suffix(lower, ".bat") {
		return run_command(strings.concatenate({quote_arg(exe), " ", args}, context.temp_allocator))
	}
	return shell_open(exe, args)
}

platform_open_default :: proc(path: string) -> bool {
	return shell_open(path)
}

// The "How do you want to open this file?" dialog. Its own process, so fff
// keeps drawing while it is up. The path goes unquoted: OpenAs_RunDLL takes
// the rest of its command line as the path.
platform_open_with_dialog :: proc(path: string) -> bool {
	return shell_open(system_exe("rundll32.exe"), strings.concatenate({"shell32.dll,OpenAs_RunDLL ", path}, context.temp_allocator))
}
