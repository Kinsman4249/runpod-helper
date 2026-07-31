#!/usr/bin/env bash
# entrypoint.sh - the image's CMD. Runs before onstart.sh on every boot:
# gets the model weights + inference backend + chosen frontend up first,
# then hands off to onstart.sh (baked in at image build time, see
# Dockerfile) for cloudflared + the idle watchdog. Not fetched from GitHub
# at runtime like idle-watchdog.sh/safety-commit.sh are - this file only
# exists inside the image.
set -euo pipefail

RUN_DIR="/run/runpod-lab"
MODEL_DIR="/workspace/persistent/models/${MODEL_PRESET:?MODEL_PRESET not set}"
mkdir -p "$RUN_DIR" "$MODEL_DIR"

# shellcheck source=presets.conf
source /opt/runpod-lab/presets.conf
MODEL_PATH="$MODEL_DIR/$HF_FILE"

# --- model weights: download straight to the network volume if missing ----
# Streaming curl directly to the destination path (no /tmp cache hop) is
# the "don't need 2x the weight size" approach PREREQUISITES.md calls out.
if [[ ! -f "$MODEL_PATH" ]]; then
  echo "Downloading $HF_FILE from $HF_REPO (first boot with this preset)..."
  curl -fL --retry 3 --retry-delay 5 \
    "https://huggingface.co/${HF_REPO}/resolve/main/${HF_FILE}" \
    -o "$MODEL_PATH.partial"
  mv "$MODEL_PATH.partial" "$MODEL_PATH"
else
  echo "Model weights already on the volume: $MODEL_PATH"
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

echo "Starting llama-server ($MODEL_PRESET, port $LLAMA_PORT)..."
nohup llama-server \
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
