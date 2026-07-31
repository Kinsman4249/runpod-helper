#!/usr/bin/env bash
# safety-commit.sh - runs ON THE POD, called by idle-watchdog.sh right
# before it stops/deletes the pod (also safe to run by hand any time).
#
# For every git repo found under /workspace with uncommitted changes,
# pushes everything to a timestamped safety branch. Never blocks shutdown:
# a hung push here costs money (the pod keeps running while it waits), so
# every failure is logged loudly and swallowed rather than propagated.
set -uo pipefail   # not -e: one repo's failure must not stop the others.

RUNPOD_LAB_BUILD="2026.07.30"
LOG_DIR="/workspace/persistent/logs"
LOG_FILE="$LOG_DIR/safety-commit.log"
SEARCH_ROOT="/workspace"
BRANCH_NAME="safety/auto-$(date -u +%Y%m%d-%H%M%S)"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

log "safety-commit build $RUNPOD_LAB_BUILD starting. Branch: $BRANCH_NAME"

committed=0
clean=0

# maxdepth 4 keeps this from wandering into node_modules/.venv/etc repos
# nested inside a checkout; adjust if repos live deeper than that.
while IFS= read -r -d '' git_dir; do
  repo_dir="$(dirname "$git_dir")"
  ( cd "$repo_dir" || exit 1

    if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
      log "CLEAN: $repo_dir"
      exit 0   # 0 = clean, nothing to do
    fi

    log "CHANGES FOUND: $repo_dir - snapshotting to $BRANCH_NAME"
    if ! git checkout -b "$BRANCH_NAME" 2>>"$LOG_FILE"; then
      log "ERROR: could not create branch $BRANCH_NAME in $repo_dir - skipping (uncommitted changes left as-is)."
      exit 1   # 1 = error
    fi
    git add -A
    if ! git commit -m "Automatic safety snapshot before pod shutdown" >>"$LOG_FILE" 2>&1; then
      log "ERROR: commit failed in $repo_dir."
      exit 1   # 1 = error
    fi
    if git push -u origin "$BRANCH_NAME" >>"$LOG_FILE" 2>&1; then
      log "PUSHED: $repo_dir -> $BRANCH_NAME"
    else
      log "ERROR: push failed for $repo_dir (branch $BRANCH_NAME committed locally but not on the remote - this repo's code disk is about to be destroyed, so this snapshot will be lost)."
    fi
    exit 2   # 2 = a safety commit was made (push may or may not have succeeded - already logged above)
  )
  case $? in
    0) clean=$((clean + 1)) ;;
    2) committed=$((committed + 1)) ;;
    *) ;;   # errors already logged inline; not counted in either bucket
  esac
done < <(find "$SEARCH_ROOT" -maxdepth 4 -name .git -type d -print0 2>/dev/null)

log "Done. Repos with a safety commit attempted: $committed. Clean repos: $clean."
