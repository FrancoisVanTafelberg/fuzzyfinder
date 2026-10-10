package fff

/*
    The index: every file under the root, and every non-empty line of every
    text file, held in memory so a keystroke can be answered from RAM.

    BUILT ON BACKGROUND THREADS, and the window never waits for them.

        walker      one thread. Lists folders breadth-first (the files nearest
                    the root are found first) and publishes each file it finds.
        readers     several threads. Each claims the next published file,
                    reads it, works out where its lines start and which are
                    worth searching, and marks it done.

    The main thread only ever LOOKS: how many files are published, which are
    done. A file that takes ten seconds to read - a cloud placeholder being
    downloaded, a network drive, a virus scanner holding a big file - costs
    one reader those ten seconds and nothing else. That is the fix for the
    freezes measured on 10 October (.design/performance_improvements.md).

    STORAGE THAT NEVER MOVES. Files live in fixed blocks of FILE_CHUNK, and a
    block once allocated stays where it is. So the main thread and the search
    can read file i while the walker is still adding file i + 1000, with no
    lock: the walker fills a File in, then publishes it by bumping `count`,
    and a reader fills in the contents, then publishes them by setting
    `state`. Everyone else reads `count` and `state` first.

    EACH FILE KEEPS ITS OWN LIST of searchable lines (`items`), built by the
    reader that loaded it. There is no index-wide line list any more - that
    list, and the copies of it every time it grew, were one of the stalls.

    WHAT IS LEFT OUT: anything the ignore panel names (folders are not even
    entered), symbolic links (they can loop), files over `max_file_kb`, files
    that look binary (a NUL in the first 8000 bytes - git's test), and once
    the index holds `max_index_mb` of text, the contents of any more files.
    Left-out files are still FILES: they appear in files mode, and the viewer
    says why it cannot show them.

    REBUILDING is a new Index. The old one is told to stop and is freed once
    its threads have finished - a reader stuck on a slow file finishes in its
    own time, and nothing waits for it (app.odin, index_retire).
*/

import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "ignore"

File_State :: enum u8 {
	Pending,
	Text,
	Binary,
	Too_Big,
	Unreadable,
	Over_Limit, // the index already holds max_index_mb of text
}

File :: struct {
	rel:    string, // owned; relative to the root, '/'-separated
	size:   i64,
	data:   []u8, // owned; only while .Text
	lines:  []u32, // owned; byte offset where each line starts
	items:  []u32, // owned; the non-empty lines - what content mode searches
	state:  File_State, // written once, last, by the reader: read it with file_state
	hidden: bool, // ruled out by an ignore rule; the main thread writes it
}

FILE_CHUNK :: 4096
MAX_CHUNKS :: 16384 // 64M files

// The walker is slot 0 of the per-thread tables; readers are 1 ..= readers.
MAX_INDEX_THREADS :: MAX_WORKERS + 1

Index :: struct {
	root:           string, // owned
	generation:     int,
	max_file_bytes: i64,
	max_text_bytes: i64, // 0 = no limit
	walk_rules:     [2]ignore.Rules, // owned copies, for the walker alone

	chunks:         [MAX_CHUNKS]^[FILE_CHUNK]File,
	count:          int, // atomic: files published by the walker
	next_read:      int, // atomic: the next file a reader claims
	loaded:         int, // atomic: files read (whatever came of it)
	lines:          int, // atomic: searchable lines, over all loaded files
	text_bytes:     i64, // atomic: text held
	read_bytes:     i64, // atomic: bytes read from disk, text or not
	dirs:           int, // atomic: folders listed
	over_limit:     int, // atomic: files not read because of max_index_mb

	walking:        bool, // atomic
	readers_live:   int, // atomic
	stop:           bool, // atomic

	readers:        int,
	threads:        [MAX_INDEX_THREADS]^thread.Thread,

	// For the metrics panel and the watchdog, per thread slot: time spent
	// working (ns, atomic), and what it is working on now - a file index for
	// readers (-1 = waiting) and since when (tick ns).
	busy_ns:        [MAX_INDEX_THREADS]i64,
	current:        [MAX_INDEX_THREADS]int,
	since:          [MAX_INDEX_THREADS]i64,
	// The folder the walker is in, for the watchdog. Guarded by walk_mu.
	walk_mu:        sync.Mutex,
	walk_dir:       [512]u8,
	walk_dir_len:   int,
}

BINARY_SNIFF :: 8000

// Start building an index of `root` on background threads.
index_start :: proc(root: string, generation: int, max_file_bytes, max_text_bytes: i64, lists: []^ignore.Rules, readers: int) -> ^Index {
	idx := new(Index)
	idx.root = strings.clone(root)
	idx.generation = generation
	idx.max_file_bytes = max_file_bytes
	idx.max_text_bytes = max_text_bytes
	for l, i in lists do if i < len(idx.walk_rules) do idx.walk_rules[i] = ignore.clone(l)
	idx.readers = clamp(readers, 1, MAX_WORKERS)
	for i in 0 ..< MAX_INDEX_THREADS do idx.current[i] = -1

	sync.atomic_store(&idx.walking, true)
	sync.atomic_store(&idx.readers_live, idx.readers)
	idx.threads[0] = thread.create_and_start_with_poly_data(idx, walker_thread)
	for r in 1 ..= idx.readers {
		idx.threads[r] = thread.create_and_start_with_poly_data2(idx, r, reader_thread)
	}
	return idx
}

// Ask the threads to finish. Returns at once.
index_stop :: proc(idx: ^Index) {
	sync.atomic_store(&idx.stop, true)
}

// Have all of its threads finished? Then index_free can run without waiting.
index_threads_done :: proc(idx: ^Index) -> bool {
	return !sync.atomic_load(&idx.walking) && sync.atomic_load(&idx.readers_live) == 0
}

// Join the (finished) threads and free everything.
index_free :: proc(idx: ^Index) {
	for t in idx.threads do if t != nil {
		thread.join(t)
		thread.destroy(t)
	}
	n := sync.atomic_load(&idx.count)
	for i in 0 ..< n {
		f := index_file(idx, i)
		delete(f.rel)
		delete(f.data)
		delete(f.lines)
		delete(f.items)
	}
	for c in idx.chunks do if c != nil do free(c)
	for &r in idx.walk_rules do ignore.destroy(&r)
	delete(idx.root)
	free(idx)
}

index_count :: #force_inline proc "contextless" (idx: ^Index) -> int {
	return sync.atomic_load(&idx.count)
}

index_file :: #force_inline proc "contextless" (idx: ^Index, i: int) -> ^File {
	return &idx.chunks[i / FILE_CHUNK][i % FILE_CHUNK]
}

file_state :: #force_inline proc "contextless" (f: ^File) -> File_State {
	return sync.atomic_load(&f.state)
}

file_hidden :: #force_inline proc "contextless" (f: ^File) -> bool {
	return sync.atomic_load(&f.hidden)
}

index_walking :: proc(idx: ^Index) -> bool {
	return sync.atomic_load(&idx.walking)
}

// Everything found has been read, and nothing more will be found.
index_done :: proc(idx: ^Index) -> bool {
	if idx == nil do return true
	walking := sync.atomic_load(&idx.walking)
	return !walking && sync.atomic_load(&idx.loaded) >= sync.atomic_load(&idx.count)
}

index_progress :: proc(idx: ^Index) -> f32 {
	n := index_count(idx)
	if n == 0 do return index_walking(idx) ? 0 : 1
	return f32(sync.atomic_load(&idx.loaded)) / f32(n)
}

// The text of one line, without its line ending. Only for a .Text file.
line_text :: proc(f: ^File, line: int) -> string {
	if line < 0 || line >= len(f.lines) do return ""
	start := int(f.lines[line])
	end := line + 1 < len(f.lines) ? int(f.lines[line + 1]) : len(f.data)
	for end > start && (f.data[end - 1] == '\n' || f.data[end - 1] == '\r') do end -= 1
	return string(f.data[start:end])
}

// ---------------------------------------------------------------------------
// The walker
// ---------------------------------------------------------------------------

@(private = "file")
walker_thread :: proc(idx: ^Index) {
	defer sync.atomic_store(&idx.walking, false)
	thread_lower_priority()
	lists := [2]^ignore.Rules{&idx.walk_rules[0], &idx.walk_rules[1]}
	queue: [dynamic]string
	defer {
		for d in queue do delete(d)
		delete(queue)
	}
	append(&queue, strings.clone(""))
	next := 0
	for next < len(queue) && !sync.atomic_load(&idx.stop) {
		rel := queue[next]
		next += 1
		start := time.tick_now()
		sync.atomic_store(&idx.since[0], i64(start._nsec))
		sync.lock(&idx.walk_mu)
		idx.walk_dir_len = copy(idx.walk_dir[:], rel == "" ? "." : rel)
		sync.unlock(&idx.walk_mu)

		walk_one(idx, rel, lists[:], &queue)
		sync.atomic_add(&idx.dirs, 1)
		sync.atomic_add(&idx.busy_ns[0], i64(time.tick_since(start)))
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&idx.since[0], 0)
}

@(private = "file")
walk_one :: proc(idx: ^Index, rel: string, lists: []^ignore.Rules, queue: ^[dynamic]string) {
	abs := rel == "" ? idx.root : strings.concatenate({idx.root, "/", rel}, context.temp_allocator)
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
			append(queue, strings.clone(child))
		case .Regular:
			if ignore.type_ignored(lists, child) do continue
			publish_file(idx, child, e.size)
		}
	}
}

// Only the walker calls this: fill the File in, then make it visible.
@(private = "file")
publish_file :: proc(idx: ^Index, rel: string, size: i64) {
	i := idx.count // only this thread writes it
	if i >= MAX_CHUNKS * FILE_CHUNK do return
	c := i / FILE_CHUNK
	if idx.chunks[c] == nil do idx.chunks[c] = new([FILE_CHUNK]File)
	idx.chunks[c][i % FILE_CHUNK] = File {
		rel  = strings.clone(rel),
		size = size,
	}
	sync.atomic_store(&idx.count, i + 1)
}

// ---------------------------------------------------------------------------
// The readers
// ---------------------------------------------------------------------------

@(private = "file")
reader_thread :: proc(idx: ^Index, slot: int) {
	defer sync.atomic_sub(&idx.readers_live, 1)
	thread_lower_priority()
	path_buf: [dynamic]u8
	defer delete(path_buf)
	for !sync.atomic_load(&idx.stop) {
		i := sync.atomic_add(&idx.next_read, 1)
		// Wait for the walker to get that far - or to finish without doing so.
		for i >= index_count(idx) {
			if !sync.atomic_load(&idx.walking) && i >= index_count(idx) do return
			if sync.atomic_load(&idx.stop) do return
			time.sleep(time.Millisecond)
		}
		f := index_file(idx, i)
		start := time.tick_now()
		sync.atomic_store(&idx.since[slot], i64(start._nsec))
		sync.atomic_store(&idx.current[slot], i)

		load_file(idx, f, &path_buf)

		took := time.tick_since(start)
		sync.atomic_store(&idx.current[slot], -1)
		sync.atomic_add(&idx.busy_ns[slot], i64(took))
		sync.atomic_add(&idx.loaded, 1)
		if took > SLOW_READ do log_line("slow read: %v for %s (%v KB)", took, f.rel, f.size / 1024)
	}
}

// A file read slower than this is written to fff.log.
SLOW_READ :: time.Second

@(private = "file")
load_file :: proc(idx: ^Index, f: ^File, path_buf: ^[dynamic]u8) {
	if f.size > idx.max_file_bytes {
		sync.atomic_store(&f.state, File_State.Too_Big)
		return
	}
	if idx.max_text_bytes > 0 && sync.atomic_load(&idx.text_bytes) + f.size > idx.max_text_bytes {
		sync.atomic_add(&idx.over_limit, 1)
		sync.atomic_store(&f.state, File_State.Over_Limit)
		return
	}
	clear(path_buf)
	append(path_buf, idx.root)
	append(path_buf, "/")
	append(path_buf, f.rel)
	data, err := os.read_entire_file_from_path(string(path_buf[:]), context.allocator)
	if err != nil {
		sync.atomic_store(&f.state, File_State.Unreadable)
		return
	}
	sync.atomic_add(&idx.read_bytes, i64(len(data)))
	if i64(len(data)) > idx.max_file_bytes {
		delete(data)
		sync.atomic_store(&f.state, File_State.Too_Big)
		return
	}
	if slice.contains(data[:min(len(data), BINARY_SNIFF)], 0) {
		delete(data)
		sync.atomic_store(&f.state, File_State.Binary)
		return
	}

	// A UTF-8 byte order mark is not part of the first line.
	first := 0
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF do first = 3

	n := 0
	if len(data) > first {
		n = 1
		for c, i in data do if c == '\n' && i + 1 < len(data) do n += 1
	}
	lines := make([]u32, n)
	if n > 0 {
		lines[0] = u32(first)
		k := 1
		for c, i in data {
			if c == '\n' && i + 1 < len(data) {
				lines[k] = u32(i + 1)
				k += 1
			}
		}
	}
	// The lines with something on them: a line is searched if it has at
	// least one character, as with rg '.'. Counted, then listed.
	has_text :: #force_inline proc(data: []u8, lines: []u32, l: int) -> bool {
		s := int(lines[l])
		e := l + 1 < len(lines) ? int(lines[l + 1]) : len(data)
		for e > s && (data[e - 1] == '\n' || data[e - 1] == '\r') do e -= 1
		return e > s
	}
	nonempty := 0
	for l in 0 ..< n do if has_text(data, lines, l) do nonempty += 1
	items := make([]u32, nonempty)
	k := 0
	for l in 0 ..< n do if has_text(data, lines, l) {
		items[k] = u32(l)
		k += 1
	}

	f.data = data
	f.lines = lines
	f.items = items
	sync.atomic_add(&idx.text_bytes, i64(len(data)))
	sync.atomic_add(&idx.lines, nonempty)
	sync.atomic_store(&f.state, File_State.Text) // publishes everything above
}

// ---------------------------------------------------------------------------
// Rules added after the walk started
// ---------------------------------------------------------------------------

// Mark files ruled out by the current lists, from file `from` on. Returns the
// count it has got to, and whether any file was newly hidden. The main thread
// calls this every frame for newly published files (the walker works from a
// copy of the rules taken when it started), and from 0 when a rule is added.
index_apply_rules :: proc(idx: ^Index, lists: []^ignore.Rules, from: int) -> (upto: int, hid_any: bool) {
	n := index_count(idx)
	for i in from ..< n {
		f := index_file(idx, i)
		h := ignore.file_ignored(lists, f.rel)
		if h != file_hidden(f) {
			sync.atomic_store(&f.hidden, h)
			if h do hid_any = true
		}
	}
	return n, hid_any
}

// Roughly what the index holds: the text, the two line tables (line starts
// and searchable lines, a u32 each - counted from the searchable lines, as
// counting the starts exactly would mean touching every file), the blocks.
index_memory :: proc(idx: ^Index) -> i64 {
	if idx == nil do return 0
	total := sync.atomic_load(&idx.text_bytes)
	total += i64(sync.atomic_load(&idx.lines)) * 2 * size_of(u32)
	for c in idx.chunks do if c != nil do total += size_of([FILE_CHUNK]File)
	return total
}
