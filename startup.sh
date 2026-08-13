#!/usr/bin/env bash
# startup.sh - runs on your own machine, not on the pod.
#
# First run (or --setup): walks through the one-time setup wizard.
# Every run after that: reuses last session's GPU/model choice (unless
# --new is passed), creates a RunPod Secure Cloud pod running vLLM, and
# waits for the OpenAI-compatible endpoint to actually respond through the
# Cloudflare tunnel.
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

SETUP=0
ROTATE=0
NEW_SESSION=0
FORCE_PREWARM=0
PREWARM_ONLY=0
IDLE_MINUTES=20
MAX_RUNTIME_HOURS=4

usage() {
  cat <<EOF
Usage: $0 [--setup] [--rotate] [--new] [--prewarm] [--prewarm-only] [--idle-minutes N] [--max-runtime-hours N]

  --setup                 Force the first-run setup wizard, even if config exists.
  --rotate                Re-paste the RunPod API key and/or Cloudflare tunnel token
                           (whichever got rotated) without redoing the rest of setup.
  --new                   Re-pick GPU/model instead of reusing the last session.
  --prewarm                Force a model-weights prewarm run on a cheap CPU pod even if
                           this volume is already marked prewarmed for this model, then
                           continue to the normal GPU pod launch (see lib/launch.sh).
  --prewarm-only           Run the prewarm (forced) and stop - no GPU pod gets created.
                           Useful for "warm the volume now, launch the real pod later".
  --idle-minutes N        Minutes with no vLLM request activity before the pod
                           auto-shuts-down (default 20).
  --max-runtime-hours N   Hard wall-clock cap on the pod's lifetime, regardless of activity (default 4).
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --setup) SETUP=1 ;;
    --rotate) ROTATE=1 ;;
    --new) NEW_SESSION=1 ;;
    --prewarm) FORCE_PREWARM=1 ;;
    --prewarm-only) FORCE_PREWARM=1; PREWARM_ONLY=1 ;;
    --idle-minutes) IDLE_MINUTES="$2"; shift ;;
    --max-runtime-hours) MAX_RUNTIME_HOURS="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 1 ;;
  esac
  shift
done

[[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || die "--idle-minutes needs a number."
[[ "$MAX_RUNTIME_HOURS" =~ ^[0-9]+$ ]] || die "--max-runtime-hours needs a number."

if [[ ! -f "$CONFIG_FILE" || "$SETUP" == 1 ]]; then
  run_setup_wizard
  exit 0
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"
# runpodctl is a separate process and only reads RUNPOD_API_KEY from its own
# environment, not from vars merely set in this shell - source'ing the plain
# KEY=value line above doesn't export it, so every runpodctl call would
# silently fall back to whatever key is cached in ~/.runpod/config.toml
# instead of the one in $CONFIG_FILE.
export RUNPOD_API_KEY

# Defense in depth: catches a credential file that ended up world/group-
# readable, whether from a tool's own umask or a browser download, on every
# run (not just at setup) so a permission regression doesn't sit unnoticed.
secure_file "$SSH_KEY_PATH"
secure_file "$HOME/.runpod/config.toml"

if [[ "$ROTATE" == 1 ]]; then
  rotate_credentials
  exit 0
fi

# Catches a key/token rotated or revoked outside this repo before anything
# billed happens (network volume creation, pod creation), instead of it
# surfacing later as a confusing runpodctl/cloudflared error.
validate_runpod_api_key
validate_cloudflare_tunnel_token

run_normal_launch
