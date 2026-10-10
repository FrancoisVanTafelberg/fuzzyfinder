#+build windows
package fff

/*
    Listing folders and reading files on Windows, straight on kernel32.

    core:os lists a folder with FindFirstFileW and then OPENS EVERY ENTRY
    (CreateFileW + GetFileInformationByHandleEx + CloseHandle) to fill in its
    inode number. So every file was opened twice - once to list it, once to
    read it - and each open is a chance for the virus scanner to step in.
    Here a folder is one FindFirstFileExW with:

        FindExInfoBasic             no 8.3 short names (a lookup per entry)
        FIND_FIRST_EX_LARGE_FETCH   more entries per call into the kernel

    and the size comes with each entry, so a file that is too big is never
    opened at all (.design/performance_improvements.md, items 2 and 3).

    Paths: fff keeps '/'-separated paths; they become '\' here. Past MAX_PATH
    they get the \\?\ prefix, which lifts the limit.
*/

import "core:unicode/utf16"
import win "core:sys/windows"

PATH_SEP :: '/'

foreign import kernel32 "system:Kernel32.lib"

@(private = "file")
@(default_calling_convention = "system")
foreign kernel32 {
	FindFirstFileExW :: proc(lpFileName: win.LPCWSTR, fInfoLevelId: i32, lpFindFileData: ^win.WIN32_FIND_DATAW, fSearchOp: i32, lpSearchFilter: rawptr, dwAdditionalFlags: win.DWORD) -> win.HANDLE ---
}

@(private = "file")
FIND_EX_INFO_BASIC :: 1
@(private = "file")
FIND_EX_SEARCH_NAME_MATCH :: 0
@(private = "file")
FIND_FIRST_EX_LARGE_FETCH :: 2

// Per-thread scratch for building wide paths.
Path_Scratch :: struct {
	w: [dynamic]u16,
}

path_scratch_destroy :: proc(s: ^Path_Scratch) {
	delete(s.w)
}

// `path` as a NUL-terminated wide string, '\'-separated, with `tail` (such as
// "\*") added. Long paths get the \\?\ prefix.
@(private = "file")
w_path :: proc(s: ^Path_Scratch, path: string, tail := "") -> win.LPCWSTR {
	full := len(path) + len(tail)
	prefix := ""
	rest := path
	if full >= 248 {
		if len(path) >= 2 && (path[0] == '/' || path[0] == '\\') && (path[1] == '/' || path[1] == '\\') {
			prefix = `\\?\UNC\`
			rest = path[2:]
		} else {
			prefix = `\\?\`
		}
	}
	resize(&s.w, len(prefix) + len(rest) + len(tail) + 1)
	n := utf16.encode_string(s.w[:], prefix)
	k := utf16.encode_string(s.w[n:], rest)
	for i in n ..< n + k do if s.w[i] == '/' do s.w[i] = '\\'
	n += k
	n += utf16.encode_string(s.w[n:], tail)
	s.w[n] = 0
	return win.LPCWSTR(raw_data(s.w))
}

// List one folder. Names are allocated with `allocator`. Symbolic links and
// junctions are left out (they can loop); other reparse points - OneDrive
// placeholders, for one - are ordinary files and folders.
list_dir :: proc(s: ^Path_Scratch, path: string, out: ^[dynamic]Dir_Entry, allocator := context.temp_allocator) -> bool {
	tail := len(path) > 0 && (path[len(path) - 1] == '/' || path[len(path) - 1] == '\\') ? "*" : `\*`
	data: win.WIN32_FIND_DATAW
	h := FindFirstFileExW(w_path(s, path, tail), FIND_EX_INFO_BASIC, &data, FIND_EX_SEARCH_NAME_MATCH, nil, FIND_FIRST_EX_LARGE_FETCH)
	if h == win.INVALID_HANDLE_VALUE do return false
	defer win.FindClose(h)
	for {
		add: {
			attrs := data.dwFileAttributes
			if attrs & win.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
				tag := data.dwReserved0
				if tag == win.IO_REPARSE_TAG_SYMLINK || tag == win.IO_REPARSE_TAG_MOUNT_POINT do break add
			}
			nlen := 0
			for nlen < len(data.cFileName) && data.cFileName[nlen] != 0 do nlen += 1
			wname := data.cFileName[:nlen]
			if nlen == 1 && wname[0] == '.' do break add
			if nlen == 2 && wname[0] == '.' && wname[1] == '.' do break add
			name, err := win.utf16_to_utf8(wname, allocator)
			if err != nil || name == "" do break add
			kind := attrs & win.FILE_ATTRIBUTE_DIRECTORY != 0 ? Entry_Kind.Dir : Entry_Kind.File
			size := i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow)
			append(out, Dir_Entry{name = name, kind = kind, size = size})
		}
		if !win.FindNextFileW(h, &data) do break
	}
	return true
}

File_Handle :: win.HANDLE

// Open a file for reading and say how big it is. Shared for reading, writing
// and deleting, so fff never stops an editor saving the file it is reading.
file_open :: proc(s: ^Path_Scratch, path: string) -> (h: File_Handle, size: i64, ok: bool) {
	h = win.CreateFileW(
		w_path(s, path),
		win.GENERIC_READ,
		win.FILE_SHARE_READ | win.FILE_SHARE_WRITE | win.FILE_SHARE_DELETE,
		nil,
		win.OPEN_EXISTING,
		win.FILE_ATTRIBUTE_NORMAL | win.FILE_FLAG_SEQUENTIAL_SCAN,
		nil,
	)
	if h == win.INVALID_HANDLE_VALUE do return nil, 0, false
	sz: win.LARGE_INTEGER
	if !win.GetFileSizeEx(h, &sz) {
		win.CloseHandle(h)
		return nil, 0, false
	}
	return h, i64(sz), true
}

// Fill `buf` from the file, or as much of it as the file has. -1 on error.
file_read :: proc(h: File_Handle, buf: []u8) -> int {
	total := 0
	for total < len(buf) {
		want := win.DWORD(min(len(buf) - total, 1 << 30))
		got: win.DWORD
		if !win.ReadFile(h, raw_data(buf[total:]), want, &got, nil) do return -1
		if got == 0 do break
		total += int(got)
	}
	return total
}

file_close :: proc(h: File_Handle) {
	win.CloseHandle(h)
}

// Large pages on Windows need a privilege ordinary users do not have.
memory_hint_huge :: proc(block: []u8) {}
