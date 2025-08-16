# !THIS IS VIBECODE!
<#
  Fuzzyfinder: search filenames and file contents with fzf + ripgrep.
  Provides syntax-highlighted previews (bat), jumps to the match line, 
  and opens the selection in your chosen editor.

  Requirements:
    - fzf (fuzzy finder, TUI search UI)
    - ripgrep (rg, fast recursive grep)
    - bat (syntax-highlighting cat/less replacement)
    - git (optional: enables "git-tracked files" mode)

  Usage examples:
    .\fuzzyfinder.ps1
    .\fuzzyfinder.ps1 -App code
    .\fuzzyfinder.ps1 -App idea -StartDir "D:\Repos\Project" -StartMode git
    .\fuzzyfinder.ps1 -IncludeExt py,ps1 -ExcludeExt min,log
#>

[CmdletBinding()]
param(
  # Preferred editor to open files in
  [ValidateSet('auto','code','idea','nvim','vim','default')]
  [string]$App = 'auto',

  # Starting directory for search
  [string]$StartDir = '.',

  # Search mode: content = search inside files, files = list files, git = git-tracked files
  [ValidateSet('content','files','git')]
  [string]$StartMode = 'content',

  # Static filters (comma-separated or array). Extensions with or without leading '.'
  [string[]]$IncludeExt = @(),   # e.g. -IncludeExt py,ps1
  [string[]]$ExcludeExt = @()    # e.g. -ExcludeExt class,log
)

# --- Tool checks: ensure required executables are available in PATH ---
foreach ($t in 'fzf','rg','bat') {
  if (-not (Get-Command $t -EA SilentlyContinue)) {
    Write-Error "Required tool '$t' not found in PATH."; exit 1
  }
}
$hasGit = [bool](Get-Command git -EA SilentlyContinue)

# --- Normalize extension lists ---
# Converts user-provided extension filters into a clean lowercase array
# Handles "py", ".py", "py,ps1" → @("py","ps1")
function Normalize-ExtList {
  param([string[]]$List)
  $norm = @()
  foreach ($item in $List) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    $parts = $item -split ','
    foreach ($p in $parts) {
      $e = $p.Trim()
      if ($e -eq '') { continue }
      if ($e.StartsWith('.')) { $e = $e.Substring(1) }
      $norm += $e.ToLowerInvariant()
    }
  }
  ,($norm | Select-Object -Unique)
}

$Inc = Normalize-ExtList $IncludeExt
$Exc = Normalize-ExtList $ExcludeExt

# Precompute CSV strings for helper calls
$incCsv = ($Inc -join ',')
$excCsv = ($Exc -join ',')

# --- Change to the requested start directory ---
Push-Location $StartDir
try {
  # --- Editor picker helper script (fzf_pick_app.ps1) ---
  # Decides which editor command to use when opening a file.
  $pickApp = Join-Path $env:TEMP 'fzf_pick_app.ps1'
  if (-not (Test-Path $pickApp)) {
@'
param([string]$want)
if ($want -in "code","idea","nvim","vim","default","auto"){ return $want }
if (Get-Command code -EA SilentlyContinue){ "code" }
elseif (Get-Command idea -EA SilentlyContinue){ "idea" }
elseif (Get-Command nvim -EA SilentlyContinue){ "nvim" }
elseif (Get-Command vim  -EA SilentlyContinue){ "vim" }
else { "default" } # fallback: use default system opener
'@ | Set-Content -Encoding UTF8 -NoNewline -LiteralPath $pickApp
  }

  # --- Preview helper script (fzf_preview_showrange.ps1) ---
  # Uses bat to show syntax-highlighted context around the matching line.
  $previewScript = Join-Path $env:TEMP 'fzf_preview_showrange.ps1'
  if (-not (Test-Path $previewScript)) {
@"
param([string]`$File,[int]`$Line=1)
if (-not (Test-Path -LiteralPath `$File)) { Write-Output "File not found: `$File"; exit 0 }
`$Line  = [math]::Max(1,`$Line)
`$start = [math]::Max(1,`$Line-30)
`$end   = `$Line + 30
bat --color=always --paging=never `
    --line-range "`$start`:`$end" `
    --highlight-line `$Line `
    --wrap never --style=numbers -- "`$File"
"@ | Set-Content -Encoding UTF8 -NoNewline -LiteralPath $previewScript
  }

  # --- File opening helper script (fzf_open_file.ps1) ---
  # Opens the chosen file+line in the requested editor.
  $openScript = Join-Path $env:TEMP 'fzf_open_file.ps1'
  if (-not (Test-Path $openScript)) {
@"
param(
  [string]`$File,
  [int]`$Line = 1,
  [string]`$App = "auto"
)
. '$pickApp'
`$File = [System.IO.Path]::GetFullPath(`$File)
`$Line = [Math]::Max(1,`$Line)
`$app  = & '$pickApp' `$App
switch (`$app) {
  "code"      { code -g "`$File`:`$Line" | Out-Null; break }
  "idea"      { idea --line `$Line -- "`$File" | Out-Null; break }
  "nvim"      { nvim +`$Line -- "`$File"; break }
  "vim"       { vim  +`$Line -- "`$File"; break }
  default     { Invoke-Item -LiteralPath `$File } # system default opener
}
"@ | Set-Content -Encoding UTF8 -NoNewline -LiteralPath $openScript
  }

  # --- Source helper script (fzf_source.ps1) ---
  # Generates candidate items for fzf based on mode:
  #   - content: uses rg to search inside files
  #   - files:   uses rg --files
  #   - git:     lists git-tracked files (or falls back to rg --files)
  $sourceHelper = Join-Path $env:TEMP 'fzf_source.ps1'
  if (-not (Test-Path $sourceHelper)) {
@'
param(
  [Parameter(Mandatory=$true, Position=0)][ValidateSet("content","files","git")] $Mode,
  [Parameter(Position=1)][string] $Include = "",
  [Parameter(Position=2)][string] $Exclude = ""
)

# Normalizes extensions again (local to helper)
function Norm($s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return @() }
  $out = @()
  foreach ($p in ($s -split ',')) {
    $t = $p.Trim()
    if ($t -eq "") { continue }
    if ($t.StartsWith('.')) { $t = $t.Substring(1) }
    $out += $t.ToLowerInvariant()
  }
  ,($out | Select-Object -Unique)
}
$inc = Norm $Include
$exc = Norm $Exclude

# Build ripgrep filters from include/exclude extension sets
function Build-RgArgs([string[]]$inc,[string[]]$exc){
  $args = @()
  foreach ($e in $inc) { $args += @('-g', "*.$e") }
  foreach ($e in $exc) { $args += @('-g', "!*.$e") }
  ,$args
}
$rgArgs = Build-RgArgs $inc $exc

switch ($Mode) {
  'content' {
    # Show matches with file:line:text
    & rg -n --no-heading --color=always @rgArgs '.'
  }
  'files' {
    # List only file paths
    & rg --files @rgArgs
  }
  'git' {
    # Restrict to git-tracked files (fallback = rg --files)
    $inRepo = $false
    try {
      $null = git -C . rev-parse --is-inside-work-tree 2>$null
      if ($LASTEXITCODE -eq 0) { $inRepo = $true }
    } catch { }
    if (-not $inRepo) {
      & rg --files @rgArgs
      break
    }
    $files = git ls-files
    if ($inc.Count -eq 0 -and $exc.Count -eq 0) { $files; break }
    $incSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $inc) { $incSet.Add($e) | Out-Null }
    $excSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $exc) { $excSet.Add($e) | Out-Null }
    $files | Where-Object {
      $ext = [System.IO.Path]::GetExtension($_)
      if ($ext.StartsWith('.')) { $ext = $ext.Substring(1) }
      if ($excSet.Contains($ext)) { return $false }
      if ($incSet.Count -gt 0) { return $incSet.Contains($ext) }
      $true
    }
  }
}
'@ | Set-Content -Encoding UTF8 -NoNewline -LiteralPath $sourceHelper
  }

  # --- Build reload commands using -EncodedCommand ---
  # Encodes helper calls into base64 to avoid quoting/escaping issues inside fzf.
  function To-Enc {
    param([string]$ScriptPath, [string]$Mode, [string]$IncCsv, [string]$ExcCsv)
    $cmd = "& '$ScriptPath' $Mode '$IncCsv' '$ExcCsv'"
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
  }
  $encContent  = To-Enc -ScriptPath $sourceHelper -Mode 'content' -IncCsv $incCsv -ExcCsv $excCsv
  $encFiles    = To-Enc -ScriptPath $sourceHelper -Mode 'files'   -IncCsv $incCsv -ExcCsv $excCsv
  $encGit      = To-Enc -ScriptPath $sourceHelper -Mode 'git'     -IncCsv $incCsv -ExcCsv $excCsv

  # Actual PowerShell commands that fzf reloads
  $cmdContent  = "powershell -NoProfile -EncodedCommand $encContent"
  $cmdAllFiles = "powershell -NoProfile -EncodedCommand $encFiles"
  $cmdGit      = "powershell -NoProfile -EncodedCommand $encGit"

  # Pick starting mode command
  switch ($StartMode) {
    'files' { $startCmd = $cmdAllFiles }
    'git'   { $startCmd = $cmdGit }
    default { $startCmd = $cmdContent }
  }

  # --- Preview command for fzf ---
  # fzf passes {1}=file, {2}=line (from delimiter split)
  $preview = ('powershell -NoProfile -File "{0}" --File {{1}} --Line {{2}}' -f $previewScript)

  # --- Header shown in fzf ---
  $incLabel = if ($Inc.Count) { ($Inc -join ',') } else { 'all' }
  $excLabel = if ($Exc.Count) { ($Exc -join ',') } else { 'none' }
  $header = @"
| [Enter]=Open  [Alt+C]=Content  [Alt+F]=Files  [Alt+G]=Git  [Shift+Up/Down]=Preview Scroll
| Include: $incLabel   Exclude: $excLabel
"@

  # --- Build fzf arguments ---
  $fzfArgs = @(
    '--ansi',
    '--delimiter', ':',               # split "file:line:text"
    '--preview', $preview,            # use our preview script
    '--preview-window', 'up:60%:wrap',

    # Reload keybinds
    '--bind', ("start:reload:{0}" -f $startCmd),
    '--bind', ("alt-c:reload:{0}" -f $cmdContent),
    '--bind', ("alt-f:reload:{0}" -f $cmdAllFiles),
    '--bind', ("alt-g:reload:{0}" -f $cmdGit),

    # Preview scrolling
    '--bind', 'shift-up:preview-up',
    '--bind', 'shift-down:preview-down',

    '--header', $header
  )

  # --- Enter = open file in chosen editor ---
  $openAppArg = & $pickApp $App
  $fzfArgs += @(
    '--bind', ('enter:execute-silent(powershell -NoProfile -File "{0}" --File {{1}} --Line {{2}} --App {1})' -f $openScript, $openAppArg)
  )

  # --- Run fzf with built args ---
  & fzf @fzfArgs | Out-Null
}
finally {
  Pop-Location
}
