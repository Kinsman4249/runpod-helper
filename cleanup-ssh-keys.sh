#!/usr/bin/env bash
# cleanup-ssh-keys.sh - runs on YOUR machine, not on a pod.
#
# Finds and removes orphaned ephemeral SSH keys left behind in your RunPod
# account by setup_ephemeral_ssh_key() (lib/common.sh). Every launch
# registers a fresh one-off keypair there, and cleanup_ephemeral_ssh_key()
# removes it again at teardown - but that removal is best-effort (a
# network hiccup, a killed process, or Ctrl-C before its trap runs all skip
# it silently, only logging a warning telling you to remove it by hand).
# Nothing else in this repo ever cleans those up, so they accumulate in
# your account's SSH key list over time. This script finds them by name -
# they're always named "runpod-lab-ephemeral-<unix-timestamp>", set as the
# key comment in setup_ephemeral_ssh_key() - and removes them via
# `runpodctl ssh remove-key`.
#
# Safe to run any time, including with a launch currently in progress: per
# README.md's Testing section, this ephemeral key is used ONLY for the
# diagnostics-only SSH-over-proxy path (resolve_pod_ssh_proxy_host() in
# lib/common.sh) - the bare vLLM/llama.cpp images have no sshd, so nothing
# in the normal launch, serving, idle-watchdog, or teardown flow depends on
# it. Removing a key belonging to a pod that's still running just means you
# lose ad-hoc SSH diagnostics into that pod until you relaunch it; billing,
# the endpoint, and auto-shutdown are unaffected. Only ever touches keys
# matching the exact ephemeral-key name pattern - never a key you added to
# the account by hand.
#
# Usage:
#   ./cleanup-ssh-keys.sh                        list orphaned keys, confirm, then remove them
#   ./cleanup-ssh-keys.sh --dry-run              list only, never prompts or removes anything
#   ./cleanup-ssh-keys.sh --yes                  skip the confirmation prompt
#   ./cleanup-ssh-keys.sh --older-than-hours N   only target keys older than N hours (default 0 = all)
#   ./cleanup-ssh-keys.sh --debug                trace every command, console + log file
#   ./cleanup-ssh-keys.sh --debug-quiet          same trace, log file only
#   ./cleanup-ssh-keys.sh --help                 show this help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Bump whenever this script's matching/removal logic changes. Only shown in
# --debug output.
BUILD="2026.08.15-1"

KEY_NAME_RE='^runpod-lab-ephemeral-[0-9]+$'

DRY_RUN=0
ASSUME_YES=0
OLDER_THAN_HOURS=0
DEBUG=0
DEBUG_MODE="both"

usage() {
  cat <<EOF
Usage: $0 [--dry-run] [--yes] [--older-than-hours N] [--debug|--debug-quiet]

Removes orphaned "runpod-lab-ephemeral-*" SSH keys left in your RunPod
account by launches that didn't clean up after themselves (crash, kill,
Ctrl-C). Never touches a key you added by hand.

  --dry-run              List matching keys and their age, remove nothing.
  --yes                  Skip the "remove these keys?" confirmation prompt.
  --older-than-hours N   Only target keys older than N hours (default 0,
                         meaning every matched key regardless of age).
  --debug                Trace every command (console + log file).
  --debug-quiet          Same trace, log file only.
  --help                 Show this help.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --yes|-y)
      ASSUME_YES=1
      shift
      ;;
    --older-than-hours)
      [ -n "${2:-}" ] || die "--older-than-hours requires a number."
      OLDER_THAN_HOURS="$2"
      shift 2
      ;;
    --older-than-hours=*)
      OLDER_THAN_HOURS="${1#*=}"
      shift
      ;;
    --debug)
      DEBUG=1
      DEBUG_MODE="both"
      shift
      ;;
    --debug-quiet)
      DEBUG=1
      DEBUG_MODE="disk"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

[[ "$OLDER_THAN_HOURS" =~ ^[0-9]+$ ]] \
  || die "--older-than-hours must be a non-negative integer, got '$OLDER_THAN_HOURS'."

if [[ "$DEBUG" == 1 ]]; then
  enable_debug_logging cleanup-ssh-keys "$DEBUG_MODE"
  log_info "[debug] cleanup-ssh-keys.sh build $BUILD"
fi

[[ -f "$CONFIG_FILE" ]] || die "No config found at $CONFIG_FILE. Run 'startup.sh --setup' first."
# shellcheck source=/dev/null
source "$CONFIG_FILE"
# Populates RUNPOD_API_KEY from the OS keyring - see load_secrets() in
# lib/common.sh.
load_secrets
export RUNPOD_API_KEY

require_cmd runpodctl
require_cmd jq

# Converts a duration in seconds to a short human string ("3d 4h", "2h 5m",
# "40m") for the listing below.
format_age() {
  local secs="$1" d h m
  d=$(( secs / 86400 ))
  h=$(( (secs % 86400) / 3600 ))
  m=$(( (secs % 3600) / 60 ))
  if [[ "$d" -gt 0 ]]; then
    printf '%dd %dh' "$d" "$h"
  elif [[ "$h" -gt 0 ]]; then
    printf '%dh %dm' "$h" "$m"
  else
    printf '%dm' "$m"
  fi
}

log_info "Fetching SSH keys registered on your RunPod account..."
KEYS_JSON="$(runpodctl_t ssh list-keys -o json)" \
  || die "Failed to list SSH keys from RunPod (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s)."

MATCHED="$(jq -c --arg re "$KEY_NAME_RE" '[.keys[]? | select(.name | test($re))]' <<< "$KEYS_JSON")"
MATCH_COUNT="$(jq 'length' <<< "$MATCHED")"

if [[ "$MATCH_COUNT" -eq 0 ]]; then
  log_ok "No orphaned runpod-lab ephemeral SSH keys found - nothing to clean up."
  exit 0
fi

NOW_EPOCH="$(date +%s)"
CUTOFF_SECONDS=$(( OLDER_THAN_HOURS * 3600 ))

# Extract each key's embedded creation timestamp (from its name), compute
# age, and drop anything younger than --older-than-hours before this ever
# reaches the confirm prompt.
TO_REMOVE="$(jq -c --argjson now "$NOW_EPOCH" --argjson cutoff "$CUTOFF_SECONDS" '
  map(.created_epoch = (.name | capture("runpod-lab-ephemeral-(?<ts>[0-9]+)").ts | tonumber))
  | map(.age_seconds = ($now - .created_epoch))
  | map(select(.age_seconds >= $cutoff))
' <<< "$MATCHED")"
TO_REMOVE_COUNT="$(jq 'length' <<< "$TO_REMOVE")"

if [[ "$TO_REMOVE_COUNT" -eq 0 ]]; then
  log_ok "$MATCH_COUNT orphaned key(s) found, but none older than ${OLDER_THAN_HOURS}h - nothing to clean up."
  exit 0
fi

log_info "Found $TO_REMOVE_COUNT orphaned ephemeral SSH key(s):"
printf '%-38s %-24s %s\n' "NAME" "FINGERPRINT" "AGE"
while IFS=$'\t' read -r name fingerprint age_seconds; do
  printf '%-38s %-24s %s\n' "$name" "$fingerprint" "$(format_age "$age_seconds")"
done < <(jq -r '.[] | [.name, .fingerprint, .age_seconds] | @tsv' <<< "$TO_REMOVE")

if [[ "$DRY_RUN" == 1 ]]; then
  log_info "Dry run - nothing removed."
  exit 0
fi

if [[ "$ASSUME_YES" != 1 ]]; then
  confirm "Remove these $TO_REMOVE_COUNT key(s) from your RunPod account?" \
    || { log_info "Aborted - nothing removed."; exit 0; }
fi

FAILED=0
while IFS=$'\t' read -r name fingerprint; do
  if runpodctl_t ssh remove-key --fingerprint "$fingerprint" >/dev/null 2>&1; then
    log_ok "Removed $name ($fingerprint)."
  else
    log_warn "Failed to remove $name ($fingerprint) - remove it by hand at https://www.runpod.io/console/user/settings if you want it fully revoked."
    FAILED=1
  fi
done < <(jq -r '.[] | [.name, .fingerprint] | @tsv' <<< "$TO_REMOVE")

if [[ "$FAILED" == 0 ]]; then
  log_ok "Done - all $TO_REMOVE_COUNT orphaned key(s) removed."
else
  exit 1
fi
