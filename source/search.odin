package fff

/*
    Running the query over the index.

    WHAT IS MATCHED is what fzf saw in the old ff:

        content mode    path:line: text     (rg -n --no-heading '.')
        files mode      path                (rg --files)

    so "app update" finds the line `game_update :: proc()` in source/app.odin
    because "app" matched the path and "update" the text, exactly as before.

    INCREMENTAL. A search remembers how far into the index it has got. A new
    keystroke starts it again from the top; a frame where nothing was typed
    carries on from where the last one stopped, which is also how results
    keep arriving while the index is still being read. Each frame's share is
    split over the cores (parallel.odin), each core keeping its own best-K,
    merged at the end.
*/

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "fuzzy"

Mode :: enum u8 {
	Content,
	Files,
}

MODE_NAME := [Mode]string {
	.Content = "content",
	.Files   = "files",
}

Search :: struct {
	query:     [dynamic]u8, // what the results below were computed for
	pattern:   fuzzy.Pattern,
	mode:      Mode,
	k:         int,
	gen:       int, // Index.generation the results point into
	rules_ver: int,
	done:      int, // items examined so far
	matched:   int, // how many of those matched
	// The best `k` so far, best first - far more than fit on screen, so the
	// list pages (main_view.odin, results_draw). `top_buf` is its storage.
	top:       fuzzy.Top,
	top_buf:   []fuzzy.Ranked, // owned
	// Bumped whenever `top` changes, so the list and viewer know to look.
	stamp:     int,
}

search_destroy :: proc(s: ^Search) {
	delete(s.query)
	delete(s.top_buf)
	s^ = {}
}

search_items :: proc(idx: ^Index, mode: Mode) -> int {
	return mode == .Content ? len(idx.lines) : len(idx.files)
}

search_busy :: proc(s: ^Search, idx: ^Index) -> bool {
	return s.done < search_items(idx, s.mode)
}

// Build the text an item is matched against into `buf`. Returns the slice
// used, and how many bytes of it are the "path:line:" prefix.
candidate :: proc(idx: ^Index, mode: Mode, item: u32, buf: []u8) -> (text: []u8, prefix: int) {
	n := 0
	put :: #force_inline proc(buf: []u8, n: ^int, s: string) {
		k := min(len(s), len(buf) - n^)
		copy(buf[n^:], s[:k])
		n^ += k
	}
	switch mode {
	case .Files:
		f := &idx.files[item]
		put(buf, &n, f.rel)
		return buf[:n], n
	case .Content:
		ref := idx.lines[item]
		f := &idx.files[ref.file]
		put(buf, &n, f.rel)
		put(buf, &n, ":")
		num: [16]u8
		put(buf, &n, strconv.write_int(num[:], i64(ref.line) + 1, 10))
		// ": " rather than ":" - the space makes the start of the line a
		// word boundary as strong as any other, so `game_update :: proc`
		// is not out-ranked by a comment that merely mentions it.
		put(buf, &n, ": ")
		prefix = n
		put(buf, &n, line_text(f, int(ref.line)))
		return buf[:n], prefix
	}
	return
}

CANDIDATE_MAX :: 2048

item_hidden :: proc(idx: ^Index, mode: Mode, item: u32) -> bool {
	switch mode {
	case .Files:
		return idx.files[item].hidden
	case .Content:
		return idx.files[idx.lines[item].file].hidden
	}
	return false
}

// Bring the search up to date with the query, the mode and the index, using
// at most `budget`. Returns true if the results changed.
search_step :: proc(s: ^Search, idx: ^Index, query: string, mode: Mode, k: int, rules_ver: int, budget: time.Duration, stats: ^Work_Stats = nil) -> bool {
	if string(s.query[:]) != query || s.mode != mode || s.k != k || s.gen != idx.generation || s.rules_ver != rules_ver {
		clear(&s.query)
		append(&s.query, query)
		s.pattern = fuzzy.parse(query)
		s.mode = mode
		s.k = k
		s.gen = idx.generation
		s.rules_ver = rules_ver
		s.done = 0
		s.matched = 0
		if len(s.top_buf) != k {
			delete(s.top_buf)
			s.top_buf = make([]fuzzy.Ranked, k)
		}
		fuzzy.top_init(&s.top, s.top_buf)
		s.stamp += 1
	}

	total := search_items(idx, mode)
	if s.done >= total do return false

	// No query: the first K items, in index order. fzf shows everything; we
	// show the top of everything, which is the same thing for a list of K.
	if fuzzy.is_empty(&s.pattern) {
		before := s.top.n
		for i := s.done; i < total && s.top.n < s.top.k; i += 1 {
			if item_hidden(idx, mode, u32(i)) do continue
			fuzzy.top_push(&s.top, {score = 0, length = 0, item = u32(i)})
		}
		s.matched = total
		s.done = total
		if s.top.n != before do s.stamp += 1
		return s.top.n != before
	}

	job := Search_Job {
		idx     = idx,
		pattern = &s.pattern,
		mode    = mode,
		start   = s.done,
		end     = total,
		started = time.tick_now(),
		budget  = budget,
	}
	n := min(worker_count(), max(1, (total - s.done) / SEARCH_CHUNK))
	// Each worker's own best-K, merged below. Allocated here, on this
	// thread: the temp allocator is per thread, and freed at frame end.
	for w in 0 ..< n do fuzzy.top_init(&job.tops[w], make([]fuzzy.Ranked, k, context.temp_allocator))
	search_start := time.tick_now()
	parallel(n, &job, search_worker, stats != nil ? &stats.busy : nil)
	if stats != nil {
		stats.search += time.tick_since(search_start)
		stats.slots = max(stats.slots, n)
	}

	claimed := sync.atomic_load(&job.next_chunk)
	s.done = min(total, s.done + claimed * SEARCH_CHUNK)
	changed := false
	for w in 0 ..< n {
		s.matched += job.matched[w]
		if job.tops[w].n > 0 {
			fuzzy.top_merge(&s.top, &job.tops[w])
			changed = true
		}
	}
	if changed do s.stamp += 1
	return changed
}

SEARCH_CHUNK :: 4096

@(private = "file")
Search_Job :: struct {
	idx:        ^Index,
	pattern:    ^fuzzy.Pattern, // read-only from every worker
	mode:       Mode,
	start, end: int,
	next_chunk: int, // atomic
	started:    time.Tick,
	budget:     time.Duration,
	tops:       [MAX_WORKERS]fuzzy.Top,
	matched:    [MAX_WORKERS]int,
}

@(private = "file")
search_worker :: proc(data: rawptr, worker: int) {
	job := (^Search_Job)(data)
	top := &job.tops[worker]
	buf: [CANDIDATE_MAX]u8
	matched := 0
	for time.tick_since(job.started) < job.budget {
		c := sync.atomic_add(&job.next_chunk, 1)
		from := job.start + c * SEARCH_CHUNK
		if from >= job.end do break
		to := min(job.end, from + SEARCH_CHUNK)
		for i in from ..< to {
			if item_hidden(job.idx, job.mode, u32(i)) do continue
			if job.mode == .Content {
				ref := job.idx.lines[i]
				f := &job.idx.files[ref.file]
				if !fuzzy.could_match(job.pattern, transmute([]u8)f.rel, transmute([]u8)line_text(f, int(ref.line))) do continue
			}
			text, _ := candidate(job.idx, job.mode, u32(i), buf[:])
			score, ok, _ := fuzzy.match(job.pattern, text)
			if !ok do continue
			matched += 1
			fuzzy.top_push(top, {score = i32(score), length = u32(len(text)), item = u32(i)})
		}
	}
	job.matched[worker] = matched
}

// Where the matched characters fall in a result, for highlighting.
match_positions :: proc(s: ^Search, idx: ^Index, item: u32, out: []int) -> (text: string, prefix: int, n: int) {
	buf := make([]u8, CANDIDATE_MAX, context.temp_allocator)
	t, p := candidate(idx, s.mode, item, buf)
	_, _, n = fuzzy.match(&s.pattern, t, out)
	// Several terms report their positions one after the other; drawing
	// wants them in order along the line.
	slice.sort(out[:n])
	return string(t), p, n
}

// "1234567" -> "1,234,567", into the temp allocator.
thousands :: proc(v: int) -> string {
	num: [32]u8
	s := strconv.write_int(num[:], i64(v), 10)
	b := strings.builder_make(context.temp_allocator)
	for c, i in transmute([]u8)s {
		if i > 0 && (len(s) - i) % 3 == 0 && s[i - 1] != '-' do strings.write_byte(&b, ',')
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}
