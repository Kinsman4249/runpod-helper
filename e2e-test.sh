#!/usr/bin/env bash
# e2e-test.sh - runs on your own machine, same as startup.sh. Boots a real,
# billed GPU pod end to end and checks it actually works: reachable directly
# over SSH (the pod's own 22/tcp, via resolve_pod_ssh_endpoint() in
# lib/common.sh - no Cloudflare involved), serving real completions through
# RunPod's own per-pod proxy URL, and (optionally) that idle-watchdog.sh
# really shuts it down. Always tears the pod down afterward (pass or fail),
# same as maybe_run_prewarm()'s CPU-pod cleanup in lib/launch.sh.
#
# Exists because every previous attempt at this (see handoff.md) was manual
# and ad hoc, and got derailed by SSH needing a passphrase typed in - fine
# at a keyboard, fatal for a script. setup_ephemeral_ssh_key() in
# lib/common.sh generates a fresh, passphrase-free keypair per launch
# specifically so this script (and anything else non-interactive) can run
# unattended.
#
# Requires `./startup.sh --setup` already completed - this script reuses
# your existing config, it doesn't create one. Does NOT touch
# ~/.runpod-lab/last-session (your normal `./startup.sh` reuse is
# unaffected by running this).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"

PRESET_NAME=""
KEEP_POD=0
CHECK_IDLE_SHUTDOWN=0
IDLE_MINUTES=3
MAX_RUNTIME_HOURS=1
SKIP_SSH_CHECK=0
STORAGE_MODE="network-volume"
NUKE_LOGGING=0
DEBUG=0
GPU_ID_OVERRIDE=""

usage() {
  cat <<EOF
Usage: $0 [--preset NAME] [--keep] [--check-idle-shutdown] [--idle-minutes N] [--skip-ssh-check] [--storage-mode MODE] [--no-logging] [--debug|--debug-quiet]

  --preset NAME            Built-in preset to test (see lib/launch.sh's PRESET_TABLE
                            for values). Defaults to the smallest/fastest-loading one.
                            "custom" is not supported here - it has no known VRAM
                            floor to pick a GPU against.
  --keep                    Don't tear the pod down at the end - leave it running for
                            manual poking. YOU are responsible for stopping/deleting it.
  --check-idle-shutdown     After the smoke checks pass, additionally wait out the idle
                            window and confirm idle-watchdog.sh actually stops/deletes
                            the pod itself, instead of this script tearing it down.
                            Adds roughly --idle-minutes to the run. Ignored with --keep.
  --idle-minutes N          Idle window for this run (default 3 - short on purpose,
                            this is a throwaway test pod, not a real session).
  --skip-ssh-check          Skip the extra on-pod process check (sshd/idle-watchdog/
                            vllm all running, checked over one SSH round trip). SSH
                            itself is still required for the pod to be considered
                            ready at all - see wait_for_pod_ready() in lib/launch.sh.
  --storage-mode MODE       "network-volume" (default) or "container-disk" - see
                            lib/launch.sh. Run this script once with each value (same
                            --preset) to A/B compare: this script prints the wall-clock
                            time from pod-create to vLLM-ready either way, which is the
                            main cost/speed axis that differs between the two modes.
  --no-logging              Passes DISABLE_LOGGING=1 to the pod - see image/entrypoint.sh.
  --gpu-id ID               Skip the "cheapest available" auto-pick and use this exact
                             GPU id (as printed by 'runpodctl gpu list', e.g. the
                             quoted display name). Use when the cheapest GPU meeting
                             the preset's VRAM floor is temporarily out of capacity.
  --debug                   Trace every command (set -x) to both the terminal and a
                            timestamped log file under ~/.runpod-lab/logs. Known secrets
                            are best-effort redacted - NOT guaranteed - skim before
                            pasting the output anywhere.
  --debug-quiet             Same trace, written to the log file only - console stays clean.

Exit status: 0 if every check that ran passed, 1 otherwise.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --preset) PRESET_NAME="$2"; shift ;;
    --keep) KEEP_POD=1 ;;
    --check-idle-shutdown) CHECK_IDLE_SHUTDOWN=1 ;;
    --idle-minutes) IDLE_MINUTES="$2"; shift ;;
    --skip-ssh-check) SKIP_SSH_CHECK=1 ;;
    --storage-mode) STORAGE_MODE="$2"; shift ;;
    --no-logging) NUKE_LOGGING=1 ;;
    --gpu-id) GPU_ID_OVERRIDE="$2"; shift ;;
    --debug) DEBUG=1; DEBUG_MODE="both" ;;
    --debug-quiet) DEBUG=1; DEBUG_MODE="disk" ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done
[[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || die "--idle-minutes needs a number."
[[ "$STORAGE_MODE" == "network-volume" || "$STORAGE_MODE" == "container-disk" ]] \
  || die "--storage-mode must be 'network-volume' or 'container-disk', got '$STORAGE_MODE'."
export STORAGE_MODE NUKE_LOGGING
[[ "$DEBUG" == 1 ]] && enable_debug_logging e2e-test "$DEBUG_MODE"

[[ -f "$CONFIG_FILE" ]] || die "No config at $CONFIG_FILE - run './startup.sh --setup' first. This script reuses that config, it doesn't create one."
# shellcheck source=/dev/null
source "$CONFIG_FILE"
load_secrets
export RUNPOD_API_KEY

log_info "e2e-test.sh starting (build $RUNPOD_LAB_BUILD)."
validate_runpod_api_key

# --- resolve preset (non-interactively - no menus here) ---------------------

resolve_preset() {
  local -a values=() repos=() served=() min_vrams=() ctxs=() quants=()
  local value repo served_name min_vram ctx quant label
  while IFS='|' read -r value repo served_name min_vram ctx quant label; do
    [[ -z "$value" ]] && continue
    values+=("$value"); repos+=("$repo"); served+=("$served_name")
    min_vrams+=("$min_vram"); ctxs+=("$ctx"); quants+=("$quant")
  done <<< "$PRESET_TABLE"

  # Default: cheapest floor + smallest weights, so a routine e2e run costs
  # and waits as little as possible - see PRESET_TABLE for why this one
  # (MoE, ~17GB weights, 24GB floor).
  [[ -z "$PRESET_NAME" ]] && PRESET_NAME="qwen3-coder-30b-moe"

  local i
  for i in "${!values[@]}"; do
    if [[ "${values[$i]}" == "$PRESET_NAME" ]]; then
      MODEL_REPO="${repos[$i]}"
      SERVED_MODEL_NAME="${served[$i]}"
      MODEL_QUANTIZATION="${quants[$i]}"
      MAX_MODEL_LEN="${ctxs[$i]}"
      TEST_MIN_VRAM="${min_vrams[$i]}"
      return
    fi
  done
  die "Unknown preset '$PRESET_NAME' (or it's 'custom', which this script doesn't support - see --help). Check lib/launch.sh's PRESET_TABLE for valid values."
}
resolve_preset
log_info "Preset: $PRESET_NAME ($MODEL_REPO, quantization=$MODEL_QUANTIZATION, min ${TEST_MIN_VRAM}GB VRAM)"

# --- pick the cheapest GPU meeting the floor ---------------------------------

log_info "Fetching live GPU availability for datacenter $DATACENTER_ID..."
gpu_rows="$(list_available_gpus "$TEST_MIN_VRAM")" \
  || die "No GPUs meeting the ${TEST_MIN_VRAM}GB+ VRAM requirement are currently available in datacenter $DATACENTER_ID."
if [[ -n "$GPU_ID_OVERRIDE" ]]; then
  gpu_row="$(grep -F -m1 "$GPU_ID_OVERRIDE"$'\t' <<< "$gpu_rows")" \
    || die "--gpu-id '$GPU_ID_OVERRIDE' isn't in the list of GPUs currently meeting the ${TEST_MIN_VRAM}GB+ floor in $DATACENTER_ID. Run 'runpodctl gpu list' to check the exact id."
  IFS=$'\t' read -r GPU_ID gpu_name gpu_vram gpu_price _stock <<< "$gpu_row"
  log_info "GPU: $gpu_name (${gpu_vram}GB, \$${gpu_price}/hr) - manually selected via --gpu-id."
else
  IFS=$'\t' read -r GPU_ID gpu_name gpu_vram gpu_price _stock <<< "$(head -n1 <<< "$gpu_rows")"
  log_info "GPU: $gpu_name (${gpu_vram}GB, \$${gpu_price}/hr) - cheapest available meeting the floor."
fi

# --- launch -------------------------------------------------------------

if [[ "$STORAGE_MODE" == "network-volume" ]]; then
  ensure_network_volume
fi

PASS=1
POD_CREATED=0

# Runs on every exit path (pass, fail, or Ctrl-C) - a billed GPU pod left
# behind because a check failed partway through would be the worst possible
# outcome for a test script. `|| true` on the runpodctl calls: under `set
# -e`, a failing command inside a trap can take the whole script down with
# it before the trap even finishes (see maybe_run_prewarm()'s identical
# comment in lib/launch.sh) - and these calls are *expected* to occasionally
# fail here too (e.g. --check-idle-shutdown's pod already self-terminated).
cleanup() {
  if [[ "$POD_CREATED" == 1 && "$KEEP_POD" != 1 ]]; then
    log_info ""
    log_info "Tearing down pod $POD_ID..."
    runpodctl_t pod stop "$POD_ID" >/dev/null 2>&1 || true
    runpodctl_t pod delete "$POD_ID" >/dev/null 2>&1 || true
    log_ok "Pod $POD_ID stopped/deleted."
    cleanup_ephemeral_ssh_key
  elif [[ "$POD_CREATED" == 1 ]]; then
    log_warn "--keep passed: pod $POD_ID left running. You are responsible for 'runpodctl pod stop/delete $POD_ID' when done - it is billing right now. The SSH key ($SSH_KEY_FINGERPRINT) is left registered too; remove it yourself later with 'runpodctl ssh remove-key --fingerprint $SSH_KEY_FINGERPRINT'."
  fi
}
trap cleanup EXIT

# Timed from create_pod through vLLM actually serving - the wall-clock axis
# that differs between storage modes: network-volume pays this once (later
# runs skip the download via maybe_run_prewarm/HF_HOME caching),
# container-disk pays it fresh every single run. Run this script once per
# --storage-mode (same --preset) and compare the two numbers this prints,
# alongside lib/launch.sh's CONTAINER_DISK_GB_STANDALONE comment and
# README's storage rate table, to see which is actually cheaper for your
# own launch frequency - deliberately not modeled further here since that
# depends on usage pattern (how often you launch, how long sessions run).
launch_started="$(date +%s)"
create_pod
POD_CREATED=1
wait_for_pod_ready
wait_for_vllm_ready
launch_elapsed=$(( $(date +%s) - launch_started ))
log_info ""
log_info "Timing (storage-mode=$STORAGE_MODE, preset=$PRESET_NAME): ${launch_elapsed}s from pod-create to vLLM-ready."

# --- checks --------------------------------------------------------------

check() {
  local name="$1"; shift
  if "$@"; then
    log_ok "PASS: $name"
  else
    log_error "FAIL: $name"
    PASS=0
  fi
}

check_models_endpoint() {
  curl -fsS --max-time 10 -H "Authorization: Bearer $VLLM_API_KEY" \
    "https://$API_HOSTNAME/v1/models" | grep -qF "\"$SERVED_MODEL_NAME\""
}

check_chat_completion() {
  local resp
  resp="$(curl -fsS --max-time 60 -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "$(printf '{"model":"%s","messages":[{"role":"user","content":"Reply with exactly one word: OK"}],"max_tokens":16}' "$SERVED_MODEL_NAME")" \
    "https://$API_HOSTNAME/v1/chat/completions")" || return 1
  [[ -n "$(jq -r '.choices[0].message.content // empty' <<< "$resp")" ]]
}

check_ssh_processes() {
  # sshd/idle-watchdog/vllm all confirmed up via one round trip, rather
  # than three separate ssh calls each paying the connection cost. Direct
  # pod IP:port, resolved by wait_for_pod_ready() (lib/launch.sh) already -
  # no Cloudflare anywhere in this repo anymore (see CHANGELOG.md).
  ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
    -i "$SSH_KEY_PATH" -p "$SSH_PORT" "root@$SSH_HOST" '
    set -e
    pgrep -x sshd >/dev/null
    pgrep -f "idle-watchdog.sh" >/dev/null
    pgrep -f "vllm serve" >/dev/null
  '
}

log_info ""
log_info "Running checks..."
check "GET /v1/models lists $SERVED_MODEL_NAME" check_models_endpoint
check "POST /v1/chat/completions returns a real completion" check_chat_completion
if [[ "$SKIP_SSH_CHECK" != 1 ]]; then
  check "SSH reachable, sshd/idle-watchdog/vllm all running" check_ssh_processes
else
  log_warn "SKIP: SSH/process checks (--skip-ssh-check passed)."
fi

# --- optional: prove idle-watchdog.sh actually shuts the pod down -----------

if [[ "$CHECK_IDLE_SHUTDOWN" == 1 && "$KEEP_POD" != 1 ]]; then
  log_info ""
  log_info "Waiting out the ${IDLE_MINUTES}m idle window with zero request activity, to confirm idle-watchdog.sh self-terminates the pod..."
  idle_check_waited=0
  # A bit more than IDLE_MINUTES: idle-watchdog.sh polls every 60s and only
  # starts counting from its first post-boot poll, not from pod-create time.
  idle_check_max_wait=$(( (IDLE_MINUTES + 3) * 60 ))
  idle_fired=0
  while (( idle_check_waited < idle_check_max_wait )); do
    if ! runpodctl_t pod get "$POD_ID" >/dev/null 2>&1; then
      idle_fired=1
      break
    fi
    sleep 20; idle_check_waited=$((idle_check_waited + 20))
  done
  if [[ "$idle_fired" == 1 ]]; then
    log_ok "PASS: idle-watchdog.sh stopped/deleted the pod on its own after idling."
    POD_CREATED=0   # already gone - cleanup() shouldn't try again.
  else
    log_error "FAIL: pod $POD_ID still exists after ${idle_check_max_wait}s idle - idle-watchdog.sh did not self-terminate it."
    PASS=0
  fi
fi

log_info ""
if [[ "$PASS" == 1 ]]; then
  log_ok "e2e-test.sh: all checks passed."
  exit 0
else
  log_error "e2e-test.sh: at least one check failed - see above."
  exit 1
fi
