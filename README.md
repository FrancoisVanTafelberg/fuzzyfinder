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
| viewer: the selected file, at the matched  |  ignored  |
| line, matched characters underlined        |  folders  |
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
| Ctrl+V, Ctrl+U, Ctrl+Backspace | paste, clear the query, delete a word |
| Right-click a result | open in system default, open in…, exclude its folder or file type |
| Double-click a result | opens it, like Enter |
| F3 | the performance panel, above the key legend: CPU, memory, disk, index rate, where each frame went, and how busy each thread is |
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
| main thread | one stacked bar per frame: walk, read, lines, search, draw, and wait (presenting and waiting for vsync) |
| threads | one column per core fff uses, showing the share of the last half second it spent working. "main" is the main thread taking its share. |

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
| `a b` | every term must match |

Lower-case terms match either case. A capital letter makes that term case-sensitive.

The index is built in the background, a slice of each frame, so the window appears at once and results arrive while files are still being read. Searching uses every core.

Binary files (a NUL byte in the first 8000 bytes) and files over `max_file_kb` are not read, but they still appear in files mode.

## Ignoring folders and file types

The panel on the right lists what is left out. Right-click a result to add to it:

| Menu item | Adds | Meaning |
|---|---|---|
| Exclude folder … from all searches | `rlu/` | any folder **named** `rlu`, in every tree fff is opened in (saved) |
| Exclude folder … from this search | `/source/rlu/` | that one folder, until fff closes |
| Exclude `*.ext` from all searches | `log` | that file type everywhere (saved) |
| Exclude `*.ext` from this search | `log` | until fff closes |

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

## Settings

Settings are stored in `%APPDATA%\fff\settings.txt` on Windows and `~/.config/fff/settings.txt` on Linux. The file is SJSON, the same format as the other Odin projects, and safe to edit by hand. The path is also shown in the Esc menu.

```
display_mode     = "windowed"      // windowed | borderless | fullscreen
window_w         = 1600            // the window remembers its size and place
font_size        = 18
results          = 10              // result rows per page
max_results      = 1000            // how many results are kept to page through
max_fps          = 60
max_file_kb      = 4096            // larger files are listed, not read
editor           = ""              // "" = the system default app, see above
ignore_folders   = [".git/", "node_modules/"]
ignore_types     = []
```

---

## Building

You need Odin **dev-2026-06 or newer**; the new `core:os` API is required. raylib comes with Odin under `vendor:raylib`.

| | Windows | Linux |
|---|---|---|
| Release: one self-contained exe | `build_release.bat` → `build\fff.exe` | `./build_release.sh` → `build/fff` |
| Hot reload (development) | `build_hot_reload.bat`, run `build\fff_dev.exe [folder]` | `./build_hot_reload.sh`, run `./build/fff_dev [folder]` |
| Tests (matcher, ignore rules) | `test.bat` | `./test.sh` |
| Timing, no window | `odin run tools/bench -o:speed -- <folder> <query>…` | same |

Put `build\fff.exe` (or `build/fff`) in a folder on your PATH. The Windows release is built with `-subsystem:windows`, so starting it from cmd returns the prompt at once. On Linux, run `fff &` if you want the terminal back.

The hot-reload setup is the same as in the Music Box and Animal Kingdoms. All state lives in one `App` block, and running `build_hot_reload` while `fff_dev` is open swaps the code within a frame, keeping the index, query and scroll position. F5 forces a reload and F6 restarts. Indexing and search threads are joined every frame, so a reload never has a thread running inside the old library.

## Layout

```
source/
  app.odin            the frame, the App block, the hot-reload exports
  index.odin          walking the tree and reading files, a slice per frame
  search.odin         running the query over the index, across all cores
  parallel.odin       fan-out / join helper
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
main_hot_reload/      the dev host
tools/bench/          headless timing
```

The old PowerShell `ff` (`ff.cmd`, `ffj.cmd`, `fuzzyfinder.ps1` and its README) is kept in `.archived/` for reference. fff doesn't use it.

## Licence

fff is public domain (see LICENSE). JetBrains Mono is © The JetBrains Mono Project Authors, under the SIL Open Font License 1.1 (`source/fonts/OFL.txt`).
