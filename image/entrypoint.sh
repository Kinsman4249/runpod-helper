#!/usr/bin/env bash
# entrypoint.sh - this image's ENTRYPOINT (see ../Dockerfile). Runs on every
# boot: starts sshd (diagnostics only), starts the Cloudflare Tunnel so the
# stable hostname reaches whichever pod is currently up, fetches and starts
# idle-watchdog.sh fresh from this repo's main branch (so a repo update
# takes effect on the next pod launch without an image rebuild - repo must
# stay public for this unauthenticated curl to work), then either downloads
# weights and self-terminates (PREWARM_ONLY) or execs into `vllm serve`
# (normal launch).
set -euo pipefail

RUN_DIR="/run/runpod-lab"
SCRIPT_DIR="/opt/runpod-lab"
PERSIST_DIR="/workspace/persistent"
REPO_RAW_BASE="https://raw.githubusercontent.com/Kinsman4249/runpod-helper/main"

mkdir -p "$RUN_DIR" "$PERSIST_DIR/logs"
echo "entrypoint.sh starting."

# HF_HOME on the network volume: weights persist across pod recreations, so
# a second launch of the same model preset skips the multi-GB download
# entirely instead of re-fetching it every time the pod disk is destroyed.
export HF_HOME="$PERSIST_DIR/hf-cache"
mkdir -p "$HF_HOME"

# --- sshd (diagnostics only - not the readiness signal for anything below) --
mkdir -p /run/sshd "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ -n "${PUBLIC_KEY:-}" ]]; then
  echo "$PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
fi
ssh-keygen -A >/dev/null
# Non-fatal on purpose: this script is PID 1 under `set -euo pipefail` - a
# raw sshd failure exiting non-zero here would kill PID 1 and the whole
# container with it. Confirmed live with the prior image (2026-08-01) that
# this exact failure mode happens and is worth guarding against.
service ssh start || echo "WARNING: sshd failed to start - SSH access to this pod will not work. Continuing anyway." >&2

# --- cloudflared: one tunnel, two Public Hostname routes (SSH + API) -------
# Ingress rules live in Cloudflare's dashboard config for the named tunnel
# (set up once during the local wizard's Cloudflare step), not a local
# config.yml - token-based `cloudflared tunnel run` picks up dashboard-
# defined routes automatically.
DISABLE_LOGGING="${DISABLE_LOGGING:-0}"
echo "Starting cloudflared tunnel..."
if [[ "$DISABLE_LOGGING" == 1 ]]; then
  # DISABLE_LOGGING=1: don't even keep cloudflared's own connection log
  # around on disk - it holds no request content, just tunnel-connection
  # noise, but "nuke logging" means nuke it too.
  nohup cloudflared tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN not set}" \
    >/dev/null 2>&1 &
else
  nohup cloudflared tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN not set}" \
    >"$RUN_DIR/cloudflared.log" 2>&1 &
fi
echo $! > "$RUN_DIR/cloudflared.pid"

# --- PREWARM_ONLY: download weights onto the volume, then self-terminate ---
# Mirrors the prior image's CPU-pod prewarm idiom: a cheap CPU pod pays for
# the download instead of an expensive GPU pod sitting there while it
# happens. RunPod restarts a pod's container on ANY exit including a clean
# `exit 0` (confirmed live 2026-08-01), so this pod must stop/delete itself
# via the RunPod API rather than just exiting - see maybe_run_prewarm() in
# ../../lib/launch.sh for the caller-side wait loop this pairs with.
if [[ "${PREWARM_ONLY:-0}" == 1 ]]; then
  echo "PREWARM_ONLY: downloading ${MODEL_REPO:?MODEL_REPO not set} into $HF_HOME..."
  huggingface-cli download "$MODEL_REPO"
  echo "Prewarm download done. Self-terminating via runpodctl..."
  pod_id="${RUNPOD_POD_ID:?RUNPOD_POD_ID not set, cannot self-identify to stop/delete}"
  export RUNPOD_API_KEY="${RUNPOD_API_KEY:?RUNPOD_API_KEY not set}"
  timeout 20 runpodctl pod stop "$pod_id" || true
  timeout 20 runpodctl pod delete "$pod_id" || true
  # Fallback if the API calls above didn't actually remove the pod: sleep
  # instead of exiting, so RunPod's restart-on-exit behavior doesn't loop
  # this download forever.
  sleep infinity
fi

# --- idle watchdog (fetched fresh so a repo fix applies without a rebuild) --
curl -fsSL "$REPO_RAW_BASE/idle-watchdog.sh" -o "$SCRIPT_DIR/idle-watchdog.sh"
chmod +x "$SCRIPT_DIR/idle-watchdog.sh"
echo "Starting idle-watchdog.sh..."
nohup "$SCRIPT_DIR/idle-watchdog.sh" >"$RUN_DIR/idle-watchdog.log" 2>&1 &
echo $! > "$RUN_DIR/idle-watchdog.pid"

# --- hand off to vLLM's own OpenAI-compatible server ------------------------
# `exec` (not a backgrounded call) so this process becomes PID 1's
# replacement: vllm serve's own exit/crash is what RunPod's container
# restart policy reacts to, same as if it had been the image's original
# ENTRYPOINT. --api-key gates the endpoint with a bearer token (see
# lib/wizard.sh's vLLM API key step) since the Public Hostname for this
# port is deliberately NOT put behind Cloudflare Access - most OpenAI-
# compatible client tools can set a bearer token but can't add Access's
# custom CF-Access-Client-Id/Secret headers.
# QUANTIZATION defaults to "auto" (vLLM's own default: detect from the
# repo's config.json) for every built-in preset except the ones that need
# on-the-fly quantization of an unquantized checkpoint (e.g. fp8) - see
# PRESET_TABLE in ../../lib/launch.sh. Old saved sessions from before this
# var existed won't set it either, same default applies.
QUANTIZATION="${QUANTIZATION:-auto}"
echo "Starting vllm serve: model=${MODEL_REPO:?MODEL_REPO not set} served-as=${SERVED_MODEL_NAME:?SERVED_MODEL_NAME not set} max-model-len=${MAX_MODEL_LEN:?MAX_MODEL_LEN not set} quantization=$QUANTIZATION disable-logging=$DISABLE_LOGGING"

# vLLM's own --enable-log-requests/--enable-log-outputs already default to
# False (docs.vllm.ai/en/stable/cli/serve/, checked 2026-08-13) - prompt/
# response content is never logged by this repo's default invocation either
# way. DISABLE_LOGGING=1 additionally silences what IS logged by default:
# --disable-log-stats (throughput/request-count stats, no content) and
# --disable-uvicorn-access-log (HTTP access lines - method/path/status/
# client IP). Both would otherwise land on stdout, which is what RunPod's
# own console "Logs" view captures - this is the "console" half of "nuke
# logging"; cloudflared's disk log above is the other half.
declare -a vllm_log_flags=()
if [[ "$DISABLE_LOGGING" == 1 ]]; then
  vllm_log_flags=(--disable-log-stats --disable-uvicorn-access-log)
fi
exec vllm serve "$MODEL_REPO" \
  --host 0.0.0.0 \
  --port 8000 \
  --served-model-name "$SERVED_MODEL_NAME" \
  --max-model-len "$MAX_MODEL_LEN" \
  --quantization "$QUANTIZATION" \
  --api-key "${VLLM_API_KEY:?VLLM_API_KEY not set}" \
  "${vllm_log_flags[@]}"
