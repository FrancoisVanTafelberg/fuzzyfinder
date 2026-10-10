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
        workers check it as they go, so the old search stops within a few
        thousand lines and the new one starts;
      - while the index is still being built the search keeps going over
        whatever has been read, and catches up as more arrives;
      - every round (SEARCH_ROUND, a few tens of ms) it publishes the best so
        far, so results appear while a big search is still running.

    A round is split over the cores (parallel.odin). The work is laid out as
    UNITS of at most SEARCH_SPLIT lines - a big file is several units, so all
    the cores share it - and each worker claims the next unit and keeps its
    own best-K; they are merged when the round ends. Files passed over
    earlier because they were still being read come first.

    THE RARE-CHARACTER SCAN. Whatever of the query a file's path cannot
    supply must be on the line itself. So each unit scans the file text for
    the rarest such character (scan.odin, 32 bytes at a time) and scores only
    the lines it turns up on. A character on most lines makes the scan pure
    overhead, so after a few hundred dense hits it goes line by line instead.

    NARROWING. A finished search keeps the list of what it matched. When the
    next query can only match a subset of that (it extends the last term or
    adds terms - see `narrows`), the search goes over that list instead of
    the files. The same query again reuses its finished results outright.

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

// A line found by a search: kept so the next, narrower query can look only
// at these (NARROWING, at the top).
Match :: struct {
	file: u32,
	line: u32,
}

// Files still to search: items from ..< to of `file`, to = TO_END for all of
// it (a file not read yet has no item count).
@(private = "file")
Range :: struct {
	file: u32,
	from: u32,
	to:   u32,
}

@(private = "file")
TO_END :: max(u32)

// One worker's piece of a round: part of a file, or part of the match list
// being narrowed.
@(private = "file")
Unit_Kind :: enum u8 {
	Skipped, // a file passed over earlier because it was still being read
	List, // list[from ..< to]
	File, // a file not searched yet
}

@(private = "file")
Unit :: struct {
	using r: Range,
	kind:    Unit_Kind,
}

// Lines per unit: a big file is split, so all the cores share it.
SEARCH_SPLIT :: 16384
// The most units laid out per round. More than any round gets through.
@(private = "file")
UNITS_MAX :: 1 << 16

// The longest match list kept for narrowing, and how many lists.
FOUND_MAX :: 4 << 20
CACHE_SLOTS :: 8

@(private = "file")
Cache_Entry :: struct {
	used:    bool,
	pattern: fuzzy.Pattern,
	mode:    Mode,
	gen:     int,
	covered: int, // files below this are covered by `matches`
	stamp:   int, // last used, for eviction
	matches: [dynamic]Match,
	// The finished results, for the same query asked again (typed back to,
	// or a trailing space): no search at all.
	top:     []fuzzy.Ranked,
	matched: int,
}

Search_State :: struct {
	q:           Search_Query,
	pattern:     fuzzy.Pattern,
	cursor:      int, // files below this have been laid out in some round...
	cursor_item: u32, // ...and of file `cursor`, the items below this
	skipped:     [dynamic]Range, // passed while still being read: try again
	list:        []Match, // narrowing: the earlier query's matches, searched instead of files below `covered`
	list_pos:    int,
	narrowed:    bool, // this search narrows an earlier one (tools/bench reports it)
	units:       [dynamic]Unit,
	top:         fuzzy.Top,
	top_buf:     []fuzzy.Ranked, // owned
	matched:     int,
	busy:        Busy, // time each worker slot spent working, for the panel
	found:       [dynamic]Match, // every match so far, while `collecting`
	collecting:  bool,
	cache:       [CACHE_SLOTS]Cache_Entry,
	clock:       int,
	// Per-worker scratch, kept between rounds.
	w_skip:      [MAX_WORKERS][dynamic]Range,
	w_top:       [MAX_WORKERS][]fuzzy.Ranked,
	w_found:     [MAX_WORKERS][dynamic]Match,
}

search_state_destroy :: proc(st: ^Search_State) {
	delete(st.skipped)
	delete(st.units)
	delete(st.top_buf)
	delete(st.found)
	for &e in st.cache do cache_drop(&e)
	for i in 0 ..< MAX_WORKERS {
		delete(st.w_skip[i])
		delete(st.w_top[i])
		delete(st.w_found[i])
	}
	st^ = {}
}

@(private = "file")
cache_drop :: proc(e: ^Cache_Entry) {
	delete(e.matches)
	delete(e.top)
	e^ = {}
}

search_reset :: proc(st: ^Search_State, q: ^Search_Query) {
	st.q = q^
	st.pattern = fuzzy.parse(query_text(q))
	st.cursor = 0
	st.cursor_item = 0
	st.matched = 0
	clear(&st.skipped)
	clear(&st.found)
	st.collecting = !fuzzy.is_empty(&st.pattern)
	st.list = nil
	st.list_pos = 0
	st.narrowed = false

	// Lists from another index are no use: drop them.
	gen := q.idx != nil ? q.idx.generation : -1
	for &e in st.cache do if e.used && e.gen != gen do cache_drop(&e)

	if len(st.top_buf) != q.k {
		delete(st.top_buf)
		st.top_buf = make([]fuzzy.Ranked, q.k)
		for i in 0 ..< MAX_WORKERS {
			delete(st.w_top[i])
			st.w_top[i] = make([]fuzzy.Ranked, q.k)
		}
	}
	fuzzy.top_init(&st.top, st.top_buf)

	// An earlier query this one narrows: search its matches instead of the
	// files they cover - the shortest such list. The same query again: its
	// results as they were.
	if st.collecting {
		best := -1
		for &e, i in st.cache {
			if !e.used || e.mode != q.mode || !narrows(&e.pattern, &st.pattern) do continue
			if narrows(&st.pattern, &e.pattern) && len(e.top) == q.k {
				copy(st.top_buf, e.top)
				st.top.n = min(e.matched, q.k)
				st.matched = e.matched
				st.cursor = e.covered
				st.collecting = false // already cached
				st.clock += 1
				e.stamp = st.clock
				st.narrowed = true
				return
			}
			if best < 0 || len(e.matches) < len(st.cache[best].matches) do best = i
		}
		if best >= 0 {
			e := &st.cache[best]
			st.list = e.matches[:]
			st.cursor = e.covered
			st.clock += 1
			e.stamp = st.clock
			st.narrowed = true
		}
	}
}

// Does every line `new` matches also match `old`? Then a search for `new`
// only needs to look at what `old` found. True when `new` is `old` with its
// last term extended (typed on) and/or more terms after it - except where an
// extension can WIDEN the match: a longer "!term" excludes less, and "abc$"
// typed on is no longer anchored to the end.
narrows :: proc(old, new: ^fuzzy.Pattern) -> bool {
	same :: proc(a, b: ^fuzzy.Term) -> bool {
		if a.kind != b.kind || a.case_sensitive != b.case_sensitive || a.len != b.len do return false
		for j in 0 ..< a.len do if a.text[j] != b.text[j] do return false
		return true
	}
	if old.n == 0 || new.n < old.n do return false
	for i in 0 ..< old.n - 1 do if !same(&old.terms[i], &new.terms[i]) do return false
	l := &old.terms[old.n - 1]
	n := &new.terms[old.n - 1]
	if same(l, n) do return true
	if l.kind == .Negate || l.kind == .Suffix || n.kind == .Negate do return false
	// A fuzzy term is implied by any term that contains its text in order;
	// an exact or prefix term only by one of its own kind.
	if l.kind != .Fuzzy && n.kind != l.kind do return false
	if n.len < l.len || (l.case_sensitive && !n.case_sensitive) do return false
	for j in 0 ..< l.len {
		c := n.text[j]
		if !l.case_sensitive do c = fuzzy.fold(c)
		if c != l.text[j] do return false
	}
	return true
}

// A finished search's matches, kept for narrowing. Takes `found`.
@(private = "file")
cache_put :: proc(st: ^Search_State) {
	gen := st.q.idx.generation
	slot := -1
	for &e, i in st.cache {
		// The same query again (typed back to): replace it.
		if e.used && e.mode == st.q.mode && e.gen == gen && narrows(&e.pattern, &st.pattern) && narrows(&st.pattern, &e.pattern) {
			cache_drop(&e)
		}
		if !e.used && slot < 0 do slot = i
	}
	if slot < 0 {
		slot = 0
		for e, i in st.cache do if e.stamp < st.cache[slot].stamp do slot = i
		cache_drop(&st.cache[slot])
	}
	st.clock += 1
	st.cache[slot] = {
		used    = true,
		pattern = st.pattern,
		mode    = st.q.mode,
		gen     = gen,
		covered = st.cursor,
		stamp   = st.clock,
		matches = st.found,
		top     = slice.clone(st.top_buf),
		matched = st.matched,
	}
	st.found = {}
	st.list = nil // it may have just been dropped
}

SEARCH_ROUND :: 30 * time.Millisecond

// Search for up to `budget`. `cancel` is checked as the work goes: when it no
// longer equals `cancel_id`, the round stops and its results mean nothing.
// Returns whether anything was searched, and whether the search is complete
// (the whole index is read and every file searched).
search_round :: proc(st: ^Search_State, budget: time.Duration, cancel: ^int = nil, cancel_id := 0) -> (progressed, complete: bool) {
	idx := st.q.idx
	if idx == nil do return false, true
	// Read BEFORE the count: if the index was done then, the count is final.
	idx_done := index_done(idx)
	end := index_count(idx)

	// Lay the round's work out: files passed over earlier, then the list
	// being narrowed, then files not searched yet.
	clear(&st.units)
	si := 0
	for si < len(st.skipped) && len(st.units) < UNITS_MAX {
		add_units(st, st.skipped[si], .Skipped)
		si += 1
	}
	lp := st.list_pos
	for lp < len(st.list) && len(st.units) < UNITS_MAX {
		b := min(lp + SEARCH_SPLIT, len(st.list))
		append(&st.units, Unit{r = {from = u32(lp), to = u32(b)}, kind = .List})
		lp = b
	}
	cf, ci := st.cursor, st.cursor_item
	for cf < end && len(st.units) < UNITS_MAX {
		add_units(st, {u32(cf), ci, TO_END}, .File)
		cf += 1
		ci = 0
	}
	if len(st.units) == 0 {
		st.cursor, st.cursor_item = cf, ci
		complete = idx_done && st.cursor >= end && len(st.skipped) == 0 && st.list_pos >= len(st.list)
		if complete && st.collecting do cache_put(st)
		return false, complete
	}

	job := Search_Job {
		st        = st,
		idx       = idx,
		units     = st.units[:],
		started   = time.tick_now(),
		budget    = budget,
		cancel    = cancel,
		cancel_id = cancel_id,
	}
	n := clamp(len(st.units) / 8, 1, worker_count())
	for w in 0 ..< n {
		clear(&st.w_skip[w])
		clear(&st.w_found[w])
		fuzzy.top_init(&job.tops[w], st.w_top[w])
	}
	parallel(n, &job, search_worker, &st.busy)
	if cancelled(&job) do return false, false

	// Every unit claimed was finished, and claims go in order: what is left
	// is units[claimed:], and whatever was not laid out.
	claimed := min(sync.atomic_load(&job.next), len(st.units))
	keep := make([dynamic]Range, 0, 16, context.temp_allocator)
	next_list := lp
	next_cf, next_ci := cf, ci
	seen_list, seen_file := false, false
	for u in st.units[claimed:] {
		switch u.kind {
		case .Skipped:
			append(&keep, u.r)
		case .List:
			if !seen_list do next_list = int(u.from)
			seen_list = true
		case .File:
			if !seen_file {
				next_cf, next_ci = int(u.file), u.from
				seen_file = true
			}
		}
	}
	append(&keep, ..st.skipped[si:])
	for w in 0 ..< n do append(&keep, ..st.w_skip[w][:])
	clear(&st.skipped)
	append(&st.skipped, ..keep[:])
	st.list_pos = next_list
	st.cursor, st.cursor_item = next_cf, next_ci

	for w in 0 ..< n {
		st.matched += job.matched[w]
		fuzzy.top_merge(&st.top, &job.tops[w])
		if st.collecting {
			if len(st.found) + len(st.w_found[w]) > FOUND_MAX {
				// Too many to be worth keeping: this one will not be narrowed.
				st.collecting = false
				delete(st.found)
				st.found = {}
			} else {
				append(&st.found, ..st.w_found[w][:])
			}
		}
	}
	progressed = claimed > 0
	complete = idx_done && st.cursor >= end && len(st.skipped) == 0 && st.list_pos >= len(st.list)
	if complete && st.collecting do cache_put(st)
	return
}

// The units for (part of) one file.
@(private = "file")
add_units :: proc(st: ^Search_State, r: Range, kind: Unit_Kind) {
	f := index_file(st.q.idx, int(r.file))
	if st.q.mode == .Files || file_state(f) != .Text {
		append(&st.units, Unit{r = r, kind = kind})
		return
	}
	to := r.to == TO_END ? u32(len(f.items)) : r.to
	for a := r.from; a < to; a += SEARCH_SPLIT {
		append(&st.units, Unit{r = {r.file, a, min(a + SEARCH_SPLIT, to)}, kind = kind})
	}
}

@(private = "file")
Search_Job :: struct {
	st:        ^Search_State,
	idx:       ^Index,
	units:     []Unit,
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

// One worker's view of the round.
@(private = "file")
Worker :: struct {
	job:     ^Search_Job,
	st:      ^Search_State,
	w:       int,
	top:     ^fuzzy.Top,
	matched: int,
	buf:     [CANDIDATE_MAX]u8,
	stop:    bool,
}

@(private = "file")
search_worker :: proc(data: rawptr, worker: int) {
	job := (^Search_Job)(data)
	wk := Worker {
		job = job,
		st  = job.st,
		w   = worker,
		top = &job.tops[worker],
	}
	defer job.matched[worker] = wk.matched

	for !wk.stop && time.tick_since(job.started) < job.budget && !cancelled(job) {
		c := sync.atomic_add(&job.next, 1)
		if c >= len(job.units) do break
		u := job.units[c]
		if u.kind == .List {
			search_list(&wk, u.from, u.to)
		} else {
			search_file(&wk, u.r)
		}
	}
}

@(private = "file")
found :: #force_inline proc(wk: ^Worker, score: int, length: int, file: int, line: u32) {
	wk.matched += 1
	fuzzy.top_push(wk.top, {score = i32(score), length = u32(length), item = u32(file), line = line})
	if wk.st.collecting do append(&wk.st.w_found[wk.w], Match{u32(file), line})
}

// Match a file's path (files mode).
@(private = "file")
check_path :: proc(wk: ^Worker, fi: int) {
	if fuzzy.is_empty(&wk.st.pattern) {
		found(wk, 0, 0, fi, 0)
		return
	}
	text, _ := candidate(wk.job.idx, .Files, fi, 0, wk.buf[:])
	score, ok, _ := fuzzy.match(&wk.st.pattern, text)
	if ok do found(wk, score, len(text), fi, 0)
}

// Match one line (content mode).
@(private = "file")
check_line :: #force_inline proc(wk: ^Worker, f: ^File, fi: int, line: int) {
	if !fuzzy.could_match(&wk.st.pattern, transmute([]u8)f.rel, transmute([]u8)line_text(f, line)) do return
	text, _ := candidate(wk.job.idx, .Content, fi, line, wk.buf[:])
	score, ok, _ := fuzzy.match(&wk.st.pattern, text)
	if ok do found(wk, score, len(text), fi, u32(line))
}

@(private = "file")
search_file :: proc(wk: ^Worker, r: Range) {
	fi := int(r.file)
	f := index_file(wk.job.idx, fi)
	if file_hidden(f) do return
	if wk.st.q.mode == .Files {
		check_path(wk, fi) // the path is known before the file is read
		return
	}
	state := file_state(f)
	if state == .Pending {
		// Still being read: come back to it next round.
		append(&wk.st.w_skip[wk.w], Range{r.file, 0, TO_END})
		return
	}
	if state != .Text do return
	to := r.to == TO_END ? len(f.items) : int(r.to)
	from := int(r.from)
	if from >= to do return

	if fuzzy.is_empty(&wk.st.pattern) {
		for k in from ..< to do found(wk, 0, 0, fi, f.items[k])
		return
	}

	// PREFILTER. Whatever of the query the path cannot supply has to be in
	// the line itself, so lines without that query's rarest such character
	// cannot match. Scan the file text for that character - 32 bytes at a
	// time - and look only at the lines it turns up in. A query whose
	// letters are all in the path falls back to every line.
	c, fold, ok := rarest_needed(&wk.st.pattern, f.rel)
	if !ok {
		for k in from ..< to {
			if k & 4095 == 4095 && cancelled(wk.job) {
				wk.stop = true
				return
			}
			check_line(wk, f, fi, int(f.items[k]))
		}
		return
	}
	lo := int(f.items[from])
	hi := int(f.items[to - 1]) + 1 // lines lo ..< hi
	first := lo
	pos := int(f.lines[lo])
	stop_at := hi < len(f.lines) ? int(f.lines[hi]) : len(f.data)
	hits := 0
	for pos < stop_at {
		k := fold ? find_letter_fold(f.data[pos:stop_at], c) : find_byte(f.data[pos:stop_at], c)
		if k < 0 do break
		line := line_of(f, pos + k, lo, hi)
		check_line(wk, f, fi, line)
		lo = line + 1
		pos = lo < len(f.lines) ? int(f.lines[lo]) : stop_at
		hits += 1
		if hits & 1023 == 0 && cancelled(wk.job) {
			wk.stop = true
			return
		}
		// The character is on most lines: the scan only adds work. Go
		// through the rest line by line.
		if hits == 256 && lo - first < 4 * hits {
			// The first item at or after line `lo`.
			a, b := from, to
			for a < b {
				mid := (a + b) / 2
				if int(f.items[mid]) < lo do a = mid + 1
				else do b = mid
			}
			for j in a ..< to {
				if j & 4095 == 4095 && cancelled(wk.job) {
					wk.stop = true
					return
				}
				check_line(wk, f, fi, int(f.items[j]))
			}
			return
		}
	}
}

// Of the characters the path cannot supply to the query's terms, the rarest:
// every matching line contains it. Only terms could_match checks count.
@(private = "file")
rarest_needed :: proc(p: ^fuzzy.Pattern, path: string) -> (c: u8, fold: bool, ok: bool) {
	best := max(int)
	for ti in 0 ..< p.n {
		t := &p.terms[ti]
		if t.kind == .Negate || !t.checkable do continue
		pat := t.text[:t.len]
		pi := 0
		for b in transmute([]u8)path {
			if (t.case_sensitive ? b : fuzzy.fold(b)) == pat[pi] {
				pi += 1
				if pi == len(pat) do break
			}
		}
		for j in pi ..< len(pat) {
			ch := pat[j]
			r := char_rarity(ch)
			if r < best {
				best = r
				c = ch
				fold = !t.case_sensitive && ch >= 'a' && ch <= 'z'
				ok = true
			}
		}
	}
	return
}

// Narrowing: the lines (or files) an earlier query matched.
@(private = "file")
search_list :: proc(wk: ^Worker, from, to: u32) {
	list := wk.st.list
	for i in from ..< to {
		if i & 4095 == 4095 && cancelled(wk.job) {
			wk.stop = true
			return
		}
		m := list[i]
		fi := int(m.file)
		f := index_file(wk.job.idx, fi)
		if file_hidden(f) do continue
		if wk.st.q.mode == .Files {
			check_path(wk, fi)
		} else {
			check_line(wk, f, fi, int(m.line))
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
