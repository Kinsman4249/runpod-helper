#!/usr/bin/env bash
# idle-watchdog.sh - runs on YOUR machine (launched detached by
# maybe_start_idle_watchdog() in lib/launch.sh), not on the pod. Moved off
# the pod 2026-08-14 along with the custom image: the bare
# vllm/vllm-openai image has a fixed ENTRYPOINT ["vllm", "serve"] with no
# room for a second background process, so there's nowhere left on-pod to
# host this. This also means: no RUNPOD_API_KEY needs to sit on the pod
# anymore just so this script could call the RunPod API to self-terminate
# - that credential now never leaves your machine (a real security win, not
# just a side effect of the image removal).
#
# Polls the engine's own Prometheus metrics endpoint (through RunPod's
# proxy, same path a real client uses) every 60s. After IDLE_MINUTES with
# no change in completed-request count AND no request currently in-flight,
# stops and deletes the pod via runpodctl_t - the actual cost-control
# mechanism for the whole design (the --terminate-after flag create_pod()
# sets at pod-create time is a second, independent backstop in case THIS
# process itself hangs, crashes, or your machine goes to sleep/shuts down).
#
# ACTIVITY-DETECTION CAVEAT (flagged per project instructions, not silently
# assumed correct): polling vLLM's /metrics for vllm:request_success_total
# (completed count) plus vllm:num_requests_running (in-flight count) is the
# vLLM-documented way to see request activity
# (docs.vllm.ai/en/latest/usage/metrics.html, checked 2026-08-12); the
# llamacpp branch (added 2026-08-14) uses llamacpp:tokens_predicted_total
# (completed proxy - llama-server has no direct completed-request counter)
# plus llamacpp:requests_processing (in-flight), per
# github.com/ggml-org/llama.cpp tools/server/README.md - --metrics must be
# passed to llama-server (create_pod() in lib/launch.sh already does this
# unconditionally for the llamacpp engine) since it's disabled by default.
# Neither metric-based approach has been verified against a live pod under
# real request load yet - if a metric name has changed in the pinned image
# version, or a counter behaves differently than expected, this could shut
# a pod down mid-use or never idle out at all. Confirm on the first real
# deployment before trusting it unattended.
#
# Usage: idle-watchdog.sh <pod_id> <api_hostname> <api_key> <idle_minutes> <engine>
# <engine> is "vllm" or "llamacpp" - selects which metric names to poll.
# Requires RUNPOD_API_KEY already exported in this process's environment
# (see maybe_start_idle_watchdog(), lib/launch.sh) and lib/common.sh
# sourceable relative to this script's own location.
set -uo pipefail   # not -e: a single failed check must not kill the loop.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

POD_ID="${1:?usage: idle-watchdog.sh <pod_id> <api_hostname> <api_key> <idle_minutes> <engine>}"
API_HOSTNAME="${2:?missing api_hostname}"
VLLM_API_KEY="${3:?missing api_key}"
IDLE_MINUTES="${4:?missing idle_minutes}"
ENGINE="${5:-vllm}"
[[ -n "${RUNPOD_API_KEY:-}" ]] || die "RUNPOD_API_KEY not set in idle-watchdog.sh's environment - cannot self-authenticate to stop/delete the pod."

mkdir -p "$CONFIG_DIR/logs"
LOG_FILE="$CONFIG_DIR/logs/idle-watchdog-$POD_ID.log"

log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG_FILE"
}

# Prints "<completed_total> <running_now>", or empty on any failure (metrics
# endpoint not up yet, e.g. still loading a large model, or a transient
# network hiccup reaching the proxy) - callers treat a failed read as
# "can't tell, assume active" rather than as zero activity, so neither a
# slow model load nor a flaky connection gets mistaken for idle.
read_engine_activity() {
  local metrics
  metrics="$(curl -fsS --max-time 10 -H "Authorization: Bearer $VLLM_API_KEY" \
    "https://$API_HOSTNAME/metrics" 2>/dev/null)" || return 1
  local completed running
  if [[ "$ENGINE" == "llamacpp" ]]; then
    completed="$(grep -oE '^llamacpp:tokens_predicted_total\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
      | awk '{sum += $2} END {print sum}')"
    running="$(grep -oE '^llamacpp:requests_processing\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
      | awk '{sum += $2} END {print sum}')"
  else
    completed="$(grep -oE '^vllm:request_success_total\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
      | awk '{sum += $2} END {print sum}')"
    running="$(grep -oE '^vllm:num_requests_running\{[^}]*\} [0-9.e+]+' <<< "$metrics" \
      | awk '{sum += $2} END {print sum}')"
  fi
  [[ -n "$completed" && -n "$running" ]] || return 1
  printf '%s %s\n' "$completed" "$running"
}

shutdown_pod() {
  log "Idle limit reached with no vLLM request activity."
  log "Stopping pod $POD_ID..."
  runpodctl_t pod stop "$POD_ID" >/dev/null || log "WARNING: pod stop call failed or timed out, attempting delete anyway."
  log "Deleting pod $POD_ID..."
  runpodctl_t pod delete "$POD_ID" >/dev/null || log "ERROR: pod delete call failed or timed out. Pod may keep running/billing - needs manual cleanup."
  exit 0
}

log "idle-watchdog build $RUNPOD_LAB_BUILD starting for pod $POD_ID. IDLE_MINUTES=$IDLE_MINUTES"

idle_seconds=0
idle_limit_seconds=$(( IDLE_MINUTES * 60 ))
last_completed=""

while true; do
  sleep 60
  # Stop watching (without touching the pod) once it's gone - covers the
  # pod being torn down some other way (e.g. --terminate-after firing, or
  # the operator stopping it by hand) so this process doesn't loop forever
  # against a pod that no longer exists.
  if ! runpodctl_t pod get "$POD_ID" >/dev/null 2>&1; then
    log "Pod $POD_ID no longer exists - stopping watch."
    exit 0
  fi

  reading="$(read_engine_activity)"
  if [[ -z "$reading" ]]; then
    log "Could not read https://$API_HOSTNAME/metrics - treating as active (not resetting or advancing idle counter)."
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
