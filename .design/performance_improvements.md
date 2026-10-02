# Performance improvements

Where fff spends its time on a big tree, and what to change, in rough order of payoff.

Each item says how to see the problem in the metrics panel (F3) before and after the change. Measure first, change one thing, measure again.

## How it works today

| Stage | Thread | What happens | Per-frame budget |
|---|---|---|---|
| Walk | main | `os.read_all_directory_by_path` on one folder at a time, breadth-first. Ignored folders are never entered. | ~2 ms (a third of the indexing budget) |
| Read | main + up to 15 workers, started and joined every frame | Claim a file from an atomic counter, `os.read_entire_file_from_path`, NUL-sniff for binary, record line starts. | the rest of the 6 ms indexing budget |
| Lines | main | Append an 8-byte `Line_Ref` for every non-empty line. | inside indexing |
| Search | main + workers | 4,096-line chunks, `could_match` pre-filter, then `path:line: text` is built and scored with fzf v1. Per-thread top-K is merged at the end. Every keystroke restarts from item 0. | 10 ms |
| Draw, present | main | raylib, then `EndDrawing` waits for vsync / the FPS cap | |

Threads never outlive a frame. That is what makes hot reload safe (see `source/parallel.odin`), and it is also the main cause of item 1.

Measured on a 13,000-file / 5.7M-line tree on 2 cores (F3 panel), while indexing:

```
main thread, ms/frame:  walk 2.4  read 5.2  lines 1.1  search 0  draw 2.3  wait 16.3
threads 2 (main + 1)    busy 15%
```

**The cores are idle about 85% of the time while there is still work to do.**

---

## 1. Let indexing use the whole machine, not a slice of each frame

**Problem.** Indexing gets 6 ms of a 16.7 ms frame. The rest goes to drawing and to waiting for vsync. At 60 fps that is at most about 36% of wall-clock time on indexing, and about 12% on walking. The headless bench (`tools/bench`, back-to-back with no vsync) indexes the same tree roughly 3x faster than the app.

**Change.**
- In the release build, run a persistent pool of background threads that index flat out from start to finish. The main thread only reads progress: an atomic count of loaded files, plus a lock or double buffer around appending to `idx.files` / `idx.lines`.
- Searching can use the same pool.
- In the hot-reload build, either keep the per-frame model, or add a `game_before_reload` export that the host calls first: it tells the pool to stop and joins it, and `game_hot_reloaded` starts it again.
- The search's 10 ms budget can stay per frame, because typing has to feel immediate.

**Watch.** Thread busy % should approach 100% while indexing. `wait` stops mattering, and files/s should rise about 3x.

**Note.** This turns the threads-never-outlive-a-frame rule into threads-are-stopped-before-a-reload. Write that into `parallel.odin`.

## 2. Walk folders in parallel, with cheaper directory listing

**Problem.**
- The walk is single-threaded and gets about 2 ms per frame. On trees with many small folders (`node_modules`-shaped trees, game assets) the walk, not reading, is the bottleneck: workers starve waiting for files to be found.
- On Linux, Odin's directory iterator (`core/os/dir_linux.odin`) does an `openat` and a `statx` for every entry, on top of `getdents64`. That is three syscalls per file where one would do.

**Change.**
- Let workers take folders as well as files: a shared queue of folders, each worker listing one and pushing back the subfolders and files it finds. Keep results in order by sorting per folder, as today.
- **Linux:** write our own walker over `core:sys/linux` `getdents64`. The `d_type` field already says file / folder / symlink, so `statx` is only needed for `DT_UNKNOWN`. The file size is only needed for `max_file_kb`, and reading can find that out itself (`fstat` on a file it already has open).
- **Windows:** `FindFirstFileExW(..., FindExInfoBasic, ..., FIND_FIRST_EX_LARGE_FETCH)`. Basic info skips the 8.3 short-name lookup, and large fetch returns more entries per kernel call. One call per folder, with the size included.

**Watch.** dirs/s, and `walk` in the main-thread bar. With the walk parallel, `walk` drops to near zero on the main thread.

## 3. Fewer system calls and allocations per file

**Problem.**
- Per file, `os.read_entire_file_from_path` does open, stat, read and close, plus allocates an `os.File`, the path string (`root + "/" + rel`, built per file) and the data buffer.
- For many small files the fixed cost dominates the reading.
- **On Windows, Defender's real-time scan runs on every file open.** It is often the largest single cost, and it is invisible to fff except as low MB/s with high CPU in `MsMpEng.exe`.

**Change.**
- Read with the size from the walk: one open, one read into a buffer of known size, one close.
- Keep a per-worker scratch path buffer instead of concatenating per file.
- Allocate file contents from a per-worker arena (big blocks), not one heap allocation per file. This also frees faster on reindex.
- Report Defender rather than work around it. If files/s is low and fff's CPU is low but system CPU is high, say so in the panel and suggest a Defender exclusion for trusted source trees. fff must never add exclusions itself.

**Watch.** files/s at the same MB/s. Then try the same tree with and without a Defender exclusion, to put a number on it.

## 4. Narrow the search as the query grows

**Problem.** Every keystroke restarts the search from the first line. Typing `palettes` searches 5.7M lines eight times. fzf narrows instead: if the new query only adds to the old one, every new match was an old match.

**Change.**
- Keep the full list of matched item indices, not only the top-K. That costs 4 bytes per match; the top-K stays as it is.
- When the new query extends the last one (same mode, same index generation, and the old query is a prefix, ignoring trailing spaces), search only that list.
- Backspace can reuse the list from a cache keyed by query. A small stack of the last few queries' match lists is enough.
- Some cases are not a narrowing and must restart: `!term` terms (adding a negation narrows, but editing one may widen), and a query whose last term changes from fuzzy to exact or the reverse. When in doubt, restart; it is only slower, never wrong.

**Watch.** `search` ms/frame and the "searching" status. After the first two or three characters, a keystroke should resolve within one frame.

## 5. A persistent thread pool instead of creating threads every frame

**Problem.** `parallel()` creates and destroys up to 15 OS threads per call, and indexing and searching can each call it in the same frame. On Windows, creating a thread costs tens of microseconds plus the scheduler's ramp-up. The cost is small but constant, and it shows up as busy % below what the work should give.

**Change.**
- Workers that sleep on a semaphore between jobs. `parallel()` hands them the job and waits on a counter.
- This comes almost for free with item 1. For hot reload, the same stop-and-join-before-reload hook applies.

**Watch.** The gap between the main thread's `read` + `search` time and the workers' busy share.

## 6. Memory: the whole tree's text lives in RAM

**Problem.** Every text file is held in full, at 4 bytes per line start and 8 bytes per searchable line. On the 13k-file tree above, about 310 MB of text became 368 MB of index: the text plus about 20% in line tables. A tree of tens of GB would not fit.

**Change, in order of effort.**
1. Show what is held. The panel already reports `index` against `fff`. Warn in the status line past a threshold, such as 25% of physical memory.
2. Lower `max_file_kb` by default, or skip by type: minified JS, lockfiles, generated code.
3. Memory-map files instead of reading them (`CreateFileMapping` / `mmap`). The OS then pages text in and out as it likes, and the index keeps only line starts.
4. Compact the line index: `u32` line starts relative to the file are already used. `Line_Ref` could become one `u32` index into a prefix-sum table of per-file line counts, which saves 4 bytes per line.

**Watch.** `mem fff` against `index`, and against the machine's RAM.

---

## Not on the list (and why)

- **SIMD in the matcher.** Search is already roughly 6M lines/s per core, and items 1 and 4 remove most of the repeated work. Revisit only if `search` still dominates after them.
- **A persistent on-disk index between runs.** Real speed for repeat opens, but it brings cache invalidation (file watching, mtimes) and a second source of truth. Only worth it if cold-start time is still the complaint after items 1–3.
