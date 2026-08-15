# lib/launch.sh - normal pod launch (startup.sh section 1b), run every time
# except during the first-run setup wizard. Sourced by startup.sh.

CONTAINER_DISK_GB=40   # holds the vLLM image + OS only; weights live on the
                       # network volume (HF_HOME, set via --env in
                       # create_pod() below). vllm/vllm-openai is a heavy
                       # base image (full CUDA/PyTorch/vLLM stack) - not yet
                       # measured against a real pull, bump this if it
                       # turns out too small.

# Used instead of CONTAINER_DISK_GB when STORAGE_MODE=container-disk: no
# network volume is attached, so this disk has to hold the image/OS AND the
# model weights (HF_HOME falls back to plain local disk under
# /workspace/persistent - entrypoint.sh needs no change for this, it just
# mkdir -p's a normal directory instead of a mounted volume). Sized
# generously since container disk is billed per-second only while the pod is
# running (free once stopped) - the real cost driver for this mode is GB
# rather than time. The largest current preset needing headroom is
# qwen3.5-40b-deckard: it downloads the full bf16 checkpoint (~80GB, roughly
# double its ~40GB post-quantization VRAM footprint) since vLLM's
# --quantization fp8 quantizes on the fly at load time rather than
# downloading a pre-quantized repo - not yet measured against a real pull,
# bump this if it turns out too small.
CONTAINER_DISK_GB_STANDALONE=150

# "network-volume" (default): current behavior, model weights persist on a
# billed network volume across pod recreations. "container-disk": no network
# volume at all, weights land on the pod's own (bigger, local, ephemeral)
# container disk instead - faster reads, but every fresh pod re-downloads
# the model, and nothing survives idle-watchdog.sh deleting the pod. Callers
# (startup.sh, e2e-test.sh) set this from a --storage-mode flag before
# calling run_normal_launch/create_pod; defaults here only as a safety net.
STORAGE_MODE="${STORAGE_MODE:-network-volume}"

# vLLM's own official image - no custom Dockerfile/entrypoint (removed
# 2026-08-14; see CHANGELOG.md). Pinning to a digest instead of "latest"
# would be more reproducible, but "latest" is what every live diagnosis
# this session was run against and is what confirmed the --ports/VRAM
# findings below - not changing that out from under itself right now.
IMAGE_NAME="vllm/vllm-openai:latest"

# llama.cpp's own official server image, added 2026-08-14 for the
# qwen3.5-40b-deckard-gguf preset below. Verified live against a throwaway
# pod: it auto-downloads a GGUF straight from Hugging Face via --hf-repo
# (no custom entrypoint/prewarm needed, mirroring how the vLLM image
# already just takes --model), caches it under $LLAMA_CACHE, and serves an
# OpenAI-compatible API - confirmed both /v1/models and /v1/chat/completions
# work through RunPod's proxy on port 8000, same as vLLM.
LLAMACPP_IMAGE_NAME="ghcr.io/ggml-org/llama.cpp:server-cuda"

# --- model presets -----------------------------------------------------------
# Every repo below was confirmed to exist via the HF API
# (huggingface.co/api/models/<repo>) as of 2026-08-12. Quantization method
# for the AWQ presets is auto-detected by vLLM from each repo's own
# config.json ("auto" here is literally passed as --quantization auto,
# vLLM's own default - not a magic value, just makes the flag unconditional
# for every preset including the on-the-fly ones below), EXCEPT two repos
# whose own config.json declares a quantization_method explicitly - vLLM
# 0.27.1 rejects --quantization auto against either (pydantic
# ValidationError, confirmed live 2026-08-14 boot-looping the pod both
# times), so each pins its real method instead of "auto":
# qwen3.6-27b-awq-mtp ("awq") and qwen3-coder-30b-moe ("compressed-tensors").
# min_vram is a floor
# (the GPU list is still filtered live against it, same as the old preset
# system), not a recommendation - a bigger card than the floor buys more
# KV-cache headroom and lets you push max-model-len higher than the
# suggested default below. Weight sizes are approximate (param count x
# ~4-8 bits/byte + overhead).
#
# Columns: value | engine | HF repo | served-model-name | min_vram_gb | default max-model-len | quantization | extra serve flags (space-separated, "-" for none) | label
#
# engine is "vllm" or "llamacpp" (added 2026-08-14 alongside the first
# llamacpp preset below) - selects IMAGE_NAME vs LLAMACPP_IMAGE_NAME and the
# whole docker-args/env shape in create_pod(). For llamacpp rows, "HF repo"
# is actually "<repo>:<quant tag>" (llama-server's own --hf-repo syntax -
# the quant is picked by tag, not a separate flag), so the quantization
# column is unused ("-") for those rows.
#
# extra_args exists because of a live-confirmed failure mode (2026-08-14):
# hybrid Gated-DeltaNet/full-attention models (Qwen3.5/3.6's architecture)
# need extra FIXED memory for recurrent/mamba state on top of normal KV
# cache. vLLM's default --gpu-memory-utilization 0.9 left only 0.39GiB free
# after AWQ weights on a 24GB L4, crashing _initialize_kv_caches. Fixed by
# --gpu-memory-utilization 0.95 --kv-cache-dtype fp8. --enforce-eager added
# defensively (ruled out, not confirmed needed) against two known unfixed
# vLLM bugs on this architecture (github.com/vllm-project/vllm issues
# #40807, #40880) that involve CUDA-graph capture. Plain (non-hybrid) dense
# presets need none of this, hence "-".
#
# The label (last column) is kept short - just the model, quant, approx
# weight size, the min_vram floor, and whether that floor is "tested live"
# (confirmed by a real pod boot) or "napkin math" (a conservative estimate:
# weights + KV cache + engine overhead, not yet run). The floors that are
# estimates aim to be the cheapest tier that still won't OOM, not a padded
# safe-by-a-mile number. Detail that used to live in these labels:
#   - qwen3-coder-30b-moe / qwen3.6-27b-awq-mtp pin a non-"auto" --quantization
#     (compressed-tensors / awq) because each repo's config.json declares its
#     own method and vLLM 0.27.1 rejects "auto" against that (see the extra_args
#     note above and CHANGELOG 2.0.0/2.1.0).
#   - qwen3.5-40b-deckard-gguf's 48GB floor = ~25GB Q5_K_S weights + ~13GB
#     full-attention KV cache (q8_0, 262144 tokens, only 24 of 96 layers are
#     full-attention; the other 72 are GDN/linear with a fixed ~0.2GB state) +
#     llama.cpp compute buffers ~= 41GB; 48 is the cheapest tier clearing it.
#     The -40gb row is the same weights capped at 196608 tokens (192K) to fit a
#     40GB card - 262144 is the model hard max_position_embeddings (no rope
#     scaling), so a smaller card buys less context, not a bigger model.
PRESET_TABLE='
deepseek-r1-distill-32b|vllm|casperhansen/deepseek-r1-distill-qwen-32b-awq|deepseek-r1-32b|24|16384|auto|-|DeepSeek-R1-Distill-Qwen-32B (AWQ ~19GB) - 24GB VRAM floor (napkin math) - dense reasoning
qwen3-32b|vllm|Qwen/Qwen3-32B-AWQ|qwen3-32b|24|16384|auto|-|Qwen3-32B (AWQ ~19GB) - 24GB VRAM floor (napkin math) - dense general-purpose
qwen3-coder-30b-moe|vllm|stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ|qwen3-coder-30b|24|32768|compressed-tensors|-|Qwen3-Coder-30B-A3B MoE (AWQ ~17GB) - 24GB VRAM floor (tested live) - coding
qwen2.5-72b|vllm|Qwen/Qwen2.5-72B-Instruct-AWQ|qwen2.5-72b|48|8192|auto|-|Qwen2.5-72B-Instruct (AWQ ~41GB) - 48GB VRAM floor (napkin math) - bigger dense
llama3.3-70b|vllm|casperhansen/llama-3.3-70b-instruct-awq|llama3.3-70b|48|8192|auto|-|Llama-3.3-70B-Instruct (AWQ ~39GB) - 48GB VRAM floor (napkin math) - non-Qwen option
qwen3.5-40b-deckard|vllm|DavidAU/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking|qwen3.5-40b-deckard|80|262144|fp8|--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager|Qwen3.5-40B-Deckard (FP8 ~40GB, 256K ctx) - 80GB VRAM floor (napkin math) - uncensored, tool use
qwen3.6-27b-awq-mtp|vllm|shawnw3i/Qwen3.6-27B-AWQ-MTP|qwen3.6-27b|24|16384|awq|--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager|Qwen3.6-27B-AWQ-MTP (AWQ ~18GB) - 24GB VRAM floor (tested live) - agentic coding
qwen3.5-40b-deckard-gguf|llamacpp|mradermacher/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-GGUF:Q5_K_S|qwen3.5-40b-deckard|48|262144|-|-fa on --cache-type-k q8_0 --cache-type-v q8_0|Qwen3.5-40B-Deckard GGUF Q5_K_S (~27GB, 256K ctx, llama.cpp) - 48GB VRAM floor (tested live) - uncensored, tool use
qwen3.5-40b-deckard-gguf-40gb|llamacpp|mradermacher/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-GGUF:Q5_K_S|qwen3.5-40b-deckard|40|196608|-|-fa on --cache-type-k q8_0 --cache-type-v q8_0|Qwen3.5-40B-Deckard GGUF Q5_K_S (~27GB, 192K ctx, llama.cpp) - 40GB VRAM floor (napkin math) - budget/reduced context
'

# --- GPU listing --------------------------------------------------------
# Live-fetches GPUs stocked in $DATACENTER_ID meeting a VRAM floor, sorted
# cheapest-first. Split out of pick_preset_and_gpu's interactive "gpu" step
# so e2e-test.sh can reuse the exact same fetch/filter/sort logic to pick a
# GPU non-interactively (cheapest available), instead of hand-rolling a
# second copy of this jq query that could silently drift from this one.
# Prints tab-separated rows (gpuId, displayName, memoryInGb, securePricePerHr,
# stockStatus) to stdout, one per available GPU; prints nothing and returns
# 1 if none meet the floor.
list_available_gpus() {
  local min_vram="$1"
  local gpu_json
  gpu_json="$(runpodctl_t gpu list)" || die "Could not list GPUs - check https://www.runpod.io/console/gpu-cloud instead."

  # Field names (gpuId, displayName, memoryInGb, securePricePerHr,
  # dataCenterAvailability[].stockStatus) confirmed against live
  # `runpodctl gpu list` JSON output (2026-07-30, re-checked 2026-08-12).
  local rows
  rows="$(jq -r --arg dc "$DATACENTER_ID" --argjson minvram "$min_vram" '
    .[]
    | . as $g
    | ($g.dataCenterAvailability[]? | select(.dataCenterId == $dc) | .stockStatus) as $stock
    | select($stock != "none")
    | select($g.memoryInGb >= $minvram)
    | [$g.gpuId, $g.displayName, ($g.memoryInGb | tostring), ($g.securePricePerHr | tostring), $stock]
    | @tsv
  ' <<< "$gpu_json" | sort -t $'\t' -k4 -n)"

  [[ -n "$rows" ]] || return 1
  printf '%s\n' "$rows"
}

# --- pod creation ------------------------------------------------------------

create_pod() {
  local terminate_after
  # --terminate-after is a confirmed native runpodctl flag (absolute
  # ISO-8601 datetime) - a hard backstop that fires even if the local
  # idle-watchdog (see maybe_start_idle_watchdog() below) itself has
  # crashed or its request-activity detection is misbehaving.
  terminate_after="$(date -u -d "+${MAX_RUNTIME_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

  # Registered with RunPod so resolve_pod_ssh_proxy_host() (lib/common.sh)
  # can diagnose this pod later via ssh.runpod.io - the bare image has no
  # sshd, so this key never gets baked into an authorized_keys file
  # anywhere; it's only good for RunPod's own proxy-side exec.
  setup_ephemeral_ssh_key
  VLLM_API_KEY="$(openssl rand -hex 32)"

  log_info ""
  log_info "Creating pod (GPU $GPU_ID, engine ${ENGINE:-vllm}, model $MODEL_REPO, auto-terminate at $terminate_after UTC)..."

  # Both the vllm/vllm-openai and ggml-org/llama.cpp images have a fixed
  # ENTRYPOINT (["vllm","serve"] / ["/app/llama-server"] respectively) - no
  # custom entrypoint.sh anymore (removed 2026-08-14; see CHANGELOG.md), so
  # every model/runtime setting has to arrive as a CLI arg appended via
  # --docker-args, not an --env var some wrapper script used to translate.
  # This also means: no sshd (nothing starts it), no on-pod idle-watchdog
  # (nothing to host it - see maybe_start_idle_watchdog()), and no reason
  # to put RUNPOD_API_KEY on the pod at all anymore, since nothing running
  # on it needs to call the RunPod API to self-terminate.
  local -a log_flags=()
  if [[ "${NUKE_LOGGING:-0}" == 1 ]]; then
    if [[ "${ENGINE:-vllm}" == "llamacpp" ]]; then
      log_flags=(--log-disable)
    else
      log_flags=(--disable-log-stats --disable-uvicorn-access-log)
    fi
  fi

  local -a extra_flags=()
  [[ -n "${MODEL_EXTRA_ARGS:-}" && "$MODEL_EXTRA_ARGS" != "-" ]] && read -ra extra_flags <<< "$MODEL_EXTRA_ARGS"

  # User-supplied engine flags from --extra-args (startup.sh/e2e-test.sh),
  # appended verbatim to whichever engine's serve command runs below - for when
  # a model/quant needs a knob this script doesn't expose (e.g. vLLM's
  # --rope-scaling / --tensor-parallel-size, or llama.cpp's --split-mode /
  # --override-kv). Applied AFTER the preset's own MODEL_EXTRA_ARGS so a user
  # value wins on any flag the CLI takes last-one-wins. Space-split like
  # MODEL_EXTRA_ARGS, so an individual flag VALUE can't itself contain spaces -
  # fine for engine flags, which don't. Not applied to the prewarm pod (it only
  # downloads weights - see lib/prewarm.sh).
  local -a user_flags=()
  [[ -n "${USER_EXTRA_ARGS:-}" ]] && read -ra user_flags <<< "$USER_EXTRA_ARGS"

  local docker_args env_json
  if [[ "${ENGINE:-vllm}" == "llamacpp" ]]; then
    # --hf-repo takes MODEL_REPO's own "<repo>:<quant tag>" form directly
    # (llama-server's own syntax, confirmed live 2026-08-14 against
    # ggml-org/gemma-4-E2B-it-GGUF:Q8_0 through RunPod's proxy) - no
    # separate --quantization flag the way vLLM has one. --alias sets the
    # clean served name (otherwise /v1/models would list the full
    # repo:quant string, which e2e-test.sh's checks and any client
    # wouldn't know to ask for). --metrics is required for
    # idle-watchdog.sh's activity polling below, not optional here.
    # -ngl 999 offloads every layer to GPU - llama.cpp's own convention for
    # "as many as exist", not a real layer count.
    docker_args="$(printf '%q ' \
      --hf-repo "$MODEL_REPO" \
      --alias "$SERVED_MODEL_NAME" \
      --host 0.0.0.0 \
      --port 8000 \
      --ctx-size "$MAX_MODEL_LEN" \
      --api-key "$VLLM_API_KEY" \
      --n-gpu-layers 999 \
      --metrics \
      "${extra_flags[@]}" \
      "${user_flags[@]}" \
      "${log_flags[@]}")"

    # LLAMA_CACHE on the network volume (when attached): the downloaded
    # GGUF persists across pod recreations, mirroring HF_HOME's role for
    # vLLM below. STORAGE_MODE=container-disk has no volume mounted, so
    # LLAMA_CACHE is left at llama.cpp's own default (the pod's own
    # container disk).
    if [[ "$STORAGE_MODE" == "network-volume" ]]; then
      env_json=$(jq -n --arg cache "/workspace/persistent/llama-cache" --arg hftoken "${HF_TOKEN:-}" \
        '{LLAMA_CACHE:$cache} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
    else
      env_json=$(jq -n --arg hftoken "${HF_TOKEN:-}" \
        '{} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
    fi
  else
    docker_args="$(printf '%q ' \
      --model "$MODEL_REPO" \
      --served-model-name "$SERVED_MODEL_NAME" \
      --host 0.0.0.0 \
      --port 8000 \
      --max-model-len "$MAX_MODEL_LEN" \
      --quantization "${MODEL_QUANTIZATION:-auto}" \
      --api-key "$VLLM_API_KEY" \
      "${extra_flags[@]}" \
      "${user_flags[@]}" \
      "${log_flags[@]}")"

    # HF_HOME on the network volume (when attached): weights persist across
    # pod recreations, so a second launch of the same model preset skips the
    # multi-GB download entirely instead of re-fetching it every time.
    # STORAGE_MODE=container-disk has no volume mounted, so HF_HOME is left
    # at vLLM's own default (the pod's own container disk - see
    # CONTAINER_DISK_GB_STANDALONE above for why that disk is sized bigger).
    if [[ "$STORAGE_MODE" == "network-volume" ]]; then
      env_json=$(jq -n --arg hfhome "/workspace/persistent/hf-cache" --arg hftoken "${HF_TOKEN:-}" \
        '{HF_HOME:$hfhome} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
    else
      env_json=$(jq -n --arg hftoken "${HF_TOKEN:-}" \
        '{} + (if $hftoken != "" then {HF_TOKEN:$hftoken} else {} end)')
    fi
  fi

  # STORAGE_MODE=container-disk omits --network-volume-id/--volume-mount-path
  # entirely - nothing mounts at /workspace/persistent, so HF_HOME above
  # falls back to the pod's own (bigger) container disk instead. See
  # CONTAINER_DISK_GB_STANDALONE above for the sizing rationale.
  local -a storage_args
  if [[ "$STORAGE_MODE" == "container-disk" ]]; then
    storage_args=(--container-disk-in-gb "$CONTAINER_DISK_GB_STANDALONE")
  else
    storage_args=(
      --network-volume-id "$NETWORK_VOLUME_ID"
      --volume-mount-path /workspace/persistent
      --container-disk-in-gb "$CONTAINER_DISK_GB"
    )
  fi

  local image_name="$IMAGE_NAME"
  [[ "${ENGINE:-vllm}" == "llamacpp" ]] && image_name="$LLAMACPP_IMAGE_NAME"

  # Capture stderr separately (a temp file, not 2>&1): runpodctl prints its
  # graphql error JSON to stderr, not stdout - confirmed live 2026-08-15, where
  # a capacity failure left our old `die` message's "Raw output:" (stdout only)
  # completely blank. Keeping the streams apart means a stray stderr warning on
  # an OTHERWISE-successful create can't corrupt the stdout JSON that jq parses
  # for .id below, while still giving us the error text to classify/print.
  local create_output errfile create_err rc=0
  errfile="$(mktemp "${TMPDIR:-/tmp}/runpod-lab-create.XXXXXX")"
  create_output="$(runpodctl_t pod create \
    --cloud-type SECURE \
    --gpu-id "$GPU_ID" \
    --image "$image_name" \
    "${storage_args[@]}" \
    --terminate-after "$terminate_after" \
    --name "runpod-lab-$(date +%s)" \
    --ports "8000/http" \
    --env "$env_json" \
    --docker-args "$docker_args" 2>"$errfile")" || rc=$?
  create_err="$(cat "$errfile")"; rm -f "$errfile"

  if (( rc != 0 )); then
    # Capacity/placement failures are the one class worth retrying on a
    # different card rather than aborting: RunPod stocks a GPU type
    # datacenter-wide (so list_available_gpus shows it) but a specific host can
    # still be full at create time. Return 2 so the caller can offer another
    # card (offer_alternate_gpu / e2e's auto-advance); everything else is fatal.
    if grep -qiE 'resources to deploy|different machine|no( longer)? .*instances|instances available|out of capacity|no capacity|insufficient capacity' \
         <<< "$create_err"$'\n'"$create_output"; then
      log_warn "RunPod couldn't place a pod on GPU '$GPU_ID' right now: ${create_err:-$create_output}"
      return 2
    fi
    die "Pod creation failed (rc=$rc):"$'\n'"${create_err:-$create_output}"
  fi

  # Picking specific fields (rather than printing $create_output raw) is
  # deliberate: the response echoes back both the --env payload and the
  # --docker-args string verbatim, including VLLM_API_KEY (now inside
  # docker-args, not env) and HF_TOKEN if set - none of that has any
  # business hitting the terminal or a captured log.
  POD_ID="$(jq -r '.id // empty' <<< "$create_output")"
  [[ -n "$POD_ID" ]] || die "Pod created but no id found in the response: $create_output"

  # RunPod's proxy does NOT auto-detect a listening port - `pod create`
  # needs an explicit --ports flag (see runpodctl's own --help) or every
  # request to <pod-id>-8000.proxy.runpod.net 404s forever even once vLLM
  # is healthy on 8000 inside the container. Confirmed live 2026-08-14 on a
  # bare vllm-openai pod: omitting --ports gave a permanent 404 through 10+
  # minutes of a healthy internal /health; adding --ports "8000/http" made
  # the same proxy URL start returning 502 (booting) then 200 (ready)
  # within the same launch. This is what used to need a whole Cloudflare
  # Tunnel setup.
  API_HOSTNAME="$POD_ID-8000.proxy.runpod.net"

  log_ok "Pod created:"
  jq -r '"  ID:     \(.id)\n  Name:   \(.name)\n  GPU:    \(.machine.gpuDisplayName) x\(.gpuCount)\n  Cost:   $\(.costPerHr)/hr\n  Status: \(.desiredStatus)"' <<< "$create_output"
}

# --- wait for the pod to actually be reachable ------------------------------

wait_for_pod_ready() {
  log_info ""
  log_info "Waiting for pod $POD_ID to report running..."
  local waited=0 max_wait=600
  while (( waited < max_wait )); do
    if runpodctl_t pod get "$POD_ID" 2>/dev/null | grep -qi running; then
      break
    fi
    sleep 10; waited=$((waited + 10))
  done
  (( waited < max_wait )) || die "Pod didn't report running within ${max_wait}s. Check the console."
  log_ok "Pod reports running."

  # Pod status alone says nothing about whether vllm serve is actually up
  # yet (still pulling the image, or still loading a large model into
  # VRAM) - wait_for_vllm_ready() below, polling the real HTTP endpoint, is
  # the actual readiness gate. No SSH check here: the bare vllm/vllm-openai
  # image never starts an sshd (see resolve_pod_ssh_proxy_host(),
  # lib/common.sh, for the diagnostics-only proxy alternative), so there is
  # nothing to poll on port 22 anymore.
}

# Pod status alone says nothing about whether vllm serve has finished
# loading a (potentially tens-of-GB) model into VRAM yet. Poll the actual
# public endpoint (RunPod's own per-pod proxy URL, the same path a real
# client uses) so "Pod ready" means the API genuinely works, not just that
# the container booted.
wait_for_vllm_ready() {
  log_info ""
  log_info "Waiting for the ${ENGINE:-vllm} endpoint to finish loading $MODEL_REPO (this can take several minutes for a large model)..."
  local waited=0 max_wait=1800
  while (( waited < max_wait )); do
    if curl -fsS --max-time 5 -o /dev/null \
         -H "Authorization: Bearer $VLLM_API_KEY" \
         "https://$API_HOSTNAME/v1/models"; then
      log_ok "${ENGINE:-vllm} endpoint is serving."
      return
    fi
    sleep 15; waited=$((waited + 15))
  done
  log_warn "${ENGINE:-vllm} endpoint didn't respond within ${max_wait}s - it may still be loading, or something failed. Check the RunPod console (pod > Logs), or 'ssh -i $SSH_KEY_PATH \$SSH_PROXY_HOST@ssh.runpod.io' (resolve_pod_ssh_proxy_host() in lib/common.sh; requires a real terminal/PTY, see its comment - not scriptable)."
  # Callers historically didn't check this - both existing call sites (below,
  # and lib/prewarm.sh's run_prewarm) treat a timeout as a warning rather
  # than a hard failure. The explicit 1 here is additive: it lets a new
  # caller distinguish "actually served" from "gave up waiting" (see
  # mark_prewarmed's use below) without changing behavior for callers that
  # still ignore the status.
  return 1
}

# Launches idle-watchdog.sh (repo root) detached on THIS machine - see that
# script's own header comment for the full design/caveat. IDLE_MINUTES=0
# skips it entirely (only the --terminate-after wall-clock backstop
# applies), for anyone who'd rather manage shutdown by hand. Writes the
# watcher's own PID next to its log file so it can be found/killed later if
# needed; not tracked any further by this script.
maybe_start_idle_watchdog() {
  if [[ "$IDLE_MINUTES" == 0 ]]; then
    log_info "IDLE_MINUTES=0 - idle auto-shutdown disabled, only --max-runtime-hours ($MAX_RUNTIME_HOURS h) applies."
    return
  fi
  mkdir -p "$CONFIG_DIR/logs"
  nohup "$SCRIPT_DIR/idle-watchdog.sh" "$POD_ID" "$API_HOSTNAME" "$VLLM_API_KEY" "$IDLE_MINUTES" "${ENGINE:-vllm}" \
    >>"$CONFIG_DIR/logs/idle-watchdog-$POD_ID.log" 2>&1 &
  echo "$!" > "$CONFIG_DIR/logs/idle-watchdog-$POD_ID.pid"
  log_ok "Started local idle-watchdog (PID $!, ${IDLE_MINUTES}m idle window) - log: $CONFIG_DIR/logs/idle-watchdog-$POD_ID.log"
}

# --- entry point -------------------------------------------------------------

run_normal_launch() {
  if [[ "$STORAGE_MODE" == "network-volume" ]]; then
    ensure_network_volume
  else
    log_info "STORAGE_MODE=container-disk: no network volume, model weights will download fresh onto the pod's own disk this run."
  fi
  pick_preset_and_gpu

  # Offer a cheap-CPU-pod prewarm before paying real GPU-hourly rates for the
  # download, but only when we don't already have a local record that this
  # preset's weights landed on this volume before (either via a prior
  # prewarm or a prior real launch - see mark_prewarmed() below) - see
  # lib/prewarm.sh's is_marked_prewarmed()/mark_prewarmed(). Skipped
  # entirely on container-disk (nothing persists there to check) and when
  # --prewarm was already passed explicitly (about to run unconditionally
  # below either way).
  if [[ "$STORAGE_MODE" == "network-volume" && "${PREWARM:-0}" != 1 ]] \
      && ! is_marked_prewarmed "$NETWORK_VOLUME_ID" "$MODEL_REPO"; then
    confirm "No local record that $MODEL_REPO is cached on network volume $NETWORK_VOLUME_ID yet - downloading it during the real launch bills GPU-hourly rates for the download time. Prewarm it first via a cheap CPU pod instead?" \
      && PREWARM=1
  fi

  [[ "${PREWARM:-0}" == 1 ]] && run_prewarm

  # create_pod returns 2 on a retryable capacity failure (the specific host had
  # no room, even though the card showed stock) - loop, offering a different
  # card each time, until one deploys or there are none left / you back out.
  # Any other create failure still dies inside create_pod. `|| rc=$?` keeps
  # set -e from aborting on the non-zero return we handle here ourselves.
  local rc
  while true; do
    rc=0; create_pod || rc=$?
    (( rc == 0 )) && break
    offer_alternate_gpu "$GPU_ID" || die "Pod creation failed: no GPU with free capacity to deploy on. Try again shortly, or check https://www.runpod.io/console/gpu-cloud."
  done
  wait_for_pod_ready
  # || true: a timeout here is a warning, not a fatal error (see
  # wait_for_vllm_ready's own comment) - under set -e a bare failing call
  # would otherwise abort the script instead of printing the pod-ready
  # summary below. Its exit status still gates mark_prewarmed right after,
  # so a genuine timeout correctly skips recording this as cached.
  if wait_for_vllm_ready; then
    [[ "$STORAGE_MODE" == "network-volume" ]] && mark_prewarmed "$NETWORK_VOLUME_ID" "$MODEL_REPO"
  fi
  maybe_start_idle_watchdog

  # Best-effort - a failure here doesn't affect the endpoint at all, only
  # the diagnostics line printed below.
  resolve_pod_ssh_proxy_host || log_warn "Could not resolve an SSH diagnostics endpoint for this pod - the endpoint above still works fine, this only affects manual troubleshooting."

  log_info ""
  log_ok "Pod ready."
  log_info "OpenAI-compatible endpoint: https://$API_HOSTNAME/v1"
  log_info "Model name for clients: $SERVED_MODEL_NAME"
  log_info "API key (Authorization: Bearer <key> - one-off, generated for this pod, shown once, not stored anywhere): $VLLM_API_KEY"
  if [[ -n "${SSH_PROXY_HOST:-}" ]]; then
    log_info "Diagnostics: ssh -i $SSH_KEY_PATH $SSH_PROXY_HOST@ssh.runpod.io"
    log_info "  (proxy SSH, not direct-TCP - the bare vllm-openai image has no sshd. Requires a real terminal; needs a PTY. Key is registered with your RunPod account for this pod only - 'runpodctl ssh remove-key --fingerprint $SSH_KEY_FINGERPRINT' revokes it sooner if you want that.)"
  fi
  log_info "Pod ID: $POD_ID   Model: $MODEL_REPO   Quantization: ${MODEL_QUANTIZATION:-auto}   Context: $MAX_MODEL_LEN   Idle limit: ${IDLE_MINUTES}m   Max runtime: ${MAX_RUNTIME_HOURS}h"

  # Fully-populated OpenCode provider config (see README's "Pointing
  # OpenCode at it" for the {env:...}-based version) - this one bakes the
  # actual baseURL/apiKey/model in directly rather than making the user
  # copy them into env vars by hand, since that's just another place to
  # typo a one-off value that's already only shown here, once. Schema
  # matches https://opencode.ai/config.json: top-level key is "provider"
  # (singular), the AI SDK package field is "npm" (not "package"), and
  # per-provider connection settings live under "options" (not
  # "settings") - confirmed against opencode's own docs 2026-08-15.
  log_info ""
  log_info "OpenCode config - paste as-is into ~/.config/opencode/opencode.json (contains the one-off API key above; not stored anywhere else, so save it now if you want it):"
  jq -n \
    --arg baseURL "https://$API_HOSTNAME/v1" \
    --arg apiKey "$VLLM_API_KEY" \
    --arg model "$SERVED_MODEL_NAME" \
    '{
      "$schema": "https://opencode.ai/config.json",
      provider: {
        "runpod-helper": {
          npm: "@ai-sdk/openai-compatible",
          name: "runpod-helper",
          options: { baseURL: $baseURL, apiKey: $apiKey },
          models: { ($model): { name: $model } }
        }
      }
    }'
}
