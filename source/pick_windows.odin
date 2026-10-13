#+build windows
package fff

/*
    Browse... on Windows: the shell's folder picker (SHBrowseForFolderW, with
    the newer resizable style and an edit box), opened at the current root.
    Run on its own thread (root_bar.odin), so fff keeps drawing; the window
    is its owner, so it stays on top of fff.

    NOTHING FROM user32 IS LINKED. user32.lib exports a CloseWindow, and so
    does raylib: with both on the link line, MSVC's linker fails with
    LNK2005 "CloseWindow already defined". The one user32 call needed here,
    SendMessageW, is looked up at run time instead (raylib has user32.dll
    loaded already).
*/

import "core:unicode/utf16"
import win "core:sys/windows"
import rl "vendor:raylib"

foreign import shell32 "system:Shell32.lib"

@(private = "file")
BROWSEINFOW :: struct {
	hwndOwner:      win.HWND,
	pidlRoot:       rawptr,
	pszDisplayName: [^]u16,
	lpszTitle:      win.LPCWSTR,
	ulFlags:        u32,
	lpfn:           rawptr,
	lParam:         win.LPARAM,
	iImage:         i32,
}

@(private = "file")
@(default_calling_convention = "system")
foreign shell32 {
	SHBrowseForFolderW :: proc(lpbi: ^BROWSEINFOW) -> rawptr ---
	SHGetPathFromIDListW :: proc(pidl: rawptr, pszPath: [^]u16) -> win.BOOL ---
}

@(private = "file")
BIF_RETURNONLYFSDIRS :: 0x1
@(private = "file")
BIF_EDITBOX :: 0x10
@(private = "file")
BIF_NEWDIALOGSTYLE :: 0x40
@(private = "file")
BFFM_INITIALIZED :: 1
@(private = "file")
BFFM_SETSELECTIONW :: 0x0400 + 103

@(private = "file")
Send_Message :: #type proc "system" (hwnd: win.HWND, msg: u32, wparam: win.WPARAM, lparam: win.LPARAM) -> win.LRESULT

@(private = "file")
send_message: Send_Message // user32's SendMessageW, found at run time

// Start the dialog where fff is searching now.
@(private = "file")
browse_callback :: proc "system" (hwnd: win.HWND, msg: u32, lparam: win.LPARAM, data: win.LPARAM) -> i32 {
	if msg == BFFM_INITIALIZED && data != 0 && send_message != nil do send_message(hwnd, BFFM_SETSELECTIONW, 1, data)
	return 0
}

// Ask for a folder. ok false: cancelled. `problem` says why there was no
// dialog at all.
pick_folder :: proc(start: string, allocator := context.allocator) -> (path: string, ok: bool, problem: string) {
	platform_init() // COM, on this thread
	if send_message == nil {
		user32 := win.GetModuleHandleW(win.L("user32.dll"))
		if user32 == nil do user32 = win.LoadLibraryW(win.L("user32.dll"))
		if user32 != nil do send_message = Send_Message(win.GetProcAddress(user32, "SendMessageW"))
	}
	wstart := make([]u16, len(start) + 1, context.temp_allocator)
	n := utf16.encode_string(wstart, start)
	for i in 0 ..< n do if wstart[i] == '/' do wstart[i] = '\\'
	wstart[n] = 0
	title := win.utf8_to_wstring("Folder to search")
	name: [win.MAX_PATH]u16
	bi := BROWSEINFOW {
		hwndOwner      = win.HWND(rl.GetWindowHandle()),
		pszDisplayName = raw_data(name[:]),
		lpszTitle      = title,
		ulFlags        = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX,
		lpfn           = rawptr(browse_callback),
		lParam         = win.LPARAM(uintptr(raw_data(wstart))),
	}
	pidl := SHBrowseForFolderW(&bi)
	if pidl == nil do return "", false, ""
	defer win.CoTaskMemFree(pidl)
	buf: [32768]u16
	if !SHGetPathFromIDListW(pidl, raw_data(buf[:])) do return "", false, "that is not a folder on disk"
	k := 0
	for k < len(buf) && buf[k] != 0 do k += 1
	s, err := win.utf16_to_utf8(buf[:k], allocator)
	if err != nil do return "", false, "out of memory"
	return s, true, ""
}
