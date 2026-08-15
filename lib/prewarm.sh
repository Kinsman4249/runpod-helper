# lib/prewarm.sh - optional pre-download step (startup.sh's --prewarm,
# e2e-test.sh's --prewarm-only): fetches a preset's weights onto the network
# volume via a cheap CPU pod, instead of paying the real GPU's hourly rate for
# the download+load time. Reintroduces the idea behind the pre-2.0.0 --prewarm
# flag (removed 2026-08-14 along with the custom image its old PREWARM_ONLY
# entrypoint branch depended on - see CHANGELOG.md), rebuilt from scratch
# against the bare official images since that branch no longer exists anywhere
# to reuse.
#
# Design constraint confirmed live 2026-08-14 (probe pod 7yamt6hjjiy4wy,
# alpine:3.19, `sh -c 'sleep 25'`): a RunPod pod does NOT go to EXITED when its
# own process exits - it crash-loops instead (uptimeSeconds stayed pinned at 0
# for 90+ seconds). So the local script can't detect "prewarm finished" by
# polling pod status. It also deliberately does NOT put RUNPOD_API_KEY on the
# prewarm pod so it can self-terminate via the API - that would mean any pod
# image, including this one, carries account-wide pod/billing control, which
# is exactly what the 2.0.0 pivot removed from every pod for good reason.
# Instead: the prewarm pod serves a plain HTTP 200/503 on port 8000, same
# shape as a real vLLM/llama.cpp pod, and wait_for_vllm_ready() (lib/launch.sh)
# polls it exactly the way it polls a real launch - no new polling logic
# needed, and no credential ever leaves this machine.

# RunPod gives no way to size a CPU pod via runpodctl - confirmed live
# 2026-08-14: passing --gpu-id alongside --compute-type cpu is rejected
# outright ("--gpu-id is not supported for compute type CPU"), and there's no
# other sizing flag in `runpodctl pod create --help`. Every CPU pod comes back
# as 2 vCPU / 4GB RAM regardless of what's requested - confirmed via the same
# probe. That's fine here: the vLLM path only streams a download to disk (no
# RAM pressure), and the llama.cpp path mmaps its GGUF from the network volume
# rather than needing it fully resident, so reading enough of it to answer
# /v1/models doesn't need RAM anywhere near the file's own size.
PREWARM_CONTAINER_DISK_GB=10

# Generous backstop in case a huge download genuinely takes this long, or the
# in-pod script wedges - mirrors create_pod()'s --terminate-after in lib/
# launch.sh, just longer since this is a slower, cheaper class of pod and
# there's no idle-watchdog running against it.
PREWARM_TERMINATE_AFTER_HOURS=3

# Small, generic image with Python already on PATH - used for the vLLM
# engine's prewarm path only (the llama.cpp path below reuses llama.cpp's own
# CPU image instead). Not pinned to a digest, same tradeoff as IMAGE_NAME in
# lib/launch.sh.
PREWARM_PY_IMAGE="python:3.12-slim"

# CPU-only (no CUDA) llama.cpp server image - confirmed published alongside
# the -cuda variant used for real launches, see docs/docker.md in
# ggml-org/llama.cpp (github.com/ggml-org/llama.cpp/blob/master/docs/docker.md
# lists "server" as CPU-only and "server-cuda" as the GPU variant of the same
# build). Running the exact same binary a real launch will run, just without
# GPU offload (-n-gpu-layers 0 below), is what guarantees the cache it writes
# to LLAMA_CACHE is something a later real launch can actually reuse -
# llama.cpp has no documented download-only mode (confirmed via its server
# README and github.com/ggml-org/llama.cpp/discussions/20210: --hf-repo always
# proceeds to load after downloading), so anything other than the real binary
# risks writing a cache layout llama-server itself doesn't recognize.
PREWARM_LLAMACPP_IMAGE="ghcr.io/ggml-org/llama.cpp:server"

# Downloads $MODEL_REPO onto the network volume via a throwaway CPU pod, then
# tears it down - all before any GPU pod (billed at the real preset's hourly
# rate) gets created. Must run AFTER preset resolution (needs ENGINE,
# MODEL_REPO, SERVED_MODEL_NAME) and AFTER ensure_network_volume (needs
# NETWORK_VOLUME_ID) - both callers (run_normal_launch in lib/launch.sh,
# e2e-test.sh's --prewarm-only) already guarantee that ordering.
run_prewarm() {
  [[ "$STORAGE_MODE" == "network-volume" ]] \
    || die "--prewarm needs --storage-mode network-volume - there's nothing to keep warm on container-disk (weights don't survive the pod being torn down either way)."

  local api_key image_name docker_args env_json
  api_key="$(openssl rand -hex 32)"

  if [[ "${ENGINE:-vllm}" == "llamacpp" ]]; then
    image_name="$PREWARM_LLAMACPP_IMAGE"
    # Minimal --ctx-size: KV cache is sized off this at load time, and
    # prewarm only needs the "model finished loading" signal below, not a
    # context length that will ever actually serve anything real.
    # --n-gpu-layers 0: no GPU on this pod - keep every layer on CPU.
    docker_args="$(printf '%q ' \
      --hf-repo "$MODEL_REPO" \
      --alias "$SERVED_MODEL_NAME" \
      --host 0.0.0.0 \
      --port 8000 \
      --ctx-size 2048 \
      --api-key "$api_key" \
      --n-gpu-layers 0)"
    env_json=$(jq -n --arg cache "/workspace/persistent/llama-cache" --arg hftoken "${HF_TOKEN:-}" \
      '{LLAMA_CACHE:$cache} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
  else
    image_name="$PREWARM_PY_IMAGE"
    # vllm/vllm-openai needs a real GPU to even start, so it can't be reused
    # as its own downloader the way llama.cpp's CPU image can be above.
    # Downloads with the `hf` CLI straight into HF_HOME instead - vLLM
    # itself reads from the standard HF Hub cache layout under $HF_HOME/hub
    # (huggingface.co/docs/huggingface_hub/en/guides/manage-cache), which is
    # exactly what `hf download <repo>` (no --local-dir) populates. Confirmed
    # locally with podman 2026-08-14: `huggingface-cli` (the older name) is
    # deprecated and refuses to run in the huggingface_hub version this pulls
    # ("Warning: huggingface-cli is deprecated and no longer works. Use hf
    # instead."). A tiny stdlib HTTP server on the same port a real launch
    # uses reports 503 while that download runs and 200 once it's done, so
    # wait_for_vllm_ready() below can poll it exactly the way it polls a
    # real pod.
    # base64, not printf %q: %q emits bash's $'...' ANSI-C quoting, which
    # the pod's own /bin/sh (dash on this image, not bash) doesn't
    # understand - confirmed locally with podman 2026-08-14 before this ever
    # touched a billed pod: dash handed the literal, unexpanded $'...' text
    # straight to python3, producing "SyntaxError: invalid syntax" on the
    # very first line. Base64 has no shell-special characters at all, so it
    # round-trips correctly regardless of which /bin/sh a given image uses.
    local py_script py_b64 inner_cmd
    py_script=$(cat <<'PYEOF'
import http.server, os, subprocess, threading

status = {"code": 503, "msg": b"prewarm: downloading"}

def download():
    repo = os.environ["PREWARM_REPO"]
    try:
        subprocess.run(["hf", "download", repo], check=True)
        status["code"] = 200
        status["msg"] = b"prewarm: ready"
    except Exception as exc:
        status["code"] = 500
        status["msg"] = f"prewarm: failed: {exc}".encode()

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(status["code"])
        self.end_headers()
        self.wfile.write(status["msg"])
    def log_message(self, *args):
        pass

threading.Thread(target=download, daemon=True).start()
http.server.HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PYEOF
)
    py_b64="$(printf '%s' "$py_script" | base64 -w0)"
    inner_cmd="pip install -q -U 'huggingface_hub[hf_xet]' >/dev/null && echo $py_b64 | base64 -d | python3 -"
    docker_args="$(printf '%q ' sh -c "$inner_cmd")"
    env_json=$(jq -n --arg hfhome "/workspace/persistent/hf-cache" --arg repo "$MODEL_REPO" --arg hftoken "${HF_TOKEN:-}" \
      '{HF_HOME:$hfhome, PREWARM_REPO:$repo} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
  fi

  local terminate_after
  terminate_after="$(date -u -d "+${PREWARM_TERMINATE_AFTER_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

  log_info ""
  log_info "Prewarming $MODEL_REPO onto network volume $NETWORK_VOLUME_ID via a throwaway CPU pod (engine ${ENGINE:-vllm})..."
  local create_output
  create_output="$(runpodctl_t pod create \
    --compute-type CPU \
    --cloud-type SECURE \
    --image "$image_name" \
    --network-volume-id "$NETWORK_VOLUME_ID" \
    --volume-mount-path /workspace/persistent \
    --container-disk-in-gb "$PREWARM_CONTAINER_DISK_GB" \
    --terminate-after "$terminate_after" \
    --name "runpod-lab-prewarm-$(date +%s)" \
    --ports "8000/http" \
    --env "$env_json" \
    --docker-args "$docker_args")" || die "Prewarm pod creation failed. Raw output:\n$create_output"

  local prewarm_pod_id
  prewarm_pod_id="$(jq -r '.id // empty' <<< "$create_output")"
  [[ -n "$prewarm_pod_id" ]] || die "Prewarm pod created but no id found in the response: $create_output"
  log_ok "Prewarm pod created: $prewarm_pod_id"

  # wait_for_pod_ready()/wait_for_vllm_ready() (lib/launch.sh) both read the
  # global POD_ID/API_HOSTNAME/VLLM_API_KEY set by create_pod() - save and
  # restore them around this call so a --prewarm run (prewarm THEN a real
  # launch, see run_normal_launch() below) doesn't clobber the real pod's
  # values the caller still needs afterward.
  local saved_pod_id="${POD_ID:-}" saved_hostname="${API_HOSTNAME:-}" saved_key="${VLLM_API_KEY:-}"
  POD_ID="$prewarm_pod_id"
  API_HOSTNAME="$prewarm_pod_id-8000.proxy.runpod.net"
  VLLM_API_KEY="$api_key"

  wait_for_pod_ready
  wait_for_vllm_ready
  # wait_for_vllm_ready() only warns on timeout, it doesn't signal failure to
  # its caller (see lib/launch.sh) - so success here is judged by one more
  # direct check, not by that function's own (always-0) return status.
  local prewarm_ok=0
  curl -fsS --max-time 5 -o /dev/null -H "Authorization: Bearer $api_key" "https://$API_HOSTNAME/v1/models" 2>/dev/null \
    && prewarm_ok=1

  log_info "Tearing down prewarm pod $prewarm_pod_id..."
  runpodctl_t pod stop "$prewarm_pod_id" >/dev/null 2>&1 || true
  runpodctl_t pod delete "$prewarm_pod_id" >/dev/null 2>&1 || true

  POD_ID="$saved_pod_id"; API_HOSTNAME="$saved_hostname"; VLLM_API_KEY="$saved_key"

  if (( prewarm_ok == 1 )); then
    log_ok "Prewarm done - $MODEL_REPO is cached on $NETWORK_VOLUME_ID. The next launch of this preset will skip the download."
  else
    die "Prewarm pod $prewarm_pod_id never became ready within the wait window - it has already been torn down. Check https://www.runpod.io/console/pods for its recent logs if the console still has them, or rerun --prewarm."
  fi
}
