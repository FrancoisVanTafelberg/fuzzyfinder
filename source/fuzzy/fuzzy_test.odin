package fuzzy

// odin test source/fuzzy

import "core:testing"

@(private = "file")
score_of :: proc(q, text: string) -> (int, bool) {
	p := parse(q)
	s, ok, _ := match(&p, transmute([]u8)text)
	return s, ok
}

@(test)
fuzzy_matches_in_order :: proc(t: ^testing.T) {
	_, ok := score_of("fbr", "foo/bar.odin")
	testing.expect(t, ok)
	_, ok = score_of("rbf", "foo/bar.odin")
	testing.expect(t, !ok)
}

@(test)
smart_case :: proc(t: ^testing.T) {
	_, ok := score_of("app", "App.odin")
	testing.expect(t, ok, "lower-case query matches any case")
	_, ok = score_of("App", "app.odin")
	testing.expect(t, !ok, "a capital makes the term case-sensitive")
}

@(test)
boundaries_beat_the_middle_of_words :: proc(t: ^testing.T) {
	a, _ := score_of("fo", "src/foo.odin")
	b, _ := score_of("fo", "src/info.odin")
	testing.expectf(t, a > b, "boundary %v should beat mid-word %v", a, b)
}

@(test)
consecutive_beats_scattered :: proc(t: ^testing.T) {
	a, _ := score_of("main", "source/main.odin")
	b, _ := score_of("main", "source/my_api_index.odin")
	testing.expectf(t, a > b, "consecutive %v should beat scattered %v", a, b)
}

@(test)
camel_case_humps :: proc(t: ^testing.T) {
	a, _ := score_of("gu", "gameUpdate")
	b, _ := score_of("gu", "garbage")
	testing.expect(t, a > b)
}

@(test)
extended_terms :: proc(t: ^testing.T) {
	_, ok := score_of("'bar", "foo/bar.odin")
	testing.expect(t, ok)
	_, ok = score_of("'bra", "foo/bar.odin")
	testing.expect(t, !ok, "exact does not match fuzzily")
	_, ok = score_of("foo !bar", "foo/bar.odin")
	testing.expect(t, !ok, "negation rejects")
	_, ok = score_of("foo !baz", "foo/bar.odin")
	testing.expect(t, ok)
	_, ok = score_of("^proc", "\tproc main")
	testing.expect(t, ok, "prefix skips leading whitespace")
	_, ok = score_of("odin$", "foo/bar.odin")
	testing.expect(t, ok)
	_, ok = score_of("foo$", "foo/bar.odin")
	testing.expect(t, !ok)
}

@(test)
all_terms_must_match :: proc(t: ^testing.T) {
	_, ok := score_of("foo odin", "foo/bar.odin")
	testing.expect(t, ok)
	_, ok = score_of("foo rust", "foo/bar.odin")
	testing.expect(t, !ok)
}

@(test)
positions_are_reported :: proc(t: ^testing.T) {
	p := parse("bar")
	pos: [8]int
	_, ok, n := match(&p, transmute([]u8)string("foo/bar.odin"), pos[:])
	testing.expect(t, ok)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, pos[0], 4)
	testing.expect_value(t, pos[2], 6)
}

@(test)
quoted_phrases_are_exact :: proc(t: ^testing.T) {
	_, ok := score_of("\"gets an upgraded\"", "Aragorn gets an upgraded battle model")
	testing.expect(t, ok)
	_, ok = score_of("\"gets upgraded\"", "Aragorn gets an upgraded battle model")
	testing.expect(t, !ok, "a phrase is not fuzzy")
	_, ok = score_of("\"gets an upg", "Aragorn gets an upgraded battle model")
	testing.expect(t, ok, "the closing quote is optional")
	_, ok = score_of("aragorn !\"battle model\"", "Aragorn gets an upgraded battle model")
	testing.expect(t, !ok, "a negated phrase rejects")
	_, ok = score_of("\"battle model\" aragorn", "Aragorn gets an upgraded battle model")
	testing.expect(t, ok, "terms after a phrase still parse")
	p := parse("\"a b\"")
	testing.expect_value(t, p.n, 1)
	testing.expect(t, !p.terms[0].checkable, "a space could come from the ': ' between path and text")
}

@(test)
long_terms_are_kept :: proc(t: ^testing.T) {
	long := "unit_models/AttachmentSets/final_general_gondor_norm_Early.texture_and_then_some_more_to_go_well_past_one_hundred_and_twenty_eight_bytes_long"
	_, ok := score_of(long, long)
	testing.expect(t, ok)
	_, ok = score_of(long, "unit_models/AttachmentSets/final_general_gondor_norm_Early.texture")
	testing.expect(t, !ok, "every byte of a long term counts")
}

@(test)
lone_operators_are_ignored :: proc(t: ^testing.T) {
	p := parse("  !  '  ")
	testing.expect(t, is_empty(&p))
}

@(test)
top_keeps_the_best_k :: proc(t: ^testing.T) {
	top: Top
	buf: [3]Ranked
	top_init(&top, buf[:])
	for s, i in ([]i32{5, 1, 9, 7, 3, 9}) do top_push(&top, {score = s, length = 10, item = u32(i)})
	testing.expect_value(t, top.n, 3)
	testing.expect_value(t, top.items[0].score, 9)
	testing.expect_value(t, top.items[0].item, 2) // equal scores: earlier item first
	testing.expect_value(t, top.items[1].item, 5)
	testing.expect_value(t, top.items[2].score, 7)
}

@(test)
top_stays_sorted_when_deep :: proc(t: ^testing.T) {
	buf: [500]Ranked
	top: Top
	top_init(&top, buf[:])
	// A scrambled run of scores, more of them than fit.
	for i in 0 ..< 5000 do top_push(&top, {score = i32((i * 7919) % 3001), length = 1, item = u32(i)})
	testing.expect_value(t, top.n, 500)
	for i in 1 ..< top.n do testing.expect(t, !better(top.items[i], top.items[i - 1]), "best first")
	testing.expect_value(t, top.items[0].score, 3000)
}

@(test)
could_match_is_necessary_not_sufficient :: proc(t: ^testing.T) {
	p := parse("app upd")
	testing.expect(t, could_match(&p, transmute([]u8)string("src/app.odin"), transmute([]u8)string("game_update()")))
	testing.expect(t, !could_match(&p, transmute([]u8)string("src/app.odin"), transmute([]u8)string("game_draw()")))
	// A digit could come from the line number left out between the pieces.
	q := parse("app12")
	testing.expect(t, could_match(&q, transmute([]u8)string("app"), transmute([]u8)string("x")))
}
