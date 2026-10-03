package fuzzy

/*
    The matcher. Pure: no raylib, no allocation in the hot path, so it can be
    tested headless (`odin test source/fuzzy`) and run on worker threads.

    THE SCORING IS FZF'S, because the old ff handed every keystroke to fzf and
    the rankings people are used to are fzf's rankings. This is its "v1"
    algorithm:

      1. Forward scan: find the first place every pattern character appears in
         order. No match -> rejected, and this is the only cost most
         candidates ever pay.
      2. Backward scan from that end: find the LATEST start that still matches,
         which gives the shortest window ending there.
      3. Score the window: 16 per matched character, a bonus for landing on a
         word boundary / camelCase hump / after a path separator, a bonus for
         runs of consecutive matches, and a penalty for gaps.

    The first character's bonus counts double, which is why "fo" ranks
    "foo.odin" above "info.odin".

    THE QUERY LANGUAGE is fzf's extended mode, trimmed to what earns its keep:

        abc      fuzzy
        'abc     exact substring
        !abc     must NOT contain (exact)
        ^abc     starts with (exact)
        abc$     ends with (exact)
        "a b c"  exact phrase, spaces and all (the closing quote is optional,
                 so a phrase still being typed already searches)
        !"a b"   must NOT contain the phrase

    Space-separated terms must ALL match; their scores add up. Smart case per
    term: all-lowercase matches any case, a capital makes the term exact-case.
*/

SCORE_MATCH :: 16
SCORE_GAP_START :: -3
SCORE_GAP_EXTENSION :: -1
BONUS_BOUNDARY :: SCORE_MATCH / 2 // 8
BONUS_NON_WORD :: SCORE_MATCH / 2 // 8
BONUS_CAMEL :: BONUS_BOUNDARY + SCORE_GAP_EXTENSION // 7
BONUS_CONSECUTIVE :: -(SCORE_GAP_START + SCORE_GAP_EXTENSION) // 4
BONUS_FIRST_CHAR_MULTIPLIER :: 2
BONUS_BOUNDARY_WHITE :: BONUS_BOUNDARY + 2
BONUS_BOUNDARY_DELIMITER :: BONUS_BOUNDARY + 1

MAX_TERMS :: 16
// Long enough for a pasted path or log line; a longer term is cut here and
// still matches by its first MAX_TERM_LEN bytes.
MAX_TERM_LEN :: 512
// The most positions `match` can report. A pattern longer than this still
// matches; only the highlighting stops.
MAX_POSITIONS :: 256

// Non_Word first, so it is the zero value and the default for any byte the
// table below does not list (punctuation).
Char_Class :: enum u8 {
	Non_Word,
	White,
	Delimiter,
	Lower,
	Upper,
	Letter, // non-ASCII: treated as a word character
	Number,
}

Term_Kind :: enum u8 {
	Fuzzy,
	Exact,
	Prefix,
	Suffix,
	Negate,
}

Term :: struct {
	kind:           Term_Kind,
	case_sensitive: bool,
	// No digit, ':' or space in it: see could_match.
	checkable:      bool,
	len:            int,
	text:           [MAX_TERM_LEN]u8, // folded to lower case unless case_sensitive
}

Pattern :: struct {
	terms: [MAX_TERMS]Term,
	n:     int,
}

@(rodata)
CLASS_TABLE := #partial [256]Char_Class {
	' '  = .White,
	'\t' = .White,
	'\n' = .White,
	'\r' = .White,
	'/'  = .Delimiter,
	'\\' = .Delimiter,
	':'  = .Delimiter,
	';'  = .Delimiter,
	','  = .Delimiter,
	'|'  = .Delimiter,
}

char_class :: #force_inline proc "contextless" (c: u8) -> Char_Class {
	switch {
	case c >= 'a' && c <= 'z':
		return .Lower
	case c >= 'A' && c <= 'Z':
		return .Upper
	case c >= '0' && c <= '9':
		return .Number
	case c >= 0x80:
		return .Letter
	}
	return CLASS_TABLE[c]
}

fold :: #force_inline proc "contextless" (c: u8) -> u8 {
	return c >= 'A' && c <= 'Z' ? c + 32 : c
}

is_word :: #force_inline proc "contextless" (c: Char_Class) -> bool {
	return c >= .Lower
}

// fzf's bonus for matching a character of class `cur` that follows `prev`.
bonus_for :: #force_inline proc "contextless" (prev, cur: Char_Class) -> int {
	if is_word(cur) {
		#partial switch prev {
		case .White:
			return BONUS_BOUNDARY_WHITE
		case .Delimiter:
			return BONUS_BOUNDARY_DELIMITER
		case .Non_Word:
			return BONUS_BOUNDARY
		}
	}
	if (prev == .Lower && cur == .Upper) || (prev != .Number && cur == .Number) {
		return BONUS_CAMEL
	}
	#partial switch cur {
	case .Non_Word, .Delimiter:
		return BONUS_NON_WORD
	case .White:
		return BONUS_BOUNDARY_WHITE
	}
	return 0
}

// Split a query into terms. Pure; the Pattern is a value with no pointers, so
// worker threads can each be handed a copy.
parse :: proc(query: string) -> (p: Pattern) {
	i := 0
	for i < len(query) && p.n < MAX_TERMS {
		for i < len(query) && query[i] == ' ' do i += 1
		if i >= len(query) do break

		t: Term
		word: string
		// "a phrase" or !"a phrase": everything up to the closing quote,
		// spaces included, matched exactly.
		q := i
		if query[q] == '!' && q + 1 < len(query) && query[q + 1] == '"' do q += 1
		if query[q] == '"' {
			t.kind = q > i ? .Negate : .Exact
			start := q + 1
			end := start
			for end < len(query) && query[end] != '"' do end += 1
			word = query[start:end]
			i = min(end + 1, len(query))
		} else {
			start := i
			for i < len(query) && query[i] != ' ' do i += 1
			word = query[start:i]
		}
		if len(word) == 0 do continue

		if t.kind == .Fuzzy do switch {
		case word[0] == '!':
			t.kind = .Negate
			word = word[1:]
		case word[0] == '\'':
			t.kind = .Exact
			word = word[1:]
		case word[0] == '^':
			t.kind = .Prefix
			word = word[1:]
		case len(word) > 1 && word[len(word) - 1] == '$':
			t.kind = .Suffix
			word = word[:len(word) - 1]
		}
		if len(word) == 0 do continue // a lone "!" or "'" is still being typed
		if len(word) > MAX_TERM_LEN do word = word[:MAX_TERM_LEN]

		t.checkable = true
		for c in transmute([]u8)word {
			if c >= 'A' && c <= 'Z' do t.case_sensitive = true
			if (c >= '0' && c <= '9') || c == ':' || c == ' ' do t.checkable = false
		}
		for c, j in transmute([]u8)word do t.text[j] = t.case_sensitive ? c : fold(c)
		t.len = len(word)
		p.terms[p.n] = t
		p.n += 1
	}
	return
}

is_empty :: proc "contextless" (p: ^Pattern) -> bool {
	return p.n == 0
}

// Score `text` against every term. ok is false if any term rejects it.
//
// `positions`, when given, receives the byte offsets of the matched
// characters (for highlighting), and `npos` how many were written. Leave it
// nil on the hot path; computing it costs nothing extra but the slice write.
match :: proc "contextless" (p: ^Pattern, text: []u8, positions: []int = nil) -> (score: int, ok: bool, npos: int) {
	if p.n == 0 do return 0, true, 0
	for ti in 0 ..< p.n {
		t := &p.terms[ti]
		pos_out: []int
		if positions != nil && npos < len(positions) do pos_out = positions[npos:]
		s, got, n := match_term(t, text, pos_out)
		if t.kind == .Negate {
			if got do return 0, false, 0
			continue
		}
		if !got do return 0, false, 0
		score += s
		npos += n
	}
	return score, true, npos
}

@(private)
eq :: #force_inline proc "contextless" (t: ^Term, c: u8, want: u8) -> bool {
	return (t.case_sensitive ? c : fold(c)) == want
}

match_term :: proc "contextless" (t: ^Term, text: []u8, positions: []int) -> (score: int, ok: bool, npos: int) {
	pat := t.text[:t.len]
	m := len(pat)
	n := len(text)
	if m == 0 do return 0, true, 0
	if m > n do return 0, false, 0

	switch t.kind {
	case .Fuzzy:
		// 1. forward: the first window that contains the pattern in order.
		pi := 0
		end := -1
		for i in 0 ..< n {
			if eq(t, text[i], pat[pi]) {
				pi += 1
				if pi == m {
					end = i + 1
					break
				}
			}
		}
		if end < 0 do return 0, false, 0
		// 2. backward: the latest start that still matches, ending at `end`.
		pi = m - 1
		start := 0
		for i := end - 1; i >= 0; i -= 1 {
			if eq(t, text[i], pat[pi]) {
				pi -= 1
				if pi < 0 {
					start = i
					break
				}
			}
		}
		s, np := score_window(t, text, start, end, positions)
		return s, true, np

	case .Exact, .Negate:
		// The best-scoring occurrence, not merely the first: "'main" should
		// prefer "main.odin" to "domain.odin".
		best := -1
		best_at := -1
		for i in 0 ..= n - m {
			hit := true
			for j in 0 ..< m {
				if !eq(t, text[i + j], pat[j]) {
					hit = false
					break
				}
			}
			if !hit do continue
			if t.kind == .Negate do return 0, true, 0
			s, _ := score_window(t, text, i, i + m, nil)
			if s > best {
				best = s
				best_at = i
			}
		}
		if best_at < 0 do return 0, false, 0
		s, np := score_window(t, text, best_at, best_at + m, positions)
		return s, true, np

	case .Prefix:
		// Leading whitespace is skipped, as fzf does, so ^func finds an
		// indented line.
		i := 0
		for i < n && (text[i] == ' ' || text[i] == '\t') do i += 1
		if n - i < m do return 0, false, 0
		for j in 0 ..< m do if !eq(t, text[i + j], pat[j]) do return 0, false, 0
		s, np := score_window(t, text, i, i + m, positions)
		return s, true, np

	case .Suffix:
		e := n
		for e > 0 && (text[e - 1] == ' ' || text[e - 1] == '\t' || text[e - 1] == '\r') do e -= 1
		if e < m do return 0, false, 0
		for j in 0 ..< m do if !eq(t, text[e - m + j], pat[j]) do return 0, false, 0
		s, np := score_window(t, text, e - m, e, positions)
		return s, true, np
	}
	return 0, false, 0
}

// fzf's calculateScore over text[start:end].
@(private)
score_window :: proc "contextless" (t: ^Term, text: []u8, start, end: int, positions: []int) -> (score: int, npos: int) {
	pat := t.text[:t.len]
	pi := 0
	in_gap := false
	consecutive := 0
	first_bonus := 0
	prev := start > 0 ? char_class(text[start - 1]) : Char_Class.White

	for i in start ..< end {
		c := text[i]
		class := char_class(c)
		if pi < len(pat) && eq(t, c, pat[pi]) {
			if npos < len(positions) {
				positions[npos] = i
				npos += 1
			}
			score += SCORE_MATCH
			bonus := bonus_for(prev, class)
			if consecutive == 0 {
				first_bonus = bonus
			} else {
				// A run keeps the bonus of the boundary it started on.
				if bonus >= BONUS_BOUNDARY && bonus > first_bonus do first_bonus = bonus
				bonus = max(bonus, first_bonus, BONUS_CONSECUTIVE)
			}
			score += pi == 0 ? bonus * BONUS_FIRST_CHAR_MULTIPLIER : bonus
			in_gap = false
			consecutive += 1
			pi += 1
		} else {
			score += in_gap ? SCORE_GAP_EXTENSION : SCORE_GAP_START
			in_gap = true
			consecutive = 0
			first_bonus = 0
		}
		prev = class
	}
	return
}

// A cheap NECESSARY condition for `match`, tested on two pieces of a
// candidate without joining them: each term's characters must appear in order
// across a then b. The search uses it on "path" and "text" before building
// "path:line: text", which is most of the cost of rejecting a line.
//
// What lies between the pieces (":123: ") is left out, so a term that could
// take characters from there - a digit or a ':' - is not checked here, and
// neither is a negation (which can only reject).
could_match :: proc "contextless" (p: ^Pattern, a, b: []u8) -> bool {
	for ti in 0 ..< p.n {
		t := &p.terms[ti]
		if t.kind == .Negate || !t.checkable do continue
		pat := t.text[:t.len]
		pi := 0
		for c in a {
			if eq(t, c, pat[pi]) {
				pi += 1
				if pi == len(pat) do break
			}
		}
		if pi < len(pat) {
			for c in b {
				if eq(t, c, pat[pi]) {
					pi += 1
					if pi == len(pat) do break
				}
			}
		}
		if pi < len(pat) do return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Ranking
// ---------------------------------------------------------------------------

// One ranked candidate. `item` is whatever the caller indexes by; `length` is
// the tiebreak (shorter wins, as in fzf), then the item index (earlier wins).
Ranked :: struct {
	score:  i32,
	length: u32,
	item:   u32,
}

better :: #force_inline proc "contextless" (a, b: Ranked) -> bool {
	if a.score != b.score do return a.score > b.score
	if a.length != b.length do return a.length < b.length
	return a.item < b.item
}

// The best K, kept sorted best first, in a buffer the caller owns (its
// length is K). Thousands deep, so the list can be paged through.
//
// Sorted insertion, found by binary search and made room for with one block
// move. Nearly every candidate is rejected by the first comparison, against
// the current worst; for those that get in, the move is a memmove of at most
// K entries, and in a search over N candidates in no particular order only
// about K * ln(N / K) of them ever get in.
Top :: struct {
	items: []Ranked,
	n:     int,
	k:     int,
}

top_init :: proc "contextless" (t: ^Top, buf: []Ranked) {
	t.items = buf
	t.n = 0
	t.k = len(buf)
}

top_push :: proc "contextless" (t: ^Top, r: Ranked) {
	if t.k == 0 do return
	if t.n == t.k && !better(r, t.items[t.n - 1]) do return
	// The first position whose item r is better than.
	lo, hi := 0, t.n
	for lo < hi {
		mid := (lo + hi) / 2
		if better(r, t.items[mid]) do hi = mid
		else do lo = mid + 1
	}
	last := t.n < t.k ? t.n : t.n - 1 // the worst falls off a full list
	if last > lo do copy(t.items[lo + 1:last + 1], t.items[lo:last])
	t.items[lo] = r
	if t.n < t.k do t.n += 1
}

top_merge :: proc "contextless" (into: ^Top, from: ^Top) {
	for i in 0 ..< from.n do top_push(into, from.items[i])
}
