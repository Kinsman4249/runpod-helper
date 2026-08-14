#!/usr/bin/env bash
# entrypoint.sh - this image's ENTRYPOINT (see ../Dockerfile). Runs on every
# boot: starts sshd (reachable directly over the pod's own 22/tcp - see
# resolve_pod_ssh_endpoint() in ../lib/common.sh, no tunnel involved),
# fetches and starts idle-watchdog.sh fresh from this repo's main branch
# (so a repo update takes effect on the next pod launch without an image
# rebuild - repo must stay public for this unauthenticated curl to work),
# then either downloads weights and self-terminates (PREWARM_ONLY) or execs
# into `vllm serve` (normal launch). The OpenAI-compatible endpoint itself
# needs nothing started here at all - RunPod auto-exposes whatever port
# vllm serve listens on (8000) at https://<pod-id>-8000.proxy.runpod.net.
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

# --- SSH IP pinning: lock 22/tcp to whichever IP connects first ------------
# The pod's SSH port is otherwise reachable, over its whole lifetime, by
# anyone who has the ephemeral key from create_pod() AND finds the pod's
# IP/port - both true only for the operator who just launched it, but
# "true only for" isn't the same as "provably restricted to". This watcher
# waits for the FIRST established connection on port 22, then inserts an
# iptables rule that ACCEPTs only that source IP and DROPs everything else
# to the port from then on - firewall-level, no sshd/auth involvement, so
# even a leaked key stops being useful for a login from anywhere else.
# One-way and irreversible for this pod's lifetime by design, matching the
# ephemeral-pod model this whole repo runs on (see create_pod() in
# ../lib/launch.sh): a locked-out IP just means recreate the pod, which
# generates a fresh key and re-arms this lock against the new first
# connection. Not yet independently confirmed whether RunPod's proxy in
# front of a pod's public IP:port preserves the real client IP here vs.
# substituting its own gateway IP - if it substitutes, this degrades to
# "locked to RunPod's own edge" rather than "locked to your home IP", but
# never causes a false lockout of the legitimate operator (same address
# either way, every reconnect), and is still strictly tighter than no lock.
# Polls every 0.5s rather than sshd/PAM hooking into the actual auth event
# (which would be race-free) - a deliberate simplicity tradeoff, not
# unconsidered: PAM config differs enough across base images that editing
# it blind, with no way to test against this exact image before it ships,
# risks breaking SSH login entirely, which is a much worse failure mode
# than this watcher's only real gap (a connection so short it comes and
# goes between two 0.5s polls, which a real interactive SSH session or
# even a quick `ssh host true` round trip - handshake, auth, command,
# FIN - is very unlikely to do).
lock_ssh_to_first_client() {
  local waited_ms=0 max_wait_ms=600000 peer
  while (( waited_ms < max_wait_ms )); do
    peer="$(ss -Htn state established '( sport = :22 )' 2>/dev/null | awk '{print $4}' | sed -E 's/:[0-9]+$//' | head -n1)"
    if [[ -n "$peer" ]]; then
      if iptables -I INPUT -p tcp --dport 22 -s "$peer" -j ACCEPT \
          && iptables -A INPUT -p tcp --dport 22 -j DROP; then
        echo "SSH locked to first client IP: $peer (see entrypoint.sh's lock_ssh_to_first_client)."
      else
        echo "WARNING: iptables rule insert failed (container may lack CAP_NET_ADMIN) - SSH IP lock did NOT arm, port 22 stays open to anyone with the key." >&2
      fi
      return
    fi
    sleep 0.5; waited_ms=$((waited_ms + 500))
  done
  echo "WARNING: no SSH connection seen within $((max_wait_ms / 1000))s - the IP lock never armed, port 22 stays open to anyone with the key. Connect once soon if you want it locked." >&2
}
if command -v iptables >/dev/null 2>&1; then
  lock_ssh_to_first_client >"$RUN_DIR/ssh-iplock.log" 2>&1 &
  echo $! > "$RUN_DIR/ssh-iplock.pid"
else
  echo "WARNING: iptables not found - SSH IP-pinning is disabled, port 22 stays open to anyone with the key." >&2
fi

DISABLE_LOGGING="${DISABLE_LOGGING:-0}"

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
# ENTRYPOINT. --api-key gates the endpoint with a one-off bearer token
# generated fresh per launch (see create_pod() in ../lib/launch.sh) - this
# port's RunPod proxy URL is otherwise open to anyone who guesses it, so
# the bearer token is the only gate it has.
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
# own console "Logs" view captures - that's the whole of "nuke logging"
# now that cloudflared (which used to have its own disk log) is gone.
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
