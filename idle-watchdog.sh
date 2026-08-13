#!/usr/bin/env bash
# idle-watchdog.sh - runs ON THE POD, launched detached by
# image/entrypoint.sh. Fetched fresh from this repo's main branch on every
# boot (see entrypoint.sh), not baked into the image.
#
# Polls vLLM's own Prometheus metrics endpoint every 60s. After IDLE_MINUTES
# with no change in completed-request count AND no request currently
# in-flight, stops and deletes this pod via the RunPod API - the actual
# cost-control mechanism for the whole design (the --terminate-after flag
# startup.sh sets at pod-create time is a second, independent backstop in
# case THIS process itself hangs or crashes).
#
# ACTIVITY-DETECTION CAVEAT (flagged per project instructions, not silently
# assumed correct): this replaced an SSH-session-based check (see this
# repo's git history) because the normal workflow is now hitting the OpenAI-
# compatible API directly, often with no SSH session ever open - so SSH
# activity is no longer a meaningful proxy for "in use". Polling vLLM's
# /metrics for vllm:request_success_total (completed count) plus
# vllm:num_requests_running (in-flight count) is the vLLM-documented way to
# see request activity (docs.vllm.ai/en/latest/usage/metrics.html, checked
# 2026-08-12), but this has NOT been verified against a live pod yet - if
# either metric name has changed in the pinned vLLM version, or the counter
# behaves differently than expected, this could shut a pod down mid-use or
# never idle out at all. Confirm on the first real deployment before
# trusting it unattended.
set -uo pipefail   # not -e: a single failed check must not kill the loop.

RUNPOD_LAB_BUILD="2026.08.12"
IDLE_MINUTES="${IDLE_MINUTES:-20}"
DEBUG_LOG="${DEBUG_LOG:-0}"
METRICS_URL="http://localhost:8000/metrics"
LOG_DIR="/workspace/persistent/logs"   # on the network volume, survives pod deletion
LOG_FILE="$LOG_DIR/idle-watchdog.log"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
  echo "$line"
  [[ "$DEBUG_LOG" == 1 ]] && echo "$line" >> "$LOG_FILE" 2>/dev/null
}

# Prints "<completed_total> <running_now>", or empty on any failure (metrics
# endpoint not up yet, e.g. still loading a large model at boot) - callers
# treat a failed read as "can't tell, assume active" rather than as zero
# activity, so a slow model load never gets mistaken for idle.
read_vllm_activity() {
  local metrics
  metrics="$(curl -fsS --max-time 5 "$METRICS_URL" 2>/dev/null)" || return 1
  local completed running
  completed="$(grep -oE '^vllm:request_success_total\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
    | awk '{sum += $2} END {print sum}')"
  running="$(grep -oE '^vllm:num_requests_running\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
    | awk '{sum += $2} END {print sum}')"
  [[ -n "$completed" && -n "$running" ]] || return 1
  printf '%s %s\n' "$completed" "$running"
}

shutdown_pod() {
  log "Idle limit reached with no vLLM request activity."
  local pod_id="${RUNPOD_POD_ID:?RUNPOD_POD_ID not set, cannot self-identify to stop/delete}"
  log "Stopping pod $pod_id..."
  runpodctl pod stop "$pod_id" || log "WARNING: pod stop call failed, attempting delete anyway."
  log "Deleting pod $pod_id..."
  runpodctl pod delete "$pod_id" || log "ERROR: pod delete call failed. Pod may keep running/billing - needs manual cleanup."
  exit 0
}

log "idle-watchdog build $RUNPOD_LAB_BUILD starting. IDLE_MINUTES=$IDLE_MINUTES DEBUG_LOG=$DEBUG_LOG"

idle_seconds=0
idle_limit_seconds=$(( IDLE_MINUTES * 60 ))
last_completed=""

while true; do
  sleep 60
  reading="$(read_vllm_activity)"
  if [[ -z "$reading" ]]; then
    log "Could not read $METRICS_URL - treating as active (not resetting or advancing idle counter)."
    continue
  fi
  read -r completed running <<< "$reading"

  if [[ "$running" != "0" ]] || [[ -n "$last_completed" && "$completed" != "$last_completed" ]]; then
    [[ "$idle_seconds" -gt 0 ]] && log "Activity detected (completed=$completed running=$running) - resetting idle counter."
    idle_seconds=0
  else
    idle_seconds=$(( idle_seconds + 60 ))
    log "No activity (completed=$completed running=$running). Idle for ${idle_seconds}s / ${idle_limit_seconds}s."
    if [[ "$idle_seconds" -ge "$idle_limit_seconds" ]]; then
      shutdown_pod
    fi
  fi
  last_completed="$completed"
done
