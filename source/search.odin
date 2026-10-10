package fff

/*
    Running the query over the index - on a thread of its own.

    WHAT IS MATCHED is what fzf saw in the old ff:

        content mode    path:line: text     (rg -n --no-heading '.')
        files mode      path                (rg --files)

    so "app update" finds the line `game_update :: proc()` in source/app.odin
    because "app" matched the path and "update" the text, exactly as before.

    THE SEARCH THREAD (Searcher) never stops while fff runs. The main thread
    posts what it wants - query, mode, how many results, which index - and
    reads back whatever the search thread last published. Neither ever waits
    for the other beyond a mutex held for a copy:

      - a keystroke posts a new request and bumps `cancel_id`; the search
        workers check it between files, so the old search stops within a file
        and the new one starts;
      - while the index is still being built the search keeps going over
        whatever has been read, and catches up as more arrives;
      - every round (SEARCH_ROUND, a few tens of ms) it publishes the best so
        far, so results appear while a big search is still running.

    A round is split over the cores (parallel.odin). Each worker claims whole
    files - first any it had to skip earlier because they were still being
    read, then the next unclaimed ones - and keeps its own best-K; they are
    merged when the round ends.

    Search_State and search_round are the engine, without the thread around
    them: tools/bench drives them directly.
*/

import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
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

QUERY_MAX :: 4096

// What to search for. Copied whole between threads.
Search_Query :: struct {
	text:      [QUERY_MAX]u8,
	text_len:  int,
	mode:      Mode,
	k:         int,
	idx:       ^Index,
	rules_ver: int,
}

query_text :: proc(q: ^Search_Query) -> string {
	return string(q.text[:q.text_len])
}

// ---------------------------------------------------------------------------
// The engine
// ---------------------------------------------------------------------------

Search_State :: struct {
	q:        Search_Query,
	pattern:  fuzzy.Pattern,
	cursor:   int, // files below this have been claimed by some round
	skipped:  [dynamic]u32, // files passed while still being read: try again
	top:      fuzzy.Top,
	top_buf:  []fuzzy.Ranked, // owned
	matched:  int,
	busy:     Busy, // time each worker slot spent working, for the panel
	// Per-worker scratch, kept between rounds.
	w_skip:   [MAX_WORKERS][dynamic]u32,
	w_top:    [MAX_WORKERS][]fuzzy.Ranked,
}

search_state_destroy :: proc(st: ^Search_State) {
	delete(st.skipped)
	delete(st.top_buf)
	for i in 0 ..< MAX_WORKERS {
		delete(st.w_skip[i])
		delete(st.w_top[i])
	}
	st^ = {}
}

search_reset :: proc(st: ^Search_State, q: ^Search_Query) {
	st.q = q^
	st.pattern = fuzzy.parse(query_text(q))
	st.cursor = 0
	st.matched = 0
	clear(&st.skipped)
	if len(st.top_buf) != q.k {
		delete(st.top_buf)
		st.top_buf = make([]fuzzy.Ranked, q.k)
		for i in 0 ..< MAX_WORKERS {
			delete(st.w_top[i])
			st.w_top[i] = make([]fuzzy.Ranked, q.k)
		}
	}
	fuzzy.top_init(&st.top, st.top_buf)
}

SEARCH_ROUND :: 30 * time.Millisecond

// Search for up to `budget`. `cancel` is checked between files: when it no
// longer equals `cancel_id`, the round stops and its results mean nothing.
// Returns whether any file was processed, and whether the search is complete
// (the whole index is read and every file searched).
search_round :: proc(st: ^Search_State, budget: time.Duration, cancel: ^int = nil, cancel_id := 0) -> (progressed, complete: bool) {
	idx := st.q.idx
	if idx == nil do return false, true
	// Read BEFORE the count: if the index was done then, the count is final.
	idx_done := index_done(idx)
	end := index_count(idx)

	job := Search_Job {
		st        = st,
		idx       = idx,
		skipped   = st.skipped[:],
		start     = st.cursor,
		end       = end,
		started   = time.tick_now(),
		budget    = budget,
		cancel    = cancel,
		cancel_id = cancel_id,
	}
	work := len(st.skipped) + (end - st.cursor)
	if work == 0 {
		return false, idx_done
	}
	n := clamp(work / 8, 1, worker_count())
	for w in 0 ..< n {
		clear(&st.w_skip[w])
		fuzzy.top_init(&job.tops[w], st.w_top[w])
	}
	parallel(n, &job, search_worker, &st.busy)

	// What the round got through. Claims are numbered: skipped files first,
	// then new ones; every claim below the final count was finished.
	claimed := sync.atomic_load(&job.next)
	skip_done := min(claimed, len(st.skipped))
	new_done := min(max(0, claimed - len(st.skipped)), end - st.cursor)

	// Skipped files not reached this round stay on the list, ahead of the
	// ones the workers passed over.
	rest := st.skipped[skip_done:]
	keep := make([dynamic]u32, 0, len(rest), context.temp_allocator)
	append(&keep, ..rest)
	clear(&st.skipped)
	append(&st.skipped, ..keep[:])
	for w in 0 ..< n do append(&st.skipped, ..st.w_skip[w][:])
	st.cursor += new_done

	for w in 0 ..< n {
		st.matched += job.matched[w]
		fuzzy.top_merge(&st.top, &job.tops[w])
	}
	progressed = skip_done + new_done > 0
	complete = idx_done && st.cursor >= end && len(st.skipped) == 0
	return
}

@(private = "file")
Search_Job :: struct {
	st:        ^Search_State,
	idx:       ^Index,
	skipped:   []u32,
	start:     int,
	end:       int,
	next:      int, // atomic claim counter
	started:   time.Tick,
	budget:    time.Duration,
	cancel:    ^int,
	cancel_id: int,
	tops:      [MAX_WORKERS]fuzzy.Top,
	matched:   [MAX_WORKERS]int,
}

@(private = "file")
cancelled :: #force_inline proc(job: ^Search_Job) -> bool {
	return job.cancel != nil && sync.atomic_load(job.cancel) != job.cancel_id
}

@(private = "file")
search_worker :: proc(data: rawptr, worker: int) {
	job := (^Search_Job)(data)
	st := job.st
	top := &job.tops[worker]
	buf: [CANDIDATE_MAX]u8
	matched := 0
	empty := fuzzy.is_empty(&st.pattern)
	defer job.matched[worker] = matched

	for time.tick_since(job.started) < job.budget && !cancelled(job) {
		c := sync.atomic_add(&job.next, 1)
		fi: int
		if c < len(job.skipped) {
			fi = int(job.skipped[c])
		} else {
			fi = job.start + (c - len(job.skipped))
			if fi >= job.end do break
		}
		f := index_file(job.idx, fi)
		state := file_state(f)
		if state == .Pending {
			// Still being read: come back to it next round.
			append(&st.w_skip[worker], u32(fi))
			continue
		}
		if file_hidden(f) do continue

		switch st.q.mode {
		case .Files:
			if empty {
				matched += 1
				fuzzy.top_push(top, {item = u32(fi)})
				continue
			}
			text, _ := candidate(job.idx, .Files, fi, 0, buf[:])
			score, ok, _ := fuzzy.match(&st.pattern, text)
			if !ok do continue
			matched += 1
			fuzzy.top_push(top, {score = i32(score), length = u32(len(text)), item = u32(fi)})
		case .Content:
			if state != .Text do continue
			for line, k in f.items {
				// A file can be large: look up now and then.
				if k & 4095 == 4095 && cancelled(job) do return
				if empty {
					matched += 1
					fuzzy.top_push(top, {item = u32(fi), line = line})
					continue
				}
				if !fuzzy.could_match(&st.pattern, transmute([]u8)f.rel, transmute([]u8)line_text(f, int(line))) do continue
				text, _ := candidate(job.idx, .Content, fi, int(line), buf[:])
				score, ok, _ := fuzzy.match(&st.pattern, text)
				if !ok do continue
				matched += 1
				fuzzy.top_push(top, {score = i32(score), length = u32(len(text)), item = u32(fi), line = line})
			}
		}
	}
}

CANDIDATE_MAX :: 2048

// Build the text a result is matched against into `buf`: "path" in files
// mode, "path:line: text" in content mode. Returns the slice used, and how
// many bytes of it are the "path:line: " prefix.
candidate :: proc(idx: ^Index, mode: Mode, file: int, line: int, buf: []u8) -> (text: []u8, prefix: int) {
	n := 0
	put :: #force_inline proc(buf: []u8, n: ^int, s: string) {
		k := min(len(s), len(buf) - n^)
		copy(buf[n^:], s[:k])
		n^ += k
	}
	f := index_file(idx, file)
	put(buf, &n, f.rel)
	if mode == .Files do return buf[:n], n
	put(buf, &n, ":")
	num: [16]u8
	put(buf, &n, strconv.write_int(num[:], i64(line) + 1, 10))
	// ": " rather than ":" - the space makes the start of the line a word
	// boundary as strong as any other, so `game_update :: proc` is not
	// out-ranked by a comment that merely mentions it.
	put(buf, &n, ": ")
	prefix = n
	if file_state(f) == .Text do put(buf, &n, line_text(f, line))
	return buf[:n], prefix
}

// ---------------------------------------------------------------------------
// The thread
// ---------------------------------------------------------------------------

// What the search thread last published.
Search_Results :: struct {
	items:    [dynamic]fuzzy.Ranked,
	matched:  int,
	complete: bool, // the whole index searched for this request
	id:       int, // the request these answer
	mode:     Mode,
	gen:      int, // the index generation they point into
	stamp:    int,
}

Searcher :: struct {
	mu:          sync.Mutex,
	cv:          sync.Cond,
	want:        Search_Query, // guarded by mu
	want_id:     int, // guarded by mu
	cancel_id:   int, // atomic copy of want_id, read by the workers
	quit:        bool, // guarded by mu
	using_idx:   ^Index, // the index the thread is reading; guarded by mu
	out:         Search_Results, // guarded by mu
	busy_ns:     [MAX_WORKERS]i64, // atomic, for the panel
	workers:     int, // atomic: slots used by the last round
	thread:      ^thread.Thread,
}

searcher_start :: proc(s: ^Searcher) {
	s.want_id = 0
	s.thread = thread.create_and_start_with_poly_data(s, searcher_thread)
}

// Ask for a search. Cheap; never waits for the search.
searcher_post :: proc(s: ^Searcher, q: ^Search_Query) -> (id: int) {
	sync.lock(&s.mu)
	s.want = q^
	s.want_id += 1
	id = s.want_id
	sync.atomic_store(&s.cancel_id, id)
	sync.cond_signal(&s.cv)
	sync.unlock(&s.mu)
	return
}

// Copy out the latest results if they changed since `have_stamp`.
searcher_fetch :: proc(s: ^Searcher, into: ^Search_Results) -> bool {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	if s.out.stamp == into.stamp do return false
	clear(&into.items)
	append(&into.items, ..s.out.items[:])
	into.matched = s.out.matched
	into.complete = s.out.complete
	into.id = s.out.id
	into.mode = s.out.mode
	into.gen = s.out.gen
	into.stamp = s.out.stamp
	return true
}

// Is the search thread still holding on to this index?
searcher_uses :: proc(s: ^Searcher, idx: ^Index) -> bool {
	sync.lock(&s.mu)
	defer sync.unlock(&s.mu)
	return s.using_idx == idx || s.want.idx == idx
}

searcher_stop :: proc(s: ^Searcher) {
	sync.lock(&s.mu)
	s.quit = true
	sync.atomic_store(&s.cancel_id, -1)
	sync.cond_signal(&s.cv)
	sync.unlock(&s.mu)
	thread.join(s.thread)
	thread.destroy(s.thread)
	delete(s.out.items)
}

@(private = "file")
searcher_thread :: proc(s: ^Searcher) {
	thread_lower_priority()
	st: Search_State
	defer search_state_destroy(&st)
	cur_id := 0
	complete := true
	for {
		sync.lock(&s.mu)
		if s.quit {
			s.using_idx = nil
			sync.unlock(&s.mu)
			break
		}
		fresh := s.want_id != cur_id
		if fresh {
			cur_id = s.want_id
			search_reset(&st, &s.want)
			s.using_idx = st.q.idx
			complete = false
		} else if complete {
			// Nothing to do until a new request: sleep, but look up now and
			// then in case one was missed.
			sync.cond_wait_with_timeout(&s.cv, &s.mu, 200 * time.Millisecond)
			sync.unlock(&s.mu)
			continue
		}
		sync.unlock(&s.mu)

		before := st.busy
		progressed: bool
		progressed, complete = search_round(&st, SEARCH_ROUND, &s.cancel_id, cur_id)
		for i in 0 ..< MAX_WORKERS do if st.busy[i] != before[i] {
			sync.atomic_add(&s.busy_ns[i], i64(st.busy[i] - before[i]))
		}
		if sync.atomic_load(&s.cancel_id) != cur_id do continue // a newer request: start that

		sync.lock(&s.mu)
		clear(&s.out.items)
		append(&s.out.items, ..st.top.items[:st.top.n])
		s.out.matched = st.matched
		s.out.complete = complete
		s.out.id = cur_id
		s.out.mode = st.q.mode
		s.out.gen = st.q.idx != nil ? st.q.idx.generation : 0
		s.out.stamp += 1
		sync.unlock(&s.mu)

		// Waiting for files still being read: do not spin.
		if !progressed && !complete do time.sleep(5 * time.Millisecond)
		free_all(context.temp_allocator)
	}
}

// ---------------------------------------------------------------------------

// Where the matched characters fall in a result, for highlighting. Run on
// the main thread with the main thread's own copy of the pattern.
match_positions :: proc(pattern: ^fuzzy.Pattern, idx: ^Index, mode: Mode, file: int, line: int, out: []int) -> (text: string, prefix: int, n: int) {
	buf := make([]u8, CANDIDATE_MAX, context.temp_allocator)
	t, p := candidate(idx, mode, file, line, buf)
	_, _, n = fuzzy.match(pattern, t, out)
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
