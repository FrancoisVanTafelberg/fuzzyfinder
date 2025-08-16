# FuzzyFinder (VIBECODE)

Fast fuzzy search over **file names** and **file contents** on Windows using **fzf** + **ripgrep**, with a **syntax-highlighted preview** via **bat**. Opens results directly in your editor (VS Code, IntelliJ IDEA, Vim/Neovim, etc.).

---

## Features

- 🔎 Search **inside files** (content), **filenames only**, or **Git-tracked files**
- 🖼️ Live **preview** with line highlighting via `bat`
- ↗️ **Open on Enter** in your chosen editor at the exact line
- 🎛️ Static **include/exclude extension filters** (e.g., `-IncludeExt py,ps1 -ExcludeExt log,tmp`)
- ⌨️ Handy hotkeys while searching (content/files/git, scroll preview)

---

## How it works (at a glance)

- `ff.cmd` is a tiny wrapper that launches `fuzzyfinder.ps1`.
- `fuzzyfinder.ps1` calls:
  - `rg` (ripgrep) to list files or find matches
  - `fzf` to interactively filter
  - `bat` to preview around the matching line
  - your editor’s CLI (e.g., `idea`, `code`, `vim`, `nvim`) to open the selection

---

### Internal flow diagram

        +---------------------+
        |     Your terminal   |
        +----------+----------+
                   |
            [ ff.cmd (wrapper) ]
                   |
            [ fuzzyfinder.ps1 ]
                   |
        +----------v----------+
        |        fzf          |
        +----+-----------+----+
             |           |
        reload        preview
          |             |
    +-----v----+   +----v----+
    |    rg    |   |   bat    |
    +----------+   +----------+
             \          /
              \        /
               v      v
         Open in your editor
  (idea/code/nvim/vim/default)


---

## Prerequisites

Make sure these are installed and in your **PATH**:

- [fzf](https://github.com/junegunn/fzf) – fuzzy finder  
- [ripgrep (rg)](https://github.com/BurntSushi/ripgrep) – fast recursive search  
- [bat](https://github.com/sharkdp/bat) – syntax-highlighted previews  
- **An editor CLI**, for example:
  - IntelliJ IDEA (`idea`) — enable via *Tools → Create Command-line Launcher…*
  - VS Code (`code`)

Verify installation (PowerShell):
- fzf --version
- rg --version
- bat --version
- git --version     # optional
- idea --version    # or: code --version, nvim --version, etc.


## Installation

1. Clone/download repo.
2. Put fuzzyfinder.ps1 + ff.cmd into a folder in PATH.
3. (Optional) add wrappers like ffj.cmd, ffpython.cmd.

Add folder temporarily (PowerShell):
```
$env:PATH += ';D:\tools\fuzzyfinder'
```

---

## Quick Start

Default:
```
ff
```

Files-only:
```
ff -StartMode files
```

Git-tracked:
```
ff -StartMode git
```

IntelliJ + Java filter:
```
ff -App idea -IncludeExt java
```

---

## Usage

```
ff [-StartMode content|files|git] [-App auto|idea|code|vim|nvim|default] ^
   [-StartDir <path>] [-IncludeExt <ext[,ext...]>] [-ExcludeExt <ext[,ext...]>]
```

Examples:
```
ff -StartDir 'D:\Repos\MyProject'
ff -App code
ff -App idea -IncludeExt java
```

---

## Hotkeys

- Enter → open file at line
- Alt+C → content mode
- Alt+F → files mode
- Alt+G → git mode
- Shift+↑/↓ → scroll preview
- Header shows include/exclude filters

---

## Editor integration

- IntelliJ IDEA: idea --line <n> <path>
- VS Code: code -g "<path>:<n>"
- Vim/Neovim: nvim +<n> <path>
- default: OS default app

---

## Wrappers

Example: ffj.cmd
```
@echo off
call "%%~dp0ff.cmd" -App idea -IncludeExt java %%*
```

Example: ffpython.cmd
```
@echo off
call "%%~dp0ff.cmd" -App code -IncludeExt py,pyw %%*
```

---

## Troubleshooting

- unknown option → usually quoting, ensure ff.cmd calls fuzzyfinder.ps1
- .class/.jar preview unreadable → decompile first
- IntelliJ not opening → ensure idea launcher on PATH

---

## Uninstall

Remove ff.cmd, fuzzyfinder.ps1, and any wrappers from PATH.

---