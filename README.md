# fff — Fast Fuzzy Finder

A self-contained fuzzy finder for file **contents** and file **names**, written in [Odin](https://odin-lang.org) with raylib. It runs on Windows and Linux.

It replaces the old PowerShell `ff`, which glued together fzf, ripgrep and bat. fff does all of that itself in one executable. The font is compiled in, there are no tools to install, and nothing needs to be on your PATH except `fff` itself.

```
cd D:\Repos\MyProject
fff
```

The folder you start fff in is the folder it searches, including every subfolder. You can also pass a folder: `fff D:\Repos\Other`.

fff only **reads** files. To edit one, press Enter and it opens in your editor at the matched line.

---

## The screen

```
+--------------------------------------------+-----------+
| viewer: the selected file, at the matched  |  max file |
| line, matched characters underlined        |  size     |
|                                            |  ignored  |
|                                            |  folders  |
|                                            |  & types  |
+--------------------------------------------+           |
| results: the best 10, best first           |  key      |
|                                            |  legend   |
+--------------------------------------------+-----------+
| content > your query                   counts / status |
+--------------------------------------------------------+
```

The layout uses the whole window at whatever size it is. There is no fixed canvas, so a bigger window shows more lines.

## Keys

| Key | Does |
|---|---|
| typing | edits the query (when the search line has focus) |
| Up / Down, mouse wheel | moves through the results; the viewer follows. The list is paged: past the 10th result it shows 11–20, and so on. |
| Enter | opens the selected file in its default app, **at the line** for known editors |
| Tab | switches focus between the search line and the viewer (the focused one has an amber outline) |
| W / S | viewer: one line up / down (viewer focused) |
| E / D | viewer: half a page up / down (viewer focused) |
| A / F, Home / End | viewer: scroll sideways; jump to the top / bottom (viewer focused) |
| PageUp / PageDown | viewer: half a page, whatever has focus |
| Alt+C / Alt+F | content mode / files mode |
| Ctrl+V, Shift+Insert | paste into the search line, whatever has focus. Text with spaces goes in as one exact phrase (`"like this"`). |
| Ctrl+Shift+V | paste the words as separate terms, as if typed |
| Ctrl+U, Ctrl+Backspace | clear the query, delete a word |
| Right-click a result | open in system default, open in…, exclude its folder or file type |
| Double-click a result | opens it, like Enter |
| F3 | the performance panel, above the key legend: CPU, memory, disk, index rate, where each frame went, and how busy each background thread is |
| Esc | the menu: display mode, resolution, font size, result rows, FPS cap, quit |
| F11 | windowed / borderless |

## The performance panel (F3)

The panel sits above the key legend. It is on by default, and F3 or `show_metrics` in settings.txt turns it off. It updates twice a second:

| Row | Shows |
|---|---|
| fps | frames per second and frame time |
| cpu | fff's share of the whole machine and the machine's total; a history bar per half second |
| mem | fff's resident memory, and how much of it is the index (file text plus line tables) |
| disk | bytes read per second, as the OS counts it and as fff counts it |
| index | files read and folders listed per second |
| main thread | one stacked bar per frame: update, draw, and wait (presenting and waiting for vsync). The main thread does no indexing or searching, so nearly all of it should be wait. |
| threads | one column per background thread (the walkers, marked W, the readers, the search workers), showing the share of the last half second it spent working |

While the panel is showing and fff is idle, it redraws 20 times a second instead of sleeping, so the readout stays live. Turn it off for a fully idle fff.

`.design/performance_improvements.md` explains what the numbers mean for speed, and what to change.

## Searching

**Content mode** (the default) matches every non-empty line as `path:line: text`, the way `rg -n '.'` piped into fzf did. So `app update` finds `game_update :: proc()` in `source/app.odin`: "app" matches the path and "update" matches the text.

**Files mode** (Alt+F) matches file paths only.

The scoring is fzf's: word-boundary, camelCase and consecutive-match bonuses, and gap penalties. The query syntax is fzf's extended mode:

| Query | Matches |
|---|---|
| `abc` | fuzzy |
| `'abc` | exact substring |
| `^abc` / `abc$` | starts / ends with |
| `!abc` | must **not** contain |
| `"a b c"` | the exact phrase, spaces included. The closing quote is optional. |
| `!"a b"` | must **not** contain the phrase |
| `a b` | every term must match |

**Pasting.** A paste takes the first non-blank line of the clipboard. Tabs become spaces and the ends are trimmed. A term can be up to 512 characters, so long paths and log lines paste whole.

Lower-case terms match either case. A capital letter makes that term case-sensitive.

The index is built and searched on background threads, so the window appears at once, stays responsive, and results arrive while files are still being read. A spinner in the search line (and in the viewer, for a file not read yet) shows that work is still going on. Searching uses every core, and a big file is split between them.

**How a search stays fast.**
- **Rare-character scan.** Whatever part of the query a file's path can't supply has to be on the line itself. fff scans each file's text for the rarest such character, 32 bytes at a time, and only scores the lines it appears on. `zzzzqqq` over 40 million lines takes 0.2 s instead of 1.4 s.
- **Narrowing.** When you type on, the new query can only match lines the previous one matched, so fff searches those instead of the whole tree. Typing `mai` → `main` on that tree takes microseconds instead of 1.4 s. Going back to a query searched a moment ago, or adding a trailing space, shows its results straight away. This works for up to 4 million matches per query, and only once the index is fully read.

**Progress.** While the tree is being read, the search line shows how far along it is:
- `read 12,340 of 48,210+ files` while folders are still being listed. The `+` means more files are still being found.
- `read 12,340 of 48,210 files · 35,870 left` once every folder is listed. The total comes from listing folders, without opening any files.
- On Windows it adds `· 1.20 GB left, ~8 s`. The folder listing gives every file's size at no extra cost, and the time is the remaining bytes over the recent read rate. On Linux, getting sizes would cost a system call per file, so it is left out.

**Binary files** (a NUL byte in the first 8000 bytes) are not read; nothing in them would be worth showing as a line.

**Large files.** Files over the **max file size** at the top of the right-hand panel (64 MB by default, at most 4095 MB) are not read either. Both still appear in files mode. Click the box, type a size and press Enter; fff reads the tree again with the new limit.
- **Memory:** a file read costs its size, plus 4–8 bytes per line for the line tables.
- **Reading:** one reader reads a whole file, while the others carry on with other files.
- **Searching:** the work is shared out in pieces of 16,384 lines.

**Memory limit.** Once the index holds `max_index_mb` of text, fff stops reading more files and says so in red in the status line. The files not read are still listed in files mode.

## Ignoring folders and file types

The panel on the right lists what is left out: files over the max file size at its top (see Searching), and the folders and file types below it. Right-click a result to add to those:

| Menu item | Adds | Meaning |
|---|---|---|
| Exclude folder … from all searches | `rlu/` | any folder **named** `rlu`, in every tree fff is opened in (saved) |
| Exclude folder … from this search | `/source/rlu/` | that one folder, until fff closes |
| Exclude `*.ext` from all searches | `log` | that file type everywhere (saved) |
| Exclude `*.ext` from this search | `log` | until fff closes |

**Choosing the folder.** Point at any folder in a result's path before right-clicking, and the exclude entries are about that folder. For `data/unit_models/battle_models.modeldb.bak`:

| Mouse over | Excludes |
|---|---|
| `data/` | `data/` everywhere, or `/data/` in this search |
| `unit_models/` | `unit_models/` everywhere, or `/data/unit_models/` in this search |
| the file name, or the rest of the row | the file's own folder (`unit_models/`) |
| `.bak` | the same folder entries; the `*.bak` entries are highlighted |

The part under the mouse is underlined as you move over the path.

Hover over an entry and click its × to remove it. `.git/` and `node_modules/` are in the global list by default, and you can remove them too. fff does **not** read `.gitignore` files; the panel is the only ignore list.

## Opening files

**Enter** asks the system which app opens that kind of file. If it is an editor fff knows, fff passes the line:

| Editor | How the line is passed |
|---|---|
| VS Code, VSCodium, Cursor, Windsurf | `-g file:line` |
| JetBrains IDEs (IntelliJ, PyCharm, CLion, Rider, …) | `--line line file` |
| Notepad++ | `-nline file` |
| Sublime Text, Zed | `file:line` |
| gVim, Emacs, gedit | `+line file` |
| Kate | `-l line file` |

Any other app gets the file without a line.

- **Windows:** the app comes from the file association (`AssocQueryString`). If nothing is associated, fff looks for `code`, `idea`, Notepad++ and similar on PATH. If none is found, Windows shows its "Open with" dialog.
- **Linux:** the app comes from `xdg-mime` and its `.desktop` file. If fff can't pass a line to it, it falls back to `xdg-open`.

To always use one editor, set `editor` in settings.txt. `{file}` and `{line}` are filled in:

```
editor = "code -g {file}:{line}"
```

**Open In…** in the right-click menu shows the Windows "Open with" dialog. On Linux it asks for a command, such as `gedit +{line}` or `code -g {file}:{line}`, and remembers the last few.

## Permissions

fff never needs Administrator or sudo. It only reads, writes nothing but its own `settings.txt` and `fff.log`, and runs fine as a normal user anywhere.

When it can't get at something, it skips it:

| What | What fff does |
|---|---|
| A folder you may not list (Windows `C:\System Volume Information`, another user's home folder) | skipped, with everything under it |
| A file you may not read, or one another program holds locked (`pagefile.sys`, the registry hives in `System32\config`) | listed in files mode; the viewer says "Could not be read" |
| Symbolic links and junctions (`C:\Documents and Settings`) | not followed: they can loop |
| Devices, pipes and sockets (`/dev`) | left out: reading a pipe could wait forever |

So `fff C:\Windows\System32` works without elevation. fff is a 64-bit program, so it sees the real `System32`, not the 32-bit view. Most of the folder is binary (`.dll`, `.exe`), so mostly file names are searched, plus the text files among them. Running fff as Administrator would only let it into the few folders a normal user can't list.

On Linux, avoid starting it at `/`. Files in `/proc` report a size of 0 and come out empty, and `/sys` is thousands of tiny generated files. Add `proc/`, `sys/` and `dev/` to the ignore list if you want to search from the root.

## Settings

Settings are stored in `%APPDATA%\fff\settings.txt` on Windows and `~/.config/fff/settings.txt` on Linux. The file is SJSON, the same format as the other Odin projects, and safe to edit by hand. The path is also shown in the Esc menu.

```
display_mode     = "windowed"      // windowed | borderless | fullscreen
window_w         = 1600            // the window remembers its size and place
font_size        = 18
results          = 10              // result rows per page
max_results      = 1000            // how many results are kept to page through
max_fps          = 60
max_file_mb      = 64              // larger files are listed, not read (the box in the panel)
max_index_mb     = 0               // text held in memory at most; 0 = half the machine's RAM
show_metrics     = true            // the F3 panel
editor           = ""              // "" = the system default app, see above
ignore_folders   = [".git/", "node_modules/"]
ignore_types     = []
```

## When something is slow: fff.log

fff writes `fff.log` next to settings.txt. It records only problems:

| Line | Means |
|---|---|
| `slow frame: …` | a frame kept the window busy for more than 150 ms, with where the time went |
| `main thread stuck … for …` | the window did not finish a frame for over a second (a watchdog thread checks) |
| `reader N stuck: … on <file>` | one file has taken over 5 seconds to read (a network drive, a locked file) |
| `walker N stuck: … listing <folder>` | listing one folder has taken over 5 seconds |
| `slow read: …` | a file took over a second to read |
| `dropped input queued during a … freeze` | keys and clicks made while the window was frozen were thrown away rather than applied late |

The log is truncated at each start.

---

## Building

You need Odin **dev-2026-06 or newer**; the new `core:os` API is required. raylib comes with Odin under `vendor:raylib`.

| | Windows | Linux |
|---|---|---|
| Release: one self-contained exe | `build_release.bat` → `build\fff.exe` | `./build_release.sh` → `build/fff` |
| Tests (matcher, ignore rules) | `test.bat` | `./test.sh` |
| Timing, no window | `odin run tools/bench -o:speed -- <folder> <query>…` | same |

Put `build\fff.exe` (or `build/fff`) in a folder on your PATH. The Windows release is built with `-subsystem:windows`, so starting it from cmd returns the prompt at once. On Linux, run `fff &` if you want the terminal back.

There is no hot-reload build: fff is small enough to rebuild and rerun.

## Threads

| Thread | Does |
|---|---|
| main | input and drawing only. It never reads a file, walks a folder or searches, so it can't freeze on a big tree. |
| walkers (one per core, 2 to 8) | list folders, skipping ignored ones. The folders are listed in parallel but published in order (breadth-first, sorted within each folder), so the files come out in the same order every run. |
| readers (two per core, 4 to 32) | read files, detect binary, build each file's line table. More readers than cores keep more requests in flight while the disk is cold. |
| searcher, plus a worker per core | runs the query over the index in rounds; a new keystroke cancels the old search at once |
| watchdog | writes to fff.log when any of the above gets stuck |
| launches | opening a file runs on its own short-lived thread, so a slow editor start can't block the window |

Folders are listed and files read with the system calls directly (`getdents64` on Linux, `FindFirstFileExW` and `CreateFileW` on Windows). `core:os` makes several calls per entry that fff doesn't need, and on Windows it opened every file just to list it. File text and line tables go into large per-reader blocks instead of one allocation per file.

The index is stored in chunks that never move, so other threads read it without locks while it grows. A rebuild (after removing an ignore rule) builds a new index beside the old one and swaps it in; the old one is freed on a throwaway thread. Background threads run at lower priority than the window.

## Layout

```
source/
  app.odin            the frame, the App block, starting and swapping the index and search
  index.odin          the walker and reader threads, and the index they fill
  fs_*.odin           listing folders and reading files, per platform
  arena.odin          the blocks file text and line tables live in
  scan.odin           SIMD byte counting and searching
  search.odin         the search thread: rare-character scan, narrowing, all cores
  parallel.odin       fan-out / join helper for the search thread
  watch.odin          fff.log and the watchdog
  main_view.odin      viewer, results, search line, ignore panel
  overlays.odin       right-click menu, Esc menu, Linux "Open In..." prompt
  input.odin          keys and line editing
  launch*.odin        opening files: shared, Windows, Linux
  display.odin        window modes and resolutions
  settings.odin       settings.txt
  perf*.odin          the F3 performance panel; the OS counters per platform
  ui.odin             palette, font, widgets
  fuzzy/              the matcher (pure, tested)
  ignore/             the ignore rules (pure, tested)
  fonts/              JetBrains Mono, SIL Open Font License (OFL.txt)
main_release/         entry point for the release exe
.design/             design notes, such as performance_improvements.md
tools/bench/          headless timing
```

The old PowerShell `ff` (`ff.cmd`, `ffj.cmd`, `fuzzyfinder.ps1` and its README) is kept in `.archived/` for reference. fff doesn't use it.

## Licence

fff is public domain (see LICENSE). JetBrains Mono is © The JetBrains Mono Project Authors, under the SIL Open Font License 1.1 (`source/fonts/OFL.txt`).
