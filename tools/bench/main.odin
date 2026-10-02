package bench

// Headless timing of the index and the search: odin run tools/bench -o:speed -- <dir> <query>...
// No window: index_step and search_step never touch raylib.

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

	idx: fff.Index
	fff.index_restart(&idx, 4096 * 1024)
	t0 := time.tick_now()
	frames := 0
	for !fff.index_done(&idx) {
		fff.index_step(&idx, root, lists, 16 * time.Millisecond)
		frames += 1
		free_all(context.temp_allocator)
	}
	el := time.tick_since(t0)
	fmt.printfln("indexed %v files, %v lines, %.1f MB in %v (%v frames)", len(idx.files), len(idx.lines), f64(idx.text_bytes) / 1e6, el, frames)

	for q in queries {
		for mode in fff.Mode {
			s: fff.Search
			t1 := time.tick_now()
			fr := 0
			for {
				fff.search_step(&s, &idx, q, mode, 1000, 0, 1000 * time.Millisecond)
				fr += 1
				if !fff.search_busy(&s, &idx) do break
			}
			fmt.printfln("  %-8v %-14q %8v matched, %v", mode, q, s.matched, time.tick_since(t1))
			if s.top.n > 0 {
				it := s.top.items[0]
				buf: [2048]u8
				text, _ := fff.candidate(&idx, mode, it.item, buf[:])
				fmt.printfln("           best (%v): %s", it.score, string(text[:min(len(text), 100)]))
			}
			fff.search_destroy(&s)
		}
	}
}
