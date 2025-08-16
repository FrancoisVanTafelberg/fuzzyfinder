@echo off
:: !THIS IS VIBECODE!
:: ---------------------------------------------------------------------------
:: ff.cmd - Shortcut wrapper for fuzzyfinder.ps1
::
:: PURPOSE:
::   Runs the PowerShell fuzzy finder script with all arguments passed through.
::   This makes it quicker to launch from a regular Command Prompt or shell.
::
:: HOW IT WORKS:
::   - %~dp0 expands to the directory of this .cmd file.
::   - Everything you type after ff.cmd is passed on to fuzzyfinder.ps1 (%*).
::   - PowerShell is started with -NoProfile for speed and -ExecutionPolicy Bypass
::     so the script always runs without local policy issues.
::
:: USAGE EXAMPLES:
::
::   1) Default run (no arguments):
::        ff
::      → Starts fuzzyfinder in "content" mode at the current directory.
::        You can search inside files with ripgrep and open results in your editor.
::
::   2) Git mode (only git-tracked files):
::        ff -StartMode git
::      → Lists only files under git version control, respecting include/exclude filters.
::
::   3) Files mode (just filenames, not content):
::        ff -StartMode files
::      → Lets you fuzzy-search only file names, not inside them.
::
::   4) Open in IntelliJ with Java filters:
::        ff -App idea -IncludeExt java,class
::      → Restricts fuzzyfinder to .java and .class files, and opens selections in IntelliJ IDEA.
::
:: NOTES:
::   - Required tools: fzf, ripgrep (rg), bat, git (for git mode).
::   - For IntelliJ: ensure the "idea" command-line launcher is enabled in IntelliJ.
:: ---------------------------------------------------------------------------

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fuzzyfinder.ps1" %*
