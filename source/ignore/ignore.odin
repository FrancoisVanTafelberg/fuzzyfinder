package ignore

/*
    What the side panel keeps track of: folders and file types to leave out of
    the search. Pure, so it can be tested headless (`odin test source/ignore`).

    Two kinds of folder entry, written the way .gitignore writes them:

        build/          any folder NAMED build, anywhere in the tree
        node_*          (a trailing slash too) - * and ? wildcards in the name
        /source/rlu/    exactly that folder, relative to the search root

    "Exclude folder from all searches" adds the first kind - a name, because a
    path only means something in the tree it came from, and the global list is
    shared by every tree fff is ever opened in. "Exclude folder from this
    search" adds the second kind, because there the tree IS known and naming
    one folder exactly is what you asked for.

    File types are extensions, stored lower-case without the dot ("log"), and
    compared case-insensitively. The panel shows them as "*.log".

    Paths handed in here are always relative to the root and always use '/',
    whatever the OS. The indexer converts once, on the way in.
*/

import "core:os"
import "core:strings"

Rules :: struct {
	folders: [dynamic]string, // owned
	types:   [dynamic]string, // owned, lower case, no dot
}

destroy :: proc(r: ^Rules) {
	for s in r.folders do delete(s)
	for s in r.types do delete(s)
	delete(r.folders)
	delete(r.types)
	r^ = {}
}

clone :: proc(r: ^Rules) -> (out: Rules) {
	for s in r.folders do append(&out.folders, strings.clone(s))
	for s in r.types do append(&out.types, strings.clone(s))
	return
}

// Normalise a folder entry as typed by a person or read from settings.txt:
// backslashes become '/', and a trailing '/' is added. Returns "" for an
// entry that names nothing.
normalize_folder :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	b := strings.builder_make(allocator)
	for c in transmute([]u8)t do strings.write_byte(&b, c == '\\' ? '/' : c)
	out := strings.to_string(b)
	for strings.has_suffix(out, "//") do out = out[:len(out) - 1]
	if out == "" || out == "/" {
		strings.builder_destroy(&b)
		return ""
	}
	if !strings.has_suffix(out, "/") {
		strings.write_byte(&b, '/')
		out = strings.to_string(b)
	}
	return out
}

// "*.LOG", ".log" and "log" are all "log".
normalize_type :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	t = strings.trim_prefix(t, "*")
	t = strings.trim_prefix(t, ".")
	if t == "" do return ""
	return strings.to_lower(t, allocator)
}

add_folder :: proc(r: ^Rules, entry: string) -> bool {
	e := normalize_folder(entry)
	if e == "" do return false
	for f in r.folders do if f == e {
		delete(e)
		return false
	}
	append(&r.folders, e)
	return true
}

add_type :: proc(r: ^Rules, entry: string) -> bool {
	e := normalize_type(entry)
	if e == "" do return false
	for f in r.types do if f == e {
		delete(e)
		return false
	}
	append(&r.types, e)
	return true
}

remove_folder :: proc(r: ^Rules, i: int) {
	if i < 0 || i >= len(r.folders) do return
	delete(r.folders[i])
	ordered_remove(&r.folders, i)
}

remove_type :: proc(r: ^Rules, i: int) {
	if i < 0 || i >= len(r.types) do return
	delete(r.types[i])
	ordered_remove(&r.types, i)
}

// Does one folder entry rule out the folder at `rel_dir`?
//
// `rel_dir` is the folder's path from the root without slashes at either end
// ("source/rlu"). Name entries test only the LAST component, because the walk
// asks about every folder on the way down: by the time it reaches
// source/rlu/x it has already been told about source/rlu.
folder_entry_matches :: proc(entry: string, rel_dir: string) -> bool {
	if len(entry) < 2 do return false
	if entry[0] == '/' {
		want := entry[1:len(entry) - 1] // "/source/rlu/" -> "source/rlu"
		return rel_dir == want || strings.has_prefix(rel_dir, want) && len(rel_dir) > len(want) && rel_dir[len(want)] == '/'
	}
	name := entry[:len(entry) - 1]
	last := rel_dir
	if i := strings.last_index_byte(rel_dir, '/'); i >= 0 do last = rel_dir[i + 1:]
	if strings.index_any(name, "*?[") < 0 do return last == name
	ok, _ := os.match(name, last)
	return ok
}

// Is the folder at `rel_dir` ruled out by either list?
folder_ignored :: proc(lists: []^Rules, rel_dir: string) -> bool {
	for r in lists do for e in r.folders do if folder_entry_matches(e, rel_dir) do return true
	return false
}

// The extension of a '/'-path, lower-cased into `buf`, or "".
// "Makefile" has none; ".gitignore" is a name, not an extension.
ext_of :: proc(rel: string, buf: []u8) -> string {
	name := rel
	if i := strings.last_index_byte(rel, '/'); i >= 0 do name = rel[i + 1:]
	dot := strings.last_index_byte(name, '.')
	if dot <= 0 || dot == len(name) - 1 do return ""
	e := name[dot + 1:]
	n := min(len(e), len(buf))
	for i in 0 ..< n {
		c := e[i]
		buf[i] = c >= 'A' && c <= 'Z' ? c + 32 : c
	}
	return string(buf[:n])
}

type_ignored :: proc(lists: []^Rules, rel: string) -> bool {
	buf: [64]u8
	e := ext_of(rel, buf[:])
	if e == "" do return false
	for r in lists do for t in r.types do if t == e do return true
	return false
}

// Is the file at `rel` ruled out, by its type or by any folder above it?
//
// Used when a rule is ADDED: files already indexed are hidden without walking
// the tree again. (Removing a rule re-walks, since what it uncovers was never
// read.)
file_ignored :: proc(lists: []^Rules, rel: string) -> bool {
	if type_ignored(lists, rel) do return true
	for i in 0 ..< len(rel) {
		if rel[i] == '/' && folder_ignored(lists, rel[:i]) do return true
	}
	return false
}
