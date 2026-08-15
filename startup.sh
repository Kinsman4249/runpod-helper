#!/usr/bin/env bash
# startup.sh - runs on your own machine, not on the pod.
#
# First run (or --setup): walks through the one-time setup wizard.
# Every run after that: reuses last session's GPU/model choice (unless
# --new is passed), creates a RunPod Secure Cloud pod running vLLM, and
# waits for the OpenAI-compatible endpoint to actually respond through
# RunPod's own per-pod proxy URL.
#
# See PREREQUISITES.md for what has to exist before the wizard can run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/wizard.sh
source "$SCRIPT_DIR/lib/wizard.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
# shellcheck source=lib/gguf.sh
source "$SCRIPT_DIR/lib/gguf.sh"
# shellcheck source=lib/select.sh
source "$SCRIPT_DIR/lib/select.sh"
# shellcheck source=lib/prewarm.sh
source "$SCRIPT_DIR/lib/prewarm.sh"

SETUP=0
ROTATE=0
NOROTATE=0
NEW_SESSION=0
PREWARM=0
IDLE_MINUTES=20
MAX_RUNTIME_HOURS=4
STORAGE_MODE="network-volume"
NUKE_LOGGING=0
USER_EXTRA_ARGS=""
DEBUG=0

usage() {
  cat <<EOF
Usage: $0 [--setup] [--norotate] [--rotate] [--new] [--prewarm] [--idle-minutes N] [--max-runtime-hours N] [--storage-mode MODE] [--no-logging] [--debug|--debug-quiet]

  --setup                 Force the first-run setup wizard, even if config exists.
  --norotate               With --setup: keep the existing RunPod API key and HF
                           token from the OS keyring instead of re-pasting them, and
                           keep the existing network volume instead of creating a new
                           one, as long as the datacenter you pick is the same one
                           already on file. Picking a different datacenter still
                           creates a new volume (the old one is locked to the old
                           datacenter). Has no effect without --setup.
  --rotate                Re-paste the RunPod API key, without redoing the rest of
                           setup. The vLLM API key and SSH keypair are generated fresh
                           on every launch already - nothing to rotate for either.
  --new                   Re-pick GPU/model instead of reusing the last session.
  --prewarm                Before creating the real (billed-by-the-hour) GPU pod,
                           download the chosen preset's weights onto the network
                           volume via a cheap CPU pod first - see lib/prewarm.sh.
                           Only useful with --storage-mode network-volume (the
                           default); a no-op you don't need on container-disk,
                           since nothing persists there either way. Use
                           e2e-test.sh --prewarm-only instead if you just want to
                           cache a model for later without launching anything.
  --idle-minutes N        Minutes with no vLLM request activity before the pod
                           auto-shuts-down (default 20). 0 disables idle auto-shutdown
                           entirely - see maybe_start_idle_watchdog() in lib/launch.sh.
  --max-runtime-hours N   Hard wall-clock cap on the pod's lifetime, regardless of activity (default 4).
  --storage-mode MODE     "network-volume" (default): weights persist on a billed network
                           volume across pod recreations, so a second launch of the same
                           model skips re-downloading it. "container-disk": no network
                           volume, weights land on a bigger local disk instead (faster
                           reads) but re-download every launch and don't survive the pod
                           being stopped/deleted.
  --no-logging             Disable the engine's stats/access logging for this pod
                           (--disable-log-stats/--disable-uvicorn-access-log for vLLM
                           presets, --log-disable for llama.cpp presets - see ENGINE in
                           lib/launch.sh's PRESET_TABLE), on top of both engines' own
                           default of not logging prompt/response content. See
                           CHANGELOG.md for what this does and does not cover.
  --extra-args "ARGS"      Extra flags appended verbatim to the engine's serve command
                           (vllm serve, or llama-server for llamacpp presets), for a
                           model/quant needing a knob this script doesn't expose - e.g.
                           --extra-args "--rope-scaling yarn --rope-scaling-factor 4"
                           for vLLM, or --extra-args "--split-mode row" for llama.cpp.
                           Space-separated, applied after the preset's own flags (so
                           yours win on any last-one-wins flag). An individual flag's
                           VALUE can't contain spaces. You own their correctness - a bad
                           flag makes the engine fail to boot; watch the pod logs.
  --debug                  Trace every command (set -x) to both the terminal and a
                           timestamped log file under ~/.runpod-lab/logs, tagged with the
                           build number. Use this if something hangs or fails with no
                           clear reason. Known secrets (API keys, tokens) are best-effort
                           redacted - NOT guaranteed - so skim before pasting the output
                           anywhere, same as you would for any debug log.
  --debug-quiet            Same trace, written to the log file only - console stays clean
                           (just the normal prompts/output), for when --debug's live trace
                           makes an interactive wizard run unreadable. The log file won't
                           contain the wizard's own prompt/message text this way, only the
                           trace itself - use --debug instead if you need both.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --setup) SETUP=1 ;;
    --norotate) NOROTATE=1 ;;
    --rotate) ROTATE=1 ;;
    --new) NEW_SESSION=1 ;;
    --prewarm) PREWARM=1 ;;
    --idle-minutes) IDLE_MINUTES="$2"; shift ;;
    --max-runtime-hours) MAX_RUNTIME_HOURS="$2"; shift ;;
    --storage-mode) STORAGE_MODE="$2"; shift ;;
    --no-logging) NUKE_LOGGING=1 ;;
    --extra-args) USER_EXTRA_ARGS="$2"; shift ;;
    --debug) DEBUG=1; DEBUG_MODE="both" ;;
    --debug-quiet) DEBUG=1; DEBUG_MODE="disk" ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

[[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || die "--idle-minutes needs a number."
[[ "$MAX_RUNTIME_HOURS" =~ ^[0-9]+$ ]] || die "--max-runtime-hours needs a number."
[[ "$STORAGE_MODE" == "network-volume" || "$STORAGE_MODE" == "container-disk" ]] \
  || die "--storage-mode must be 'network-volume' or 'container-disk', got '$STORAGE_MODE'."
export STORAGE_MODE PREWARM USER_EXTRA_ARGS NOROTATE
[[ "$DEBUG" == 1 ]] && enable_debug_logging startup "$DEBUG_MODE"
[[ "$NOROTATE" == 1 && "$SETUP" != 1 ]] && log_warn "--norotate has no effect without --setup."

if [[ ! -f "$CONFIG_FILE" || "$SETUP" == 1 ]]; then
  run_setup_wizard
  exit 0
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
# Populates RUNPOD_API_KEY from the OS keyring (migrating it out of the
# file above if this is a pre-keyring config) - see load_secrets() in
# lib/common.sh.
load_secrets
# runpodctl is a separate process and only reads RUNPOD_API_KEY from its own
# environment, not from vars merely set in this shell - the value load_secrets
# just set in this shell doesn't export it, so every runpodctl call would
# silently fall back to whatever key is cached in ~/.runpod/config.toml
# instead of the one just loaded.
export RUNPOD_API_KEY

# Defense in depth: catches a credential file that ended up world/group-
# readable, whether from a tool's own umask or a browser download, on every
# run (not just at setup) so a permission regression doesn't sit unnoticed.
secure_file "$HOME/.runpod/config.toml"

if [[ "$ROTATE" == 1 ]]; then
  rotate_credentials
  exit 0
fi

# Catches a key rotated or revoked outside this repo before anything billed
# happens (network volume creation, pod creation), instead of it surfacing
# later as a confusing runpodctl error.
validate_runpod_api_key

run_normal_launch
