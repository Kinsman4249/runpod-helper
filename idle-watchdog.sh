#!/usr/bin/env bash
# idle-watchdog.sh - runs ON THE POD, launched detached by onstart.sh.
#
# Polls every 60s for an active SSH session. After IDLE_MINUTES with zero
# sessions, runs safety-commit.sh, then stops and deletes this pod via the
# RunPod API - the actual cost-control mechanism for the whole design (the
# --terminate-after flag startup.sh sets at pod-create time is a second,
# independent backstop in case THIS process itself hangs or crashes).
#
# SESSION-DETECTION CAVEAT (flagged per project instructions, not silently
# assumed correct): SSH here arrives via cloudflared's tunnel, not a direct
# connection. `who` reflects PAM/utmp login sessions, which should be
# created normally by sshd regardless of how the TCP got to it (cloudflared
# is just forwarding bytes to localhost:22; sshd does full protocol
# negotiation as usual) - but this has NOT been verified against a live
# proxied session. `ss` on established port-22 connections is checked too,
# as a second signal, in case one under-counts. Confirm both actually
# reflect reality on the first real deployment before trusting this
# unattended - if this misdetects, the pod could delete itself out from
# under an active session, or never idle out at all.
set -uo pipefail   # not -e: a single failed check must not kill the loop.

RUNPOD_LAB_BUILD="2026.07.30"
IDLE_MINUTES="${IDLE_MINUTES:-20}"
DEBUG_LOG="${DEBUG_LOG:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="/workspace/persistent/logs"   # on the network volume, survives pod deletion
LOG_FILE="$LOG_DIR/idle-watchdog.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  echo "$line"
  [[ "$DEBUG_LOG" == 1 ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null
}

active_session_count() {
  local via_who via_ss
  via_who="$(who 2>/dev/null | wc -l)"
  via_ss="$(ss -tn state established '( dport = :22 or sport = :22 )' 2>/dev/null | tail -n +2 | wc -l)"
  echo $(( via_who > via_ss ? via_who : via_ss ))
}

shutdown_pod() {
  log "Idle limit reached with zero active sessions. Running safety-commit.sh..."
  "$SCRIPT_DIR/safety-commit.sh"

  # Confirmed auto-injected env var: docs.runpod.io/pods/templates/environment-variables
  local pod_id="${RUNPOD_POD_ID:?RUNPOD_POD_ID not set, cannot self-identify to stop/delete}"
  log "Stopping pod $pod_id..."
  runpodctl pod stop "$pod_id" || log "WARNING: pod stop call failed, attempting delete anyway."
  log "Deleting pod $pod_id..."
  # No documented API operation detaches a network volume from a pod
  # without deleting the pod (confirmed absent from both the REST PATCH
  # schema and `runpodctl pod update`) - deleting the pod is the only
  # documented way to release the attachment, so that's all this does.
  runpodctl pod delete "$pod_id" || log "ERROR: pod delete call failed. Pod may keep running/billing - needs manual cleanup."
  exit 0
}

log "idle-watchdog build $RUNPOD_LAB_BUILD starting. IDLE_MINUTES=$IDLE_MINUTES DEBUG_LOG=$DEBUG_LOG"

idle_seconds=0
idle_limit_seconds=$(( IDLE_MINUTES * 60 ))

while true; do
  sleep 60
  count="$(active_session_count)"
  if [[ "$count" -gt 0 ]]; then
    [[ "$idle_seconds" -gt 0 ]] && log "Session detected ($count) - resetting idle counter."
    idle_seconds=0
  else
    idle_seconds=$(( idle_seconds + 60 ))
    log "No active sessions. Idle for ${idle_seconds}s / ${idle_limit_seconds}s."
    if [[ "$idle_seconds" -ge "$idle_limit_seconds" ]]; then
      shutdown_pod
    fi
  fi
done
