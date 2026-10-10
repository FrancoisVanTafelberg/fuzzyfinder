#+build !windows
#+build !linux
package fff

// Other systems (macOS, the BSDs): core:os, slower but correct.

import "core:os"
import "core:strings"

PATH_SEP :: '/'

Path_Scratch :: struct {}

path_scratch_destroy :: proc(s: ^Path_Scratch) {}

list_dir :: proc(s: ^Path_Scratch, path: string, out: ^[dynamic]Dir_Entry, allocator := context.temp_allocator) -> bool {
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil do return false
	for e in entries {
		if e.name == "" || e.name == "." || e.name == ".." do continue
		#partial switch e.type {
		case .Directory:
			append(out, Dir_Entry{name = strings.clone(e.name, allocator), kind = .Dir, size = -1})
		case .Regular:
			append(out, Dir_Entry{name = strings.clone(e.name, allocator), kind = .File, size = e.size})
		}
	}
	return true
}

File_Handle :: ^os.File

file_open :: proc(s: ^Path_Scratch, path: string) -> (h: File_Handle, size: i64, ok: bool) {
	f, err := os.open(path)
	if err != nil do return nil, 0, false
	sz, serr := os.file_size(f)
	if serr != nil {
		os.close(f)
		return nil, 0, false
	}
	return f, sz, true
}

file_read :: proc(h: File_Handle, buf: []u8) -> int {
	total := 0
	for total < len(buf) {
		n, err := os.read(h, buf[total:])
		total += n
		if err != nil || n <= 0 do break
	}
	return total
}

file_close :: proc(h: File_Handle) {
	os.close(h)
}

memory_hint_huge :: proc(block: []u8) {}
