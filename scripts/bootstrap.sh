#!/usr/bin/env bash
# =============================================================================
# GitNexus MCP Kit — bootstrap (macOS / Linux)
# Idempotent. Safe to run on every VS Code folderOpen.
#
# It will:
#   1. Install gitnexus globally if it is not already installed.
#   2. Figure out which repos to index:
#        - AUTO-DETECT every repo in the workspace/scan root (default ON), AND
#        - any explicit paths listed in ../repos.list (optional).
#   3. Index those repos (skips ones indexed within GITNEXUS_FRESH_DAYS).
#   4. (Optional) Install git hooks so each repo re-indexes after `git pull`.
#   5. Ensure EXACTLY ONE shared server on $PORT (no duplicates across windows).
#
# Env overrides:
#   GITNEXUS_PORT=4747         port for the shared server
#   GITNEXUS_FRESH_DAYS=3      re-index only if the index is older than this
#   GITNEXUS_FORCE=1           force re-index of every repo
#   GITNEXUS_AUTO=0            disable workspace auto-detection (use repos.list only)
#   GITNEXUS_SCAN_ROOT=<dir>   where to auto-detect repos (default: $1 or kit parent)
#   GITNEXUS_INSTALL_HOOKS=1   install post-merge/post-checkout re-index git hooks
#
# Arg $1 (optional): workspace folder to scan (VS Code passes ${workspaceFolder}).
# =============================================================================
set -euo pipefail

PORT="${GITNEXUS_PORT:-4747}"
FRESH_DAYS="${GITNEXUS_FRESH_DAYS:-3}"
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS_FILE="$KIT_DIR/repos.list"

log() { printf '\033[36m[gitnexus]\033[0m %s\n' "$*"; }

# --- 1. Ensure gitnexus is installed ----------------------------------------
if ! command -v gitnexus >/dev/null 2>&1; then
  log "gitnexus not found — installing globally (one-time)…"
  GITNEXUS_SKIP_OPTIONAL_GRAMMARS=1 npm i -g gitnexus \
    || { log "ERROR: npm install failed. Install Node.js, then re-run."; exit 1; }
fi
log "gitnexus $(gitnexus --version 2>/dev/null || echo '?') ready"

# --- Helper: detect repo roots under a directory ----------------------------
detect_repos() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  # (a) the root itself is a git repo → use it as one repo
  if [[ -d "$root/.git" ]]; then echo "$root"; return 0; fi
  # (b) child git repos (depth ≤ 3), skipping noisy folders
  local found
  found="$(find "$root" -maxdepth 3 -type d -name .git \
            -not -path '*/node_modules/*' -not -path '*/bin/*' -not -path '*/obj/*' \
            2>/dev/null | sed 's|/\.git$||' | sort -u)"
  if [[ -n "$found" ]]; then echo "$found"; return 0; fi
  # (c) fallback: folders that look like a project (markers at depth ≤ 2)
  find "$root" -maxdepth 2 -type f \
    \( -name '*.sln' -o -name 'package.json' -o -name 'pom.xml' \
       -o -name 'go.mod' -o -name 'Cargo.toml' -o -name 'pyproject.toml' \) \
    -not -path '*/node_modules/*' 2>/dev/null \
    | xargs -n1 dirname 2>/dev/null | sort -u
}

# --- 2. Build the list of repos to index ------------------------------------
declare -a REPOS=()

# (i) explicit entries from repos.list (optional)
if [[ -f "$REPOS_FILE" ]]; then
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line="${raw%%#*}"; line="$(echo "$line" | xargs 2>/dev/null || true)"
    [[ -z "$line" ]] && continue
    [[ "$line" != /* ]] && line="$KIT_DIR/$line"
    REPOS+=("$line")
  done < "$REPOS_FILE"
fi

# (ii) auto-detected repos in the workspace (default ON)
if [[ "${GITNEXUS_AUTO:-1}" == "1" ]]; then
  SCAN_ROOT="${GITNEXUS_SCAN_ROOT:-}"
  if [[ -z "$SCAN_ROOT" ]]; then
    if [[ -n "${1:-}" && -d "${1:-}" ]]; then SCAN_ROOT="$1"; else SCAN_ROOT="$(dirname "$KIT_DIR")"; fi
  fi
  log "auto-detecting repos under: $SCAN_ROOT"
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    [[ "$r" == "$KIT_DIR" ]] && continue       # never index the kit itself
    REPOS+=("$r")
  done < <(detect_repos "$SCAN_ROOT")
fi

# (iii) de-duplicate
declare -a UNIQUE=()
for r in "${REPOS[@]:-}"; do
  [[ -z "$r" ]] && continue
  skip=0; for u in "${UNIQUE[@]:-}"; do [[ "$u" == "$r" ]] && skip=1 && break; done
  [[ "$skip" == "0" ]] && UNIQUE+=("$r")
done

if [[ "${#UNIQUE[@]:-0}" -eq 0 ]]; then
  log "no repos found. Add paths to repos.list or set GITNEXUS_SCAN_ROOT."
fi

# --- Helper: install re-index-on-pull git hooks -----------------------------
install_hooks() {
  local repo="$1"
  [[ -d "$repo/.git" ]] || return 0
  local hooks="$repo/.git/hooks"
  mkdir -p "$hooks"
  for hk in post-merge post-checkout; do
    cat > "$hooks/$hk" <<'HOOK'
#!/usr/bin/env bash
# GitNexus managed hook — re-index this repo after pull/merge/checkout.
# Non-blocking; safe if gitnexus is missing.
if command -v gitnexus >/dev/null 2>&1; then
  ( cd "$(git rev-parse --show-toplevel)" && nohup gitnexus analyze >/dev/null 2>&1 & ) || true
fi
HOOK
    chmod +x "$hooks/$hk"
  done
  log "git hooks installed (re-index on pull): $repo"
}

# --- 3. Index each repo (respecting freshness) ------------------------------
declare -a GROUP_NAMES=()
for repo in "${UNIQUE[@]:-}"; do
  [[ -z "$repo" ]] && continue
  if [[ ! -d "$repo" ]]; then log "skip (not found): $repo"; continue; fi

  meta="$repo/.gitnexus/meta.json"
  needs_index=1
  if [[ -f "$meta" && "${GITNEXUS_FORCE:-0}" != "1" ]]; then
    if [[ -z "$(find "$meta" -mtime +"$FRESH_DAYS" 2>/dev/null)" ]]; then needs_index=0; fi
  fi

  if [[ "$needs_index" == "1" ]]; then
    log "indexing: $repo"
    if ( cd "$repo" && gitnexus analyze --skip-git >/dev/null 2>&1 ); then
      log "indexed:  $repo"
      GROUP_NAMES+=("$(basename "$repo")")
    else
      log "index FAILED (try: cd '$repo' && gitnexus analyze --skip-git): $repo"
    fi
  else
    log "fresh (<= ${FRESH_DAYS}d), skipping: $repo"
    GROUP_NAMES+=("$(basename "$repo")")
  fi

  [[ "${GITNEXUS_INSTALL_HOOKS:-0}" == "1" ]] && install_hooks "$repo"
done

# --- 3b. Auto-group all workspace repos for cross-repo impact ----------------
if [[ "${GITNEXUS_GROUP:-1}" == "1" && "${#GROUP_NAMES[@]:-0}" -ge 2 ]]; then
  gbase="$(basename "${SCAN_ROOT:-$(dirname "$KIT_DIR")}")"
  GROUP="${GITNEXUS_GROUP_NAME:-$gbase}"
  GROUP="$(printf '%s' "$GROUP" | tr ' /' '--' | tr -cd 'A-Za-z0-9_-')"
  [[ -z "$GROUP" ]] && GROUP="workspace"
  log "grouping ${#GROUP_NAMES[@]} repos as '$GROUP' for cross-repo impact…"
  gitnexus group create "$GROUP" >/dev/null 2>&1 || true
  for n in "${GROUP_NAMES[@]}"; do
    gitnexus group add "$GROUP" "$n" "$n" >/dev/null 2>&1 || true
  done
  gitnexus group sync "$GROUP" >/tmp/gitnexus-group-sync.log 2>&1 \
    && log "group '$GROUP' synced" \
    || log "group sync had warnings (see /tmp/gitnexus-group-sync.log)"
fi

# --- 4. Ensure exactly ONE shared server (no duplicates) --------------------
if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
  log "server already running on $PORT — reusing it (no duplicate started)"
else
  log "starting shared server on $PORT (detached)…"
  nohup gitnexus serve --port "$PORT" >/tmp/gitnexus-serve.log 2>&1 &
  disown 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    sleep 1
    if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then break; fi
  done
  if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
    log "server up on http://localhost:$PORT"
  else
    log "server may still be starting — see /tmp/gitnexus-serve.log"
  fi
fi

log "READY → open Copilot Chat → Agent mode → ask an impact question."
log "Web graph (optional): http://localhost:$PORT"
