# =============================================================================
# GitNexus MCP Kit - bootstrap (Windows / PowerShell)
# Idempotent. Safe to run on every VS Code folderOpen.
#
# It will:
#   1. Install gitnexus globally if it is not already installed.
#   2. Figure out which repos to index:
#        - AUTO-DETECT every repo in the workspace/scan root (default ON), AND
#        - any explicit paths listed in ..\repos.list (optional).
#   3. Index those repos (skips ones indexed within GITNEXUS_FRESH_DAYS).
#   4. (Optional) Install git hooks so each repo re-indexes after `git pull`.
#   5. Ensure EXACTLY ONE shared server on $Port (no duplicates across windows).
#
# Env overrides:
#   GITNEXUS_PORT=4747         port for the shared server
#   GITNEXUS_FRESH_DAYS=3      re-index only if the index is older than this
#   GITNEXUS_FORCE=1           force re-index of every repo
#   GITNEXUS_AUTO=0            disable workspace auto-detection (use repos.list only)
#   GITNEXUS_SCAN_ROOT=<dir>   where to auto-detect repos (default: arg1 or kit parent)
#   GITNEXUS_INSTALL_HOOKS=1   install post-merge/post-checkout re-index git hooks
#   GITNEXUS_GROUP=0           skip auto-grouping all workspace repos
#   GITNEXUS_GROUP_NAME=<name> override the auto-generated group name
#
# Arg 1 (optional): workspace folder to scan (VS Code passes ${workspaceFolder}).
# =============================================================================
param([string]$WorkspaceFolder = "")
$ErrorActionPreference = "Stop"

$Port      = if ($env:GITNEXUS_PORT) { $env:GITNEXUS_PORT } else { "4747" }
$FreshDays = if ($env:GITNEXUS_FRESH_DAYS) { [int]$env:GITNEXUS_FRESH_DAYS } else { 3 }
$KitDir    = Split-Path -Parent $PSScriptRoot
$ReposFile = Join-Path $KitDir "repos.list"

function Log($msg) { Write-Host "[gitnexus] $msg" -ForegroundColor Cyan }
function Test-Server {
  try { Invoke-RestMethod -Uri "http://localhost:$Port/api/health" -TimeoutSec 2 | Out-Null; return $true }
  catch { return $false }
}

# --- 1. Ensure gitnexus is installed ----------------------------------------
if (-not (Get-Command gitnexus -ErrorAction SilentlyContinue)) {
  Log "gitnexus not found - installing globally (one-time)..."
  $env:GITNEXUS_SKIP_OPTIONAL_GRAMMARS = "1"
  npm i -g gitnexus
}
Log "gitnexus ready"

# --- Helper: detect repo roots under a directory ----------------------------
function Detect-Repos($root) {
  if (-not (Test-Path $root -PathType Container)) { return @() }
  # (a) root itself is a git repo
  if (Test-Path (Join-Path $root ".git")) { return @($root) }
  # (b) child git repos (depth <= 3)
  $git = Get-ChildItem -Path $root -Directory -Recurse -Depth 3 -Force -Filter ".git" -ErrorAction SilentlyContinue |
         Where-Object { $_.FullName -notmatch '\\(node_modules|bin|obj)\\' } |
         ForEach-Object { Split-Path -Parent $_.FullName } | Sort-Object -Unique
  if ($git.Count -gt 0) { return $git }
  # (c) fallback: project markers (depth <= 2)
  $markers = '*.sln','package.json','pom.xml','go.mod','Cargo.toml','pyproject.toml'
  $hits = foreach ($m in $markers) {
    Get-ChildItem -Path $root -File -Recurse -Depth 2 -Force -Filter $m -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
      ForEach-Object { Split-Path -Parent $_.FullName }
  }
  return ($hits | Sort-Object -Unique)
}

# --- 2. Build the list of repos to index ------------------------------------
$repos = New-Object System.Collections.Generic.List[string]

# (i) explicit entries from repos.list (optional)
if (Test-Path $ReposFile) {
  foreach ($raw in Get-Content $ReposFile) {
    $line = ($raw -replace '#.*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if (-not [System.IO.Path]::IsPathRooted($line)) { $line = Join-Path $KitDir $line }
    $repos.Add($line) | Out-Null
  }
}

# (ii) auto-detected repos (default ON)
if ($env:GITNEXUS_AUTO -ne "0") {
  $scanRoot = $env:GITNEXUS_SCAN_ROOT
  if ([string]::IsNullOrWhiteSpace($scanRoot)) {
    if ($WorkspaceFolder -and (Test-Path $WorkspaceFolder)) { $scanRoot = $WorkspaceFolder }
    else { $scanRoot = Split-Path -Parent $KitDir }
  }
  Log "auto-detecting repos under: $scanRoot"
  foreach ($r in (Detect-Repos $scanRoot)) {
    if ($r -eq $KitDir) { continue }
    $repos.Add($r) | Out-Null
  }
}

$unique = $repos | Sort-Object -Unique
if ($unique.Count -eq 0) { Log "no repos found. Add paths to repos.list or set GITNEXUS_SCAN_ROOT." }

# --- Helper: install re-index-on-pull git hooks -----------------------------
function Install-Hooks($repo) {
  $gitDir = Join-Path $repo ".git"
  if (-not (Test-Path $gitDir)) { return }
  $hooks = Join-Path $gitDir "hooks"
  New-Item -ItemType Directory -Force -Path $hooks | Out-Null
  $body = @"
#!/usr/bin/env bash
# GitNexus managed hook - re-index this repo after pull/merge/checkout.
if command -v gitnexus >/dev/null 2>&1; then
  ( cd "`$(git rev-parse --show-toplevel)" && nohup gitnexus analyze >/dev/null 2>&1 & ) || true
fi
"@
  foreach ($hk in @("post-merge","post-checkout")) {
    Set-Content -Path (Join-Path $hooks $hk) -Value $body -NoNewline -Encoding ASCII
  }
  Log "git hooks installed (re-index on pull): $repo"
}

# --- 3. Index each repo (respecting freshness) ------------------------------
$groupNames = New-Object System.Collections.Generic.List[string]
foreach ($repo in $unique) {
  if (-not (Test-Path $repo -PathType Container)) { Log "skip (not found): $repo"; continue }
  $meta = Join-Path $repo ".gitnexus\meta.json"
  $needsIndex = $true
  if ((Test-Path $meta) -and ($env:GITNEXUS_FORCE -ne "1")) {
    $age = (New-TimeSpan -Start (Get-Item $meta).LastWriteTime -End (Get-Date)).TotalDays
    if ($age -le $FreshDays) { $needsIndex = $false }
  }
  if ($needsIndex) {
    Log "indexing: $repo"
    Push-Location $repo
    try { gitnexus analyze --skip-git | Out-Null; Log "indexed:  $repo"; $groupNames.Add((Split-Path -Leaf $repo)) | Out-Null }
    catch { Log "index FAILED: $repo" }
    finally { Pop-Location }
  } else {
    Log "fresh (<= $FreshDays d), skipping: $repo"
    $groupNames.Add((Split-Path -Leaf $repo)) | Out-Null
  }
  if ($env:GITNEXUS_INSTALL_HOOKS -eq "1") { Install-Hooks $repo }
}

# --- 3b. Auto-group all workspace repos for cross-repo impact ----------------
if (($env:GITNEXUS_GROUP -ne "0") -and ($groupNames.Count -ge 2)) {
  $gbase = if ($env:GITNEXUS_GROUP_NAME) { $env:GITNEXUS_GROUP_NAME } else { Split-Path -Leaf $scanRoot }
  $group = ($gbase -replace '[ /]', '-') -replace '[^A-Za-z0-9_-]', ''
  if ([string]::IsNullOrWhiteSpace($group)) { $group = "workspace" }
  Log "grouping $($groupNames.Count) repos as '$group' for cross-repo impact..."
  gitnexus group create $group 2>$null | Out-Null
  foreach ($n in $groupNames) { gitnexus group add $group $n $n 2>$null | Out-Null }
  try { gitnexus group sync $group | Out-Null; Log "group '$group' synced" }
  catch { Log "group sync had warnings" }
}

# --- 4. Ensure exactly ONE shared server (no duplicates) --------------------
if (Test-Server) {
  Log "server already running on $Port - reusing it (no duplicate started)"
} else {
  Log "starting shared server on $Port (detached)..."
  Start-Process -WindowStyle Hidden -FilePath "gitnexus" -ArgumentList "serve","--port",$Port
  for ($i=0; $i -lt 5; $i++) { Start-Sleep -Seconds 1; if (Test-Server) { break } }
  if (Test-Server) { Log "server up on http://localhost:$Port" } else { Log "server may still be starting..." }
}

Log "READY -> open Copilot Chat -> Agent mode -> ask an impact question."
Log "Web graph (optional): http://localhost:$Port"
