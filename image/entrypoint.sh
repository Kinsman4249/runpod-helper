#!/usr/bin/env bash
# entrypoint.sh - the image's ENTRYPOINT. Runs before onstart.sh on every
# boot: gets the toolchain, model weights, and inference backend + chosen
# frontend up first, then hands off to onstart.sh (baked in at image build
# time, see Dockerfile) for cloudflared + the idle watchdog. Not fetched
# from GitHub at runtime like idle-watchdog.sh/safety-commit.sh are - this
# file only exists inside the image.
#
# PREWARM_ONLY=1 short-circuits this into a tools+model-download-only run
# with no llama-server, no frontend, no onstart.sh handoff - see
# ensure_tools() and maybe_run_prewarm() in ../lib/launch.sh. The point is
# a cheap CPU pod can pay for that download time instead of an expensive
# GPU pod sitting idle while it happens.
set -euo pipefail

RUN_DIR="/run/runpod-lab"
PERSIST_DIR="/workspace/persistent"
TOOLS_DIR="$PERSIST_DIR/tools"
BIN_DIR="$PERSIST_DIR/bin"
MODEL_DIR="$PERSIST_DIR/models/${MODEL_PRESET:?MODEL_PRESET not set}"
mkdir -p "$RUN_DIR" "$MODEL_DIR" "$TOOLS_DIR" "$BIN_DIR"

# --- sshd ---------------------------------------------------------------
# RunPod does NOT start sshd for a custom image on its own (confirmed
# against docs.runpod.io/pods/configuration/use-ssh, 2026-08-01 - a custom
# template is explicitly required to install and start it itself). Without
# this, wait_for_pod_ready()'s SSH check and push_github_token() in
# lib/launch.sh would hang/fail on every launch, GPU or CPU. $PUBLIC_KEY is
# populated automatically by RunPod for any pod created with SSH enabled
# (confirmed live in a pod's own `env` block) - no local wizard step needed
# for it. Started unconditionally, even under PREWARM_ONLY, so a prewarm
# pod is reachable for diagnostics via `runpodctl ssh info <pod-id>`.
mkdir -p /run/sshd "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ -n "${PUBLIC_KEY:-}" ]]; then
  echo "$PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
  chmod 600 "$HOME/.ssh/authorized_keys"
fi
ssh-keygen -A >/dev/null
# `service ssh start` (not a raw `/usr/sbin/sshd` invocation) is RunPod's own
# documented snippet for this exact situation (docs.runpod.io/pods/configuration/use-ssh).
# Non-fatal on purpose: this whole script is PID 1 under `set -euo pipefail` -
# a raw `sshd` failing (e.g. a PAM quirk in a minimal apt install) exits
# non-zero in the foreground before it forks, which would kill PID 1 and the
# entire container with it, restarting in an silent loop with no way to
# diagnose it (confirmed live 2026-08-01: exactly this happened - pod stuck
# at uptimeSeconds=0 indefinitely, SSH connection refused every time). SSH
# not coming up is a real problem worth surfacing, but it shouldn't take the
# whole pod down with it.
service ssh start || echo "WARNING: sshd failed to start - SSH access to this pod will not work. Continuing anyway." >&2

# --- toolchain lives on the network volume, not this image ------------------
# gh, cloudflared, uv itself, and everything uv installs (Python
# interpreters, OpenHands, Open WebUI) all get written under $PERSIST_DIR so
# they survive pod deletion and are shared across every pod that mounts this
# volume - installed once, not once per image pull. See Dockerfile's comment
# on why this moved out of build time.
export PATH="$BIN_DIR:$PATH"
export UV_INSTALL_DIR="$BIN_DIR"
export UV_TOOL_DIR="$TOOLS_DIR/uv-tools"
export UV_TOOL_BIN_DIR="$BIN_DIR"
export UV_PYTHON_INSTALL_DIR="$TOOLS_DIR/uv-python"

# Idempotent by design (every step is a `command -v` guard) so it's cheap to
# call on every boot as a fallback, not just from the dedicated prewarm run -
# if maybe_run_prewarm() was skipped or never run, a normal launch still
# works, it just pays for the install time on the GPU pod instead.
ensure_tools() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "Installing gh to $BIN_DIR..."
    local gh_url tmp_dir
    gh_url="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
      | sed -E 's/.*"(https[^"]+)"/\1/' | head -n1)"
    tmp_dir="$(mktemp -d)"
    curl -fsSL "$gh_url" -o "$tmp_dir/gh.tar.gz"
    tar -xzf "$tmp_dir/gh.tar.gz" -C "$tmp_dir"
    install -m 755 "$(find "$tmp_dir" -type f -name gh -perm -u+x | head -n1)" "$BIN_DIR/gh"
    rm -rf "$tmp_dir"
  fi

  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "Installing cloudflared to $BIN_DIR..."
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
      -o "$BIN_DIR/cloudflared"
    chmod +x "$BIN_DIR/cloudflared"
  fi

  if ! command -v uv >/dev/null 2>&1; then
    echo "Installing uv to $BIN_DIR..."
    # UV_INSTALL_DIR is the installer's own documented override
    # (docs.astral.sh/uv/reference/installer, confirmed 2026-07-31) - exported
    # above, so no separate --install-dir flag needed here.
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi

  # Both frontends installed regardless of this boot's $FRONTEND choice -
  # the whole point of prewarming is covering every frontend switch a future
  # launch might make, not just today's pick.
  if ! command -v openhands >/dev/null 2>&1; then
    echo "Installing OpenHands (uv tool)..."
    uv tool install openhands --python 3.12
  fi
  if ! command -v open-webui >/dev/null 2>&1; then
    echo "Installing Open WebUI (uv tool)..."
    uv tool install open-webui --python 3.12
  fi
}

echo "Ensuring toolchain is present on the network volume..."
ensure_tools

# --- model weights: download straight to the network volume if missing ----
# Streaming curl directly to the destination path (no /tmp cache hop) is
# the "don't need 2x the weight size" approach PREREQUISITES.md calls out.
# shellcheck source=presets.conf
source /opt/runpod-lab/presets.conf
MODEL_PATH="$MODEL_DIR/$HF_FILE"

if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Downloading $HF_FILE from $HF_REPO (first boot with this preset)..."
  curl -fL --retry 3 --retry-delay 5 \
    "https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILE}" \
    -o "$MODEL_PATH.partial"
  mv "$MODEL_PATH.partial" "$MODEL_PATH"
else
  echo "Model weights already on the volume: $MODEL_PATH"
fi

if [[ "${PREWARM_ONLY:-0}" == 1 ]]; then
  echo "PREWARM_ONLY set - toolchain and model weights are in place. Not starting llama-server, any frontend, or onstart.sh."
  # Self-terminate rather than just exit - confirmed live (2026-08-01) that
  # RunPod restarts a pod's container on ANY exit, including a clean exit 0,
  # so without this the pod just loops entrypoint.sh forever and keeps
  # billing. $RUNPOD_POD_ID is RunPod's own auto-injected env var (same one
  # idle-watchdog.sh's shutdown_pod() already relies on); $RUNPOD_API_KEY is
  # passed in by maybe_run_prewarm()'s --env, same as the normal GPU pod
  # gets. If either is missing, fall through to plain exit 0 and let
  # maybe_run_prewarm()'s own stop/delete (its trap) be the backstop.
  if [[ -n "${RUNPOD_POD_ID:-}" && -n "${RUNPOD_API_KEY:-}" ]]; then
    echo "Self-terminating this prewarm pod ($RUNPOD_POD_ID)..."
    runpodctl pod stop "$RUNPOD_POD_ID" || echo "WARNING: pod stop failed - relying on the local machine's cleanup instead." >&2
    runpodctl pod delete "$RUNPOD_POD_ID" || echo "WARNING: pod delete failed - relying on the local machine's cleanup instead." >&2
  else
    echo "WARNING: RUNPOD_POD_ID or RUNPOD_API_KEY not set - cannot self-terminate. Relying on the local machine's cleanup instead." >&2
  fi
  exit 0
fi

# --- inference backend: llama-server ----------------------------------------
# Only port 3000 is forwarded through the Cloudflare tunnel (see
# PREREQUISITES.md), so llama-server binds to 3000 directly ONLY when it's
# also the chosen frontend (llama.cpp's built-in web UI is served on the
# same port as its API - no separate process). Otherwise it's internal-only
# on 127.0.0.1:8081, fronted by whichever app frontend is chosen below.
FRONTEND="${FRONTEND:-openhands}"
if [[ "$FRONTEND" == "llama-webui" ]]; then
  LLAMA_PORT=3000
else
  LLAMA_PORT=8081
fi

# SKIP_INFERENCE=1 is an escape hatch for diagnosing/benchmarking a pod
# without a GPU attached - loading a 17-20GB model on a CPU pod's default
# 4GB RAM OOMs the whole container almost immediately (confirmed live
# 2026-08-01: a CPU benchmark pod crash-looped on this repeatedly). Not
# used by any normal launch path in lib/launch.sh - GPU pods always have
# enough VRAM/RAM for this and should never set it.
if [[ "${SKIP_INFERENCE:-0}" == 1 ]]; then
  echo "SKIP_INFERENCE=1 - not starting llama-server (diagnostic/benchmark mode)."
else
  # Absolute path, not a bare `llama-server` PATH lookup - confirmed live
  # 2026-08-01 that the base image's own ENTRYPOINT invokes it by absolute
  # path (/app/llama-server) and never actually puts /app on $PATH, so a bare
  # `nohup llama-server ...` here failed instantly with "No such file or
  # directory" on every boot. entrypoint.sh's own PATH export above only adds
  # $BIN_DIR, which doesn't help.
  echo "Starting llama-server ($MODEL_PRESET, port $LLAMA_PORT)..."
  nohup /app/llama-server \
    --model "$MODEL_PATH" \
    --host 127.0.0.1 --port "$LLAMA_PORT" \
    "${LLAMA_EXTRA_ARGS[@]}" \
    >"$RUN_DIR/llama-server.log" 2>&1 &
  echo $! > "$RUN_DIR/llama-server.pid"

  # Give the frontend something to connect to instead of racing it - wait for
  # llama-server's health endpoint, same "poll with a timeout" shape as
  # wait_for_pod_ready() in lib/launch.sh.
  echo "Waiting for llama-server to report healthy..."
  waited=0
  until curl -fsS "http://127.0.0.1:${LLAMA_PORT}/health" >/dev/null 2>&1; do
    (( waited >= 180 )) && { echo "llama-server didn't come up within 180s - check $RUN_DIR/llama-server.log" >&2; break; }
    sleep 3; waited=$((waited + 3))
  done
fi

# --- frontend: exactly one, always on 127.0.0.1:3000 -------------------------
case "$FRONTEND" in
  llama-webui)
    echo "Frontend: llama.cpp's built-in web UI (llama-server already serving it on 3000)."
    ;;
  openhands)
    echo "Starting OpenHands (Local Runtime, port 3000)..."
    # RUNTIME=process is current; RUNTIME=local is a documented legacy
    # alias for the same thing (docs.openhands.dev/openhands/usage/runtimes/local).
    # LLM_* env vars + config.toml are both written out (belt and suspenders)
    # since docs disagreed on whether env vars are picked up automatically
    # or need `openhands --override-with-envs` - CONFIRM AT FIRST REAL BOOT
    # and drop whichever one turns out to be dead weight.
    export RUNTIME=process
    export LLM_MODEL="openai/${MODEL_PRESET}"
    export LLM_BASE_URL="http://127.0.0.1:${LLAMA_PORT}/v1"
    export LLM_API_KEY="local-llm"
    mkdir -p "$HOME/.openhands"
    cat > "$HOME/.openhands/config.toml" <<EOF
[llm]
model = "openai/${MODEL_PRESET}"
base_url = "http://127.0.0.1:${LLAMA_PORT}/v1"
api_key = "local-llm"
EOF
    nohup openhands web --host 127.0.0.1 --port 3000 \
      >"$RUN_DIR/openhands.log" 2>&1 &
    echo $! > "$RUN_DIR/openhands.pid"
    ;;
  open-webui)
    echo "Starting Open WebUI (port 3000)..."
    export OPENAI_API_BASE_URL="http://127.0.0.1:${LLAMA_PORT}/v1"
    export OPENAI_API_KEY="local-llm"
    nohup open-webui serve --port 3000 \
      >"$RUN_DIR/open-webui.log" 2>&1 &
    echo $! > "$RUN_DIR/open-webui.pid"
    ;;
  *)
    echo "Unknown FRONTEND '$FRONTEND' - expected openhands, llama-webui, or open-webui." >&2
    exit 1
    ;;
esac

echo "entrypoint.sh done - handing off to onstart.sh."
exec /opt/runpod-lab/onstart.sh
