package fff

/*
    The index: every file under the root, and every non-empty line of every
    text file, held in memory so a keystroke can be answered from RAM.

    BUILT ON BACKGROUND THREADS, and the window never waits for them.

        walkers     a few threads. List folders breadth-first (the files
                    nearest the root are found first) and publish the files
                    they find, in the same order every run (see Index.jobs).
        readers     twice as many as there are cores: reading is partly
                    waiting for the disk, and an SSD answers many requests at
                    once. Each claims the next published file, reads it, works
                    out where its lines start and which are worth searching,
                    and marks it done.

    Folders are listed and files read with the system calls directly
    (fs_linux.odin, fs_windows.odin): core:os does several calls per entry
    that fff does not need. File text and line tables go into each reader's
    arena (arena.odin), not one heap allocation per file.

    The main thread only ever LOOKS: how many files are published, which are
    done. A file that takes ten seconds to read - a cloud placeholder being
    downloaded, a network drive, a virus scanner holding a big file - costs
    one reader those ten seconds and nothing else. That is the fix for the
    freezes measured on 10 October (.design/performance_improvements.md).

    STORAGE THAT NEVER MOVES. Files live in fixed blocks of FILE_CHUNK, and a
    block once allocated stays where it is. So the main thread and the search
    can read file i while the walker is still adding file i + 1000, with no
    lock: a walker fills a File in, then publishes it by bumping `count`,
    and a reader fills in the contents, then publishes them by setting
    `state`. Everyone else reads `count` and `state` first.

    EACH FILE KEEPS ITS OWN LIST of searchable lines (`items`), built by the
    reader that loaded it. There is no index-wide line list any more - that
    list, and the copies of it every time it grew, were one of the stalls.

    WHAT IS LEFT OUT: anything the ignore panel names (folders are not even
    entered), symbolic links (they can loop), files over the size limit, files
    that look binary (a NUL in the first 8000 bytes - git's test), and once
    the index holds `max_index_mb` of text, the contents of any more files.
    Left-out files are still FILES: they appear in files mode, and the viewer
    says why it cannot show them.

    REBUILDING is a new Index. The old one is told to stop and is freed once
    its threads have finished - a reader stuck on a slow file finishes in its
    own time, and nothing waits for it (app.odin, index_retire).
*/

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
	size:   i64, // -1 until known (Linux learns it when the file is opened)
	data:   []u8, // in a reader's arena; only while .Text
	lines:  []u32, // in a reader's arena; byte offset where each line starts
	items:  []u32, // in a reader's arena; the non-empty lines - what content mode searches
	state:  File_State, // written once, last, by the reader: read it with file_state
	hidden: bool, // ruled out by an ignore rule; the main thread writes it
}

FILE_CHUNK :: 4096
MAX_CHUNKS :: 16384 // 64M files

MAX_WALKERS :: 8
MAX_READERS :: 32
// Per-thread tables: walkers are slots 0 ..< walkers, readers come after.
MAX_INDEX_THREADS :: MAX_WALKERS + MAX_READERS

// One entry of a folder listing (fs_*.odin).
Entry_Kind :: enum u8 {
	File,
	Dir,
}

Dir_Entry :: struct {
	name: string,
	kind: Entry_Kind,
	size: i64, // -1 if the listing does not say
}

// A folder to list, in the order folders are found. Guarded by walk_mu.
@(private = "file")
Dir_Job :: struct {
	rel:    string, // owned
	listed: bool,
	batch:  ^Dir_Batch, // what listing it found, until published
}

@(private = "file")
Dir_Batch :: struct {
	files: [dynamic]Batch_File,
	dirs:  [dynamic]string, // owned until published
}

@(private = "file")
Batch_File :: struct {
	rel:  string, // owned until published
	size: i64,
}

Index :: struct {
	root:           string, // owned
	join_root:      string, // owned; root without a trailing '/': join_root + "/" + rel
	generation:     int,
	max_file_bytes: i64,
	max_text_bytes: i64, // 0 = no limit
	walk_rules:     [2]ignore.Rules, // owned copies, read by the walkers

	chunks:         [MAX_CHUNKS]^[FILE_CHUNK]File,
	count:          int, // atomic: files published
	next_read:      int, // atomic: the next file a reader claims
	loaded:         int, // atomic: files read (whatever came of it)
	lines:          int, // atomic: searchable lines, over all loaded files
	text_bytes:     i64, // atomic: text held
	read_bytes:     i64, // atomic: bytes read from disk, text or not
	dirs:           int, // atomic: folders listed
	over_limit:     int, // atomic: files not read because of max_index_mb
	// For "X GB left": the bytes to read, as far as the listings said (only
	// Windows listings give sizes), and how many of them are done.
	// size_unknown counts files listed without a size: while it is above
	// zero there is no byte total to show.
	found_bytes:    i64, // atomic
	done_bytes:     i64, // atomic
	size_unknown:   int, // atomic

	walking:        bool, // atomic
	walkers_live:   int, // atomic
	readers_live:   int, // atomic
	stop:           bool, // atomic

	walkers:        int,
	readers:        int,
	threads:        [MAX_INDEX_THREADS]^thread.Thread,
	arenas:         [MAX_READERS]Arena, // one per reader; freed with the index

	// The folder queue. Folders are LISTED by whichever walker is free, but
	// PUBLISHED strictly in the order they were found: a walker that finishes
	// folder 7 before folder 6 is done leaves its listing for whoever finishes
	// 6 to publish after it. So the files come out in the same order every
	// run - breadth-first, sorted within each folder - however the work was
	// shared, and ties in the results always break the same way.
	walk_mu:        sync.Mutex,
	walk_cv:        sync.Cond,
	jobs:           [dynamic]Dir_Job,
	job_next:       int, // the next folder to list
	job_published:  int, // folders before this are published

	// For the metrics panel and the watchdog, per thread slot: time spent
	// working (ns, atomic), and what it is working on now - a file index for
	// readers, a folder (job) index for walkers, -1 = waiting - and since
	// when (tick ns).
	busy_ns:        [MAX_INDEX_THREADS]i64,
	current:        [MAX_INDEX_THREADS]int,
	since:          [MAX_INDEX_THREADS]i64,
}

BINARY_SNIFF :: 8000
// Read this much first and look for a NUL before reading the rest, so a big
// binary file costs one small read.
FIRST_READ :: 64 * 1024

// Start building an index of `root` on background threads.
index_start :: proc(root: string, generation: int, max_file_bytes, max_text_bytes: i64, lists: []^ignore.Rules, walkers, readers: int) -> ^Index {
	idx := new(Index)
	idx.root = strings.clone(root)
	jr := root
	for len(jr) > 0 && jr[len(jr) - 1] == '/' do jr = jr[:len(jr) - 1]
	idx.join_root = strings.clone(jr)
	idx.generation = generation
	idx.max_file_bytes = max_file_bytes
	idx.max_text_bytes = max_text_bytes
	for l, i in lists do if i < len(idx.walk_rules) do idx.walk_rules[i] = ignore.clone(l)
	idx.walkers = clamp(walkers, 1, MAX_WALKERS)
	idx.readers = clamp(readers, 1, MAX_READERS)
	for i in 0 ..< MAX_INDEX_THREADS do idx.current[i] = -1
	append(&idx.jobs, Dir_Job{rel = strings.clone("")})

	sync.atomic_store(&idx.walking, true)
	sync.atomic_store(&idx.walkers_live, idx.walkers)
	sync.atomic_store(&idx.readers_live, idx.readers)
	for w in 0 ..< idx.walkers {
		idx.threads[w] = thread.create_and_start_with_poly_data2(idx, w, walker_thread)
	}
	for r in 0 ..< idx.readers {
		idx.threads[idx.walkers + r] = thread.create_and_start_with_poly_data2(idx, r, reader_thread)
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
	for i in 0 ..< n do delete(index_file(idx, i).rel)
	for c in idx.chunks do if c != nil do free(c)
	for &a in idx.arenas do arena_release(&a)
	for j in idx.jobs {
		delete(j.rel)
		if b := j.batch; b != nil do batch_free(b)
	}
	delete(idx.jobs)
	for &r in idx.walk_rules do ignore.destroy(&r)
	delete(idx.root)
	delete(idx.join_root)
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

// The bytes still to read, if every file found so far came with a size
// (Windows); ok false otherwise (Linux).
index_bytes_left :: proc(idx: ^Index) -> (left: i64, done: i64, ok: bool) {
	if sync.atomic_load(&idx.size_unknown) > 0 do return 0, 0, false
	found := sync.atomic_load(&idx.found_bytes)
	done = sync.atomic_load(&idx.done_bytes)
	return max(found - done, 0), done, true
}

index_progress :: proc(idx: ^Index) -> f32 {
	n := index_count(idx)
	if n == 0 do return index_walking(idx) ? 0 : 1
	return f32(sync.atomic_load(&idx.loaded)) / f32(n)
}

// The folder a walker slot is listing, for the watchdog.
index_walker_dir :: proc(idx: ^Index, job: int, allocator := context.temp_allocator) -> string {
	sync.lock(&idx.walk_mu)
	defer sync.unlock(&idx.walk_mu)
	if job < 0 || job >= len(idx.jobs) do return ""
	rel := idx.jobs[job].rel
	return strings.clone(rel == "" ? "." : rel, allocator)
}

// The text of one line, without its line ending. Only for a .Text file.
line_text :: proc(f: ^File, line: int) -> string {
	if line < 0 || line >= len(f.lines) do return ""
	start := int(f.lines[line])
	end := line + 1 < len(f.lines) ? int(f.lines[line + 1]) : len(f.data)
	for end > start && (f.data[end - 1] == '\n' || f.data[end - 1] == '\r') do end -= 1
	return string(f.data[start:end])
}

// The line holding byte `at`, looking only at lines lo ..< hi.
line_of :: proc "contextless" (f: ^File, at: int, lo, hi: int) -> int {
	lo, hi := lo, hi
	// The last line in lo ..< hi that starts at or before `at`.
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if int(f.lines[mid]) <= at do lo = mid
		else do hi = mid
	}
	return lo
}

// ---------------------------------------------------------------------------
// The walkers
// ---------------------------------------------------------------------------

@(private = "file")
walker_thread :: proc(idx: ^Index, slot: int) {
	thread_lower_priority()
	scratch: Path_Scratch
	defer path_scratch_destroy(&scratch)
	lists := [2]^ignore.Rules{&idx.walk_rules[0], &idx.walk_rules[1]}

	sync.lock(&idx.walk_mu)
	for !sync.atomic_load(&idx.stop) {
		if idx.job_next < len(idx.jobs) {
			j := idx.job_next
			idx.job_next += 1
			rel := idx.jobs[j].rel
			sync.unlock(&idx.walk_mu)

			start := time.tick_now()
			sync.atomic_store(&idx.current[slot], j)
			sync.atomic_store(&idx.since[slot], i64(start._nsec))
			batch := list_one(idx, rel, lists[:], &scratch)
			sync.atomic_add(&idx.dirs, 1)
			sync.atomic_store(&idx.since[slot], 0)
			sync.atomic_store(&idx.current[slot], -1)
			sync.atomic_add(&idx.busy_ns[slot], i64(time.tick_since(start)))
			free_all(context.temp_allocator)

			sync.lock(&idx.walk_mu)
			idx.jobs[j].batch = batch
			idx.jobs[j].listed = true
			publish_ready(idx)
			continue
		}
		// Nothing to list. Done if nothing is being listed either - a folder
		// still being listed may yet add more.
		if idx.job_published >= len(idx.jobs) do break
		sync.cond_wait_with_timeout(&idx.walk_cv, &idx.walk_mu, 50 * time.Millisecond)
	}
	sync.cond_broadcast(&idx.walk_cv)
	sync.unlock(&idx.walk_mu)
	// The last walker out says the walk is over.
	if sync.atomic_sub(&idx.walkers_live, 1) == 1 do sync.atomic_store(&idx.walking, false)
}

// List one folder into a batch: sorted, ignored entries left out.
@(private = "file")
list_one :: proc(idx: ^Index, rel: string, lists: []^ignore.Rules, scratch: ^Path_Scratch) -> ^Dir_Batch {
	path := strings.concatenate({idx.join_root, "/", rel}, context.temp_allocator)
	entries := make([dynamic]Dir_Entry, context.temp_allocator)
	if !list_dir(scratch, path, &entries) do return nil
	// Sorted, so the same tree always lists in the same order.
	slice.sort_by(entries[:], proc(a, b: Dir_Entry) -> bool {return a.name < b.name})

	b := new(Dir_Batch)
	for e in entries {
		child := rel == "" ? e.name : strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		switch e.kind {
		case .Dir:
			if ignore.folder_ignored(lists, child) do continue
			append(&b.dirs, strings.clone(child))
		case .File:
			if ignore.type_ignored(lists, child) do continue
			append(&b.files, Batch_File{rel = strings.clone(child), size = e.size})
		}
	}
	return b
}

@(private = "file")
batch_free :: proc(b: ^Dir_Batch) {
	for f in b.files do delete(f.rel)
	for d in b.dirs do delete(d)
	delete(b.files)
	delete(b.dirs)
	free(b)
}

// With walk_mu held: publish every listed folder at the front of the queue,
// in order. Its files become visible to the readers, its folders join the
// queue.
@(private = "file")
publish_ready :: proc(idx: ^Index) {
	progressed := false
	for idx.job_published < len(idx.jobs) && idx.jobs[idx.job_published].listed {
		b := idx.jobs[idx.job_published].batch
		idx.jobs[idx.job_published].batch = nil
		idx.job_published += 1
		progressed = true
		if b == nil do continue // could not be listed
		for f in b.files do publish_file(idx, f.rel, f.size)
		for d in b.dirs do append(&idx.jobs, Dir_Job{rel = d})
		delete(b.files)
		delete(b.dirs)
		free(b)
	}
	if progressed do sync.cond_broadcast(&idx.walk_cv)
}

// With walk_mu held: fill the File in, then make it visible. Takes `rel`.
@(private = "file")
publish_file :: proc(idx: ^Index, rel: string, size: i64) {
	i := idx.count // only the holder of walk_mu writes it
	if i >= MAX_CHUNKS * FILE_CHUNK {
		delete(rel)
		return
	}
	c := i / FILE_CHUNK
	if idx.chunks[c] == nil do idx.chunks[c] = new([FILE_CHUNK]File)
	idx.chunks[c][i % FILE_CHUNK] = File {
		rel  = rel,
		size = size,
	}
	if size < 0 {
		sync.atomic_add(&idx.size_unknown, 1)
	} else if size <= idx.max_file_bytes {
		sync.atomic_add(&idx.found_bytes, size) // too big ones are never read
	}
	sync.atomic_store(&idx.count, i + 1)
}

// ---------------------------------------------------------------------------
// The readers
// ---------------------------------------------------------------------------

@(private = "file")
Reader :: struct {
	path:    [dynamic]u8,
	scratch: Path_Scratch,
	arena:   ^Arena,
}

@(private = "file")
reader_thread :: proc(idx: ^Index, r: int) {
	defer sync.atomic_sub(&idx.readers_live, 1)
	thread_lower_priority()
	slot := idx.walkers + r
	rd := Reader {
		arena = &idx.arenas[r],
	}
	defer {
		delete(rd.path)
		path_scratch_destroy(&rd.scratch)
	}
	for !sync.atomic_load(&idx.stop) {
		i := sync.atomic_add(&idx.next_read, 1)
		// Wait for the walkers to get that far - or to finish without doing so.
		for i >= index_count(idx) {
			if !sync.atomic_load(&idx.walking) && i >= index_count(idx) do return
			if sync.atomic_load(&idx.stop) do return
			time.sleep(time.Millisecond)
		}
		f := index_file(idx, i)
		listed := f.size // what the listing said; load_file may correct it
		start := time.tick_now()
		sync.atomic_store(&idx.since[slot], i64(start._nsec))
		sync.atomic_store(&idx.current[slot], i)

		load_file(idx, f, &rd)
		if listed >= 0 && listed <= idx.max_file_bytes do sync.atomic_add(&idx.done_bytes, listed)

		took := time.tick_since(start)
		sync.atomic_store(&idx.current[slot], -1)
		sync.atomic_add(&idx.busy_ns[slot], i64(took))
		sync.atomic_add(&idx.loaded, 1)
		if took > SLOW_READ do log_line("slow read: %v for %s (%v KB)", took, f.rel, max(f.size, 0) / 1024)
	}
}

// A file read slower than this is written to fff.log.
SLOW_READ :: time.Second

@(private = "file")
over_limit :: proc(idx: ^Index, size: i64) -> bool {
	return idx.max_text_bytes > 0 && sync.atomic_load(&idx.text_bytes) + size > idx.max_text_bytes
}

@(private = "file")
load_file :: proc(idx: ^Index, f: ^File, rd: ^Reader) {
	// When the listing gave the size (Windows), a file that is too big is
	// never even opened.
	if f.size > idx.max_file_bytes {
		sync.atomic_store(&f.state, File_State.Too_Big)
		return
	}
	if f.size >= 0 && over_limit(idx, f.size) {
		sync.atomic_add(&idx.over_limit, 1)
		sync.atomic_store(&f.state, File_State.Over_Limit)
		return
	}

	clear(&rd.path)
	append(&rd.path, idx.join_root)
	append(&rd.path, "/")
	append(&rd.path, f.rel)
	h, size, ok := file_open(&rd.scratch, string(rd.path[:]))
	if !ok {
		sync.atomic_store(&f.state, File_State.Unreadable)
		return
	}
	defer file_close(h)
	f.size = size
	if size > idx.max_file_bytes {
		sync.atomic_store(&f.state, File_State.Too_Big)
		return
	}
	if over_limit(idx, size) {
		sync.atomic_add(&idx.over_limit, 1)
		sync.atomic_store(&f.state, File_State.Over_Limit)
		return
	}

	data := arena_alloc(rd.arena, int(size))
	if data == nil && size > 0 {
		sync.atomic_store(&f.state, File_State.Unreadable) // out of memory
		return
	}
	// The first piece, and git's binary test on it, before the rest.
	n := file_read(h, data[:min(len(data), FIRST_READ)])
	if n < 0 {
		arena_trim(rd.arena, data)
		sync.atomic_store(&f.state, File_State.Unreadable)
		return
	}
	if slice.contains(data[:min(n, BINARY_SNIFF)], 0) {
		sync.atomic_add(&idx.read_bytes, i64(n))
		arena_trim(rd.arena, data)
		sync.atomic_store(&f.state, File_State.Binary)
		return
	}
	if n == FIRST_READ && n < len(data) {
		m := file_read(h, data[n:])
		if m < 0 {
			arena_trim(rd.arena, data)
			sync.atomic_store(&f.state, File_State.Unreadable)
			return
		}
		n += m
	}
	sync.atomic_add(&idx.read_bytes, i64(n))
	data = data[:n] // it may have shrunk since it was measured

	// A UTF-8 byte order mark is not part of the first line.
	first := 0
	if n >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF do first = 3

	// Line starts, and the lines with something on them - a line is searched
	// if it has at least one character, as with rg '.'. One count, then one
	// pass that fills both; `items` is sized for every line and trimmed.
	nl := 0
	if n > first do nl = count_byte(data[:n - 1], '\n') + 1
	lines := slice.reinterpret([]u32, arena_alloc(rd.arena, nl * 4, 4))
	items := slice.reinterpret([]u32, arena_alloc(rd.arena, nl * 4, 4))
	if nl > 0 && (lines == nil || items == nil) {
		sync.atomic_store(&f.state, File_State.Unreadable) // out of memory
		return
	}
	k, m := 0, 0
	if nl > 0 {
		s := first
		for k < nl {
			nlpos := find_byte(data[s:], '\n')
			e := nlpos < 0 ? n : s + nlpos
			te := e
			for te > s && data[te - 1] == '\r' do te -= 1
			lines[k] = u32(s)
			if te > s {
				items[m] = u32(k)
				m += 1
			}
			k += 1
			if nlpos < 0 || e + 1 >= n do break
			s = e + 1
		}
	}
	arena_trim(rd.arena, slice.to_bytes(items), m * 4)

	f.data = data
	f.lines = lines[:k]
	f.items = items[:m]
	sync.atomic_add(&idx.text_bytes, i64(n))
	sync.atomic_add(&idx.lines, m)
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
