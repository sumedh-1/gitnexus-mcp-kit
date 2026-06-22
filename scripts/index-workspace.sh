#!/usr/bin/env bash
# =============================================================================
# GitNexus MCP Kit — index an entire VS Code .code-workspace in one command.
#
#   bash index-workspace.sh /path/to/your.code-workspace
#
# Reads the "folders" list from the workspace file, indexes each one
# (skips repos indexed within GITNEXUS_FRESH_DAYS), AUTOMATICALLY GROUPS them
# for cross-repo impact, and makes sure the single shared server is running.
# Idempotent — safe to re-run any time.
#
# Env overrides: GITNEXUS_PORT, GITNEXUS_FRESH_DAYS, GITNEXUS_FORCE=1,
#                GITNEXUS_GROUP=0 (skip auto-group), GITNEXUS_GROUP_NAME=<name>
# =============================================================================
set -euo pipefail

WS="${1:-}"
if [[ -z "$WS" || ! -f "$WS" ]]; then
  echo "usage: bash index-workspace.sh /path/to/your.code-workspace" >&2
  exit 1
fi

PORT="${GITNEXUS_PORT:-4747}"
FRESH_DAYS="${GITNEXUS_FRESH_DAYS:-3}"
WS_DIR="$(cd "$(dirname "$WS")" && pwd)"

log() { printf '\033[36m[gitnexus]\033[0m %s\n' "$*"; }

# Ensure gitnexus is installed
if ! command -v gitnexus >/dev/null 2>&1; then
  log "installing gitnexus (one-time)…"
  GITNEXUS_SKIP_OPTIONAL_GRAMMARS=1 npm i -g gitnexus
fi

# Parse the "folders" array from the .code-workspace (JSON, tolerant of comments)
FOLDERS_RAW="$(python3 - "$WS" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
# strip // and /* */ comments so VS Code jsonc parses
raw = re.sub(r'/\*.*?\*/', '', raw, flags=re.S)
raw = re.sub(r'(^|\s)//.*$', '', raw, flags=re.M)
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
for f in data.get("folders", []):
    p = f.get("path")
    if p:
        print(p)
PY
)"

if [[ -z "$FOLDERS_RAW" ]]; then
  log "no folders found in $WS"; exit 0
fi

count="$(printf '%s\n' "$FOLDERS_RAW" | grep -c . || true)"
log "found $count folders in $(basename "$WS")"

REPO_NAMES=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  case "$p" in
    /*) repo="$p" ;;            # absolute
    *)  repo="$WS_DIR/$p" ;;    # relative to the workspace file
  esac
  repo="$(cd "$repo" 2>/dev/null && pwd || echo "$repo")"
  if [[ ! -d "$repo" ]]; then log "skip (missing): $repo"; continue; fi

  name="$(basename "$repo")"
  meta="$repo/.gitnexus/meta.json"
  if [[ -f "$meta" && "${GITNEXUS_FORCE:-0}" != "1" && -z "$(find "$meta" -mtime +"$FRESH_DAYS" 2>/dev/null)" ]]; then
    log "fresh, skipping: $repo"; REPO_NAMES+=("$name"); continue
  fi

  log "indexing: $repo"
  if [[ -d "$repo/.git" ]]; then
    ( cd "$repo" && gitnexus analyze >/dev/null 2>&1 ) && { log "indexed:  $repo"; REPO_NAMES+=("$name"); } || log "FAILED:   $repo"
  else
    ( cd "$repo" && gitnexus analyze --skip-git >/dev/null 2>&1 ) && { log "indexed:  $repo"; REPO_NAMES+=("$name"); } || log "FAILED:   $repo"
  fi
done <<EOF
$FOLDERS_RAW
EOF

# Auto-group every workspace repo so cross-repo impact works out of the box.
# ("Who knows what affects what" — that's the whole point of a workspace group.)
if [[ "${GITNEXUS_GROUP:-1}" == "1" && "${#REPO_NAMES[@]}" -ge 2 ]]; then
  base="$(basename "$WS")"; base="${base%.code-workspace}"; base="${base%.*}"
  GROUP="${GITNEXUS_GROUP_NAME:-$base}"
  # sanitize to a safe group name
  GROUP="$(printf '%s' "$GROUP" | tr ' /' '--' | tr -cd 'A-Za-z0-9_-')"
  [[ -z "$GROUP" ]] && GROUP="workspace"
  log "grouping ${#REPO_NAMES[@]} repos as '$GROUP' for cross-repo impact…"
  gitnexus group create "$GROUP" >/dev/null 2>&1 || true
  for n in "${REPO_NAMES[@]}"; do
    gitnexus group add "$GROUP" "$n" "$n" >/dev/null 2>&1 || true
  done
  if gitnexus group sync "$GROUP" >/tmp/gitnexus-group-sync.log 2>&1; then
    links="$(grep -oE '[0-9]+ cross-links' /tmp/gitnexus-group-sync.log | head -1 || true)"
    log "group '$GROUP' synced${links:+ ($links)}"
  else
    log "group sync had warnings (see /tmp/gitnexus-group-sync.log)"
  fi
fi

# Ensure exactly one shared server
if curl -fsS "http://localhost:$PORT/api/health" >/dev/null 2>&1; then
  log "server already running on $PORT — reusing it"
else
  log "starting shared server on $PORT…"
  nohup gitnexus serve --port "$PORT" >/tmp/gitnexus-serve.log 2>&1 &
  disown 2>/dev/null || true
  sleep 2
fi

log "DONE. Run 'gitnexus list' to see all indexed repos."
log "Open Copilot Chat → Agent mode and ask away."