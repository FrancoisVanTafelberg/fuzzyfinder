#+build linux
package fff

/*
    Listing folders and reading files on Linux, straight on the system calls.

    core:os lists a folder with getdents64 and then does an openat and a
    statx for EVERY entry, to fill in a File_Info we mostly do not need. The
    type is already in getdents64's d_type, so here a folder is one open, a
    few getdents64 calls and a close: 17x faster on a 100,000-file folder
    (.design/performance_improvements.md, item 2). Only a file system that
    leaves d_type empty (DT_UNKNOWN) costs an fstatat per entry.

    The size is not in d_type: a reader learns it with an fstat on the file
    it has already opened.
*/

import "core:sys/linux"

PATH_SEP :: '/'

// Per-thread scratch for building NUL-terminated paths.
Path_Scratch :: struct {
	buf: [dynamic]u8,
}

path_scratch_destroy :: proc(s: ^Path_Scratch) {
	delete(s.buf)
}

@(private = "file")
c_path :: proc(s: ^Path_Scratch, path: string) -> cstring {
	clear(&s.buf)
	append(&s.buf, path)
	append(&s.buf, 0)
	return cstring(raw_data(s.buf))
}

// List one folder. Names are allocated with `allocator`. Symbolic links and
// anything that is neither a file nor a folder are left out.
list_dir :: proc(s: ^Path_Scratch, path: string, out: ^[dynamic]Dir_Entry, allocator := context.temp_allocator) -> bool {
	fd, err := linux.open(c_path(s, path), {.DIRECTORY, .CLOEXEC})
	if err != nil do return false
	defer linux.close(fd)

	buf: [32 * 1024]u8
	for {
		n, gerr := linux.getdents(fd, buf[:])
		if gerr != nil || n <= 0 do break
		off := 0
		for d in linux.dirent_iterate_buf(buf[:n], &off) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." || name == "" do continue
			kind: Entry_Kind
			#partial switch d.type {
			case .DIR:
				kind = .Dir
			case .REG:
				kind = .File
			case .UNKNOWN:
				// This file system does not say: ask, without following links.
				cname := make([]u8, len(name) + 1, context.temp_allocator)
				copy(cname, name)
				st: linux.Stat
				if linux.fstatat(fd, cstring(raw_data(cname)), &st, {.SYMLINK_NOFOLLOW}) != nil do continue
				if linux.S_ISDIR(st.mode) do kind = .Dir
				else if linux.S_ISREG(st.mode) do kind = .File
				else do continue
			case:
				continue // links, devices, sockets
			}
			n_copy := make([]u8, len(name), allocator)
			copy(n_copy, name)
			append(out, Dir_Entry{name = string(n_copy), kind = kind, size = -1})
		}
	}
	return true
}

File_Handle :: linux.Fd

// Open a file for reading and say how big it is.
file_open :: proc(s: ^Path_Scratch, path: string) -> (h: File_Handle, size: i64, ok: bool) {
	// NONBLOCK: a file that turned into a pipe since it was listed must not
	// hang the reader. It changes nothing for regular files.
	fd, err := linux.open(c_path(s, path), {.CLOEXEC, .NONBLOCK})
	if err != nil do return -1, 0, false
	st: linux.Stat
	if linux.fstat(fd, &st) != nil || !linux.S_ISREG(st.mode) {
		linux.close(fd)
		return -1, 0, false
	}
	return fd, i64(st.size), true
}

// Fill `buf` from the file, or as much of it as the file has. -1 on error.
file_read :: proc(h: File_Handle, buf: []u8) -> int {
	total := 0
	for total < len(buf) {
		n, err := linux.read(h, buf[total:])
		if err == .EINTR do continue
		if err != nil do return -1
		if n <= 0 do break
		total += n
	}
	return total
}

file_close :: proc(h: File_Handle) {
	linux.close(h)
}

// Ask for huge pages on a big block of fresh memory: fewer page faults when
// it is first written. A hint; ignored where it is not supported.
memory_hint_huge :: proc(block: []u8) {
	linux.madvise(raw_data(block), uint(len(block)), .HUGEPAGE)
}
