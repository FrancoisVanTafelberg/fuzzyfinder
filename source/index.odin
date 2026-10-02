package fff

/*
    The index: every file under the root, and every non-empty line of every
    text file, held in memory so a keystroke can be answered from RAM.

    This replaces `rg --files` (files mode) and `rg -n '.'` (content mode) in
    the old ff. Like rg with '.', a line is a search item if it has at least
    one character; blank lines are skipped.

    BUILT INCREMENTALLY, A SLICE OF EVERY FRAME. Opening fff in a big tree
    shows a window at once and results as they arrive, rather than a frozen
    window for however long the disk takes. Walking is cheap and done on the
    main thread; reading is the slow part and is spread over the cores (see
    parallel.odin for why those threads never outlive the frame).

    WHAT IS LEFT OUT: anything the ignore panel names (checked during the walk,
    so an ignored node_modules is never even listed), symbolic links (they
    can loop), files over `max_file_kb`, and files that look binary - a NUL
    byte in the first 8000 bytes, which is git's own test. Binary and
    too-big files are still FILES: they appear in files mode, and the viewer
    says why it cannot show them.
*/

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import "ignore"

File_State :: enum u8 {
	Pending,
	Text,
	Binary,
	Too_Big,
	Unreadable,
}

File :: struct {
	rel:    string, // owned; relative to the root, '/'-separated
	size:   i64,
	data:   []u8, // owned; only while .Text
	lines:  []u32, // owned; byte offset where each line starts
	state:  File_State,
	hidden: bool, // ruled out by an ignore rule added after it was indexed
}

// One searchable line: which file, which line (0-based).
Line_Ref :: struct {
	file: u32,
	line: u32,
}

Index :: struct {
	files:          [dynamic]File,
	lines:          [dynamic]Line_Ref,
	// Folders still to walk, as paths relative to the root ("" is the root).
	// A queue that is read from the front and only ever appended to, so the
	// walk is breadth-first: the files nearest the root are found first.
	dirs:           [dynamic]string,
	dir_next:       int,
	loaded:         int, // files[:loaded] have been read (or given up on)
	text_bytes:     i64,
	// Bumped on every rebuild. The search compares it to know its results
	// point into an index that no longer exists.
	generation:     int,
	max_file_bytes: i64,
}

BINARY_SNIFF :: 8000

index_destroy :: proc(idx: ^Index) {
	for &f in idx.files {
		delete(f.rel)
		delete(f.data)
		delete(f.lines)
	}
	for d in idx.dirs do delete(d)
	delete(idx.files)
	delete(idx.lines)
	delete(idx.dirs)
	gen := idx.generation
	idx^ = {}
	idx.generation = gen
}

// Throw everything away and start walking from the root again.
index_restart :: proc(idx: ^Index, max_file_bytes: i64) {
	index_destroy(idx)
	idx.generation += 1
	idx.max_file_bytes = max_file_bytes
	append(&idx.dirs, strings.clone(""))
}

index_walking :: proc(idx: ^Index) -> bool {
	return idx.dir_next < len(idx.dirs)
}

index_done :: proc(idx: ^Index) -> bool {
	return !index_walking(idx) && idx.loaded == len(idx.files)
}

// The text of one line, without its line ending.
line_text :: proc(f: ^File, line: int) -> string {
	if f.state != .Text || line < 0 || line >= len(f.lines) do return ""
	start := int(f.lines[line])
	end := line + 1 < len(f.lines) ? int(f.lines[line + 1]) : len(f.data)
	for end > start && (f.data[end - 1] == '\n' || f.data[end - 1] == '\r') do end -= 1
	return string(f.data[start:end])
}

// Do up to `budget` of indexing work. Returns true if anything changed.
index_step :: proc(idx: ^Index, root: string, lists: []^ignore.Rules, budget: time.Duration) -> bool {
	start := time.tick_now()
	changed := false

	// --- walk: a few folders at a time ---------------------------------
	walk_budget := budget / 3
	for idx.dir_next < len(idx.dirs) && time.tick_since(start) < walk_budget {
		rel := idx.dirs[idx.dir_next]
		idx.dir_next += 1
		walk_one(idx, root, rel, lists)
		changed = true
	}

	// --- read: the files found so far, over every core -----------------
	if idx.loaded < len(idx.files) {
		left := budget - time.tick_since(start)
		if left < time.Millisecond do left = time.Millisecond
		job := Load_Job {
			idx      = idx,
			root     = root,
			next     = idx.loaded,
			end      = min(len(idx.files), idx.loaded + 8192),
			started  = time.tick_now(),
			budget   = left,
		}
		n := min(worker_count(), max(1, (job.end - job.next) / 4))
		parallel(n, &job, load_worker)
		done := min(sync.atomic_load(&job.next), job.end)
		for i in idx.loaded ..< done {
			f := &idx.files[i]
			if f.state != .Text do continue
			idx.text_bytes += i64(len(f.data))
			for l in 0 ..< len(f.lines) {
				if len(line_text(f, l)) > 0 do append(&idx.lines, Line_Ref{u32(i), u32(l)})
			}
		}
		if done > idx.loaded do changed = true
		idx.loaded = done
	}

	// The walk queue's strings are no longer needed once it is finished.
	if !index_walking(idx) && len(idx.dirs) > 0 {
		for d in idx.dirs do delete(d)
		clear(&idx.dirs)
		idx.dir_next = 0
	}
	return changed
}

@(private = "file")
walk_one :: proc(idx: ^Index, root: string, rel: string, lists: []^ignore.Rules) {
	abs := rel == "" ? root : strings.concatenate({root, "/", rel}, context.temp_allocator)
	entries, err := os.read_all_directory_by_path(abs, context.temp_allocator)
	if err != nil do return
	// Sorted, so the same tree always lists in the same order.
	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {return a.name < b.name})

	for e in entries {
		if e.name == "" || e.name == "." || e.name == ".." do continue
		child := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		#partial switch e.type {
		case .Directory:
			if ignore.folder_ignored(lists, child) do continue
			append(&idx.dirs, strings.clone(child))
		case .Regular:
			if ignore.type_ignored(lists, child) do continue
			append(&idx.files, File{rel = strings.clone(child), size = e.size})
		}
	}
}

@(private = "file")
Load_Job :: struct {
	idx:     ^Index,
	root:    string,
	next:    int, // atomic: the next file to claim
	end:     int,
	started: time.Tick,
	budget:  time.Duration,
}

// Claim files one at a time until the batch or the time runs out. A claimed
// file is always finished, so after the join every index below `next` is done.
@(private = "file")
load_worker :: proc(data: rawptr, worker: int) {
	job := (^Load_Job)(data)
	for time.tick_since(job.started) < job.budget {
		i := sync.atomic_add(&job.next, 1)
		if i >= job.end do break
		load_file(&job.idx.files[i], job.root, job.idx.max_file_bytes)
	}
}

@(private = "file")
load_file :: proc(f: ^File, root: string, max_bytes: i64) {
	if f.size > max_bytes {
		f.state = .Too_Big
		return
	}
	path := strings.concatenate({root, "/", f.rel}, context.allocator)
	defer delete(path)
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		f.state = .Unreadable
		return
	}
	if i64(len(data)) > max_bytes {
		delete(data)
		f.state = .Too_Big
		return
	}
	sniff := data[:min(len(data), BINARY_SNIFF)]
	if slice.contains(sniff, 0) {
		delete(data)
		f.state = .Binary
		return
	}

	// A UTF-8 byte order mark is not part of the first line.
	first := 0
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF do first = 3

	n := 1
	for c, i in data do if c == '\n' && i + 1 < len(data) do n += 1
	lines := make([]u32, len(data) > first ? n : 0)
	if len(lines) > 0 {
		lines[0] = u32(first)
		k := 1
		for c, i in data {
			if c == '\n' && i + 1 < len(data) {
				lines[k] = u32(i + 1)
				k += 1
			}
		}
	}
	f.data = data
	f.lines = lines
	f.state = .Text
}

// Hide what a newly added rule rules out, without walking again.
index_apply_rules :: proc(idx: ^Index, lists: []^ignore.Rules) {
	for &f in idx.files do f.hidden = ignore.file_ignored(lists, f.rel)
}

// Where the index has got to, for the status line.
index_progress :: proc(idx: ^Index) -> f32 {
	if len(idx.files) == 0 do return index_walking(idx) ? 0 : 1
	return f32(idx.loaded) / f32(len(idx.files))
}
