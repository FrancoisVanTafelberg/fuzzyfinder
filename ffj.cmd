@echo off
:: !THIS IS VIBECODE!
:: ---------------------------------------------------------------------------
:: ffj.cmd - Java-only fuzzyfinder (IntelliJ)
::
:: PURPOSE:
::   Shortcut to run fuzzyfinder for Java development.
::   - Only includes .java files
::   - Opens matches directly in IntelliJ IDEA
::
:: HOW IT WORKS:
::   Calls ff.cmd (the main fuzzyfinder wrapper) with:
::     -App idea        → Always use IntelliJ
::     -IncludeExt java → Restrict search to Java files only
::
:: USAGE:
::   ffj
::     → Search inside .java files only, preview results with bat,
::       and open them in IntelliJ.
::
::   ffj -StartMode files
::     → Fuzzy-search Java filenames only (instead of file contents).
:: ---------------------------------------------------------------------------

call "%~dp0ff.cmd" -App idea -IncludeExt java %*
