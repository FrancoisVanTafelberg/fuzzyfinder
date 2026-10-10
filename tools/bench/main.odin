package bench

// Headless timing of the index and the search:
//   odin run tools/bench -o:speed -- <dir> <query>...
// No window: the index and the search engine never touch raylib.

import "core:fmt"
import "core:os"
import "core:time"
import fff "../../source"
import "../../source/ignore"

main :: proc() {
	root := len(os.args) > 1 ? os.args[1] : "."
	queries := len(os.args) > 2 ? os.args[2:] : []string{"main", "proc update", "zzzzqqq"}
	global: ignore.Rules
	ignore.add_folder(&global, ".git")
	lists := []^ignore.Rules{&global}

	t0 := time.tick_now()
	idx := fff.index_start(root, 1, 64 << 20, 0, lists, fff.walker_count(), fff.reader_count())
	for !fff.index_done(idx) do time.sleep(time.Millisecond)
	fmt.printfln("indexed %v files, %v lines, %.1f MB in %v", fff.index_count(idx), idx.lines, f64(idx.text_bytes) / 1e6, time.tick_since(t0))

	st: fff.Search_State
	for q in queries {
		for mode in fff.Mode {
			query: fff.Search_Query
			query.text_len = copy(query.text[:], q)
			query.mode = mode
			query.k = 1000
			query.idx = idx
			fff.search_reset(&st, &query)
			t1 := time.tick_now()
			for {
				_, complete := fff.search_round(&st, time.Second)
				if complete do break
			}
			fmt.printfln("  %-8v %-14q %8v matched, %v%s", mode, q, st.matched, time.tick_since(t1), st.narrowed ? "  (narrowed)" : "")
			if st.top.n > 0 {
				it := st.top.items[0]
				buf: [2048]u8
				text, _ := fff.candidate(idx, mode, int(it.item), int(it.line), buf[:])
				fmt.printfln("           best (%v): %s", it.score, string(text[:min(len(text), 100)]))
			}
		}
	}
	// Typing the last query one character at a time: each keystroke after
	// the first can narrow the one before.
	if len(queries) > 0 {
		q := queries[len(queries) - 1]
		fmt.println("  typing", q)
		for n in 1 ..= len(q) {
			query: fff.Search_Query
			query.text_len = copy(query.text[:], q[:n])
			query.k = 1000
			query.idx = idx
			fff.search_reset(&st, &query)
			t1 := time.tick_now()
			for {
				_, complete := fff.search_round(&st, time.Second)
				if complete do break
			}
			fmt.printfln("    %-14q %8v matched, %v%s", q[:n], st.matched, time.tick_since(t1), st.narrowed ? "  (narrowed)" : "")
		}
	}
	fff.search_state_destroy(&st)
	fff.index_free(idx)
}
