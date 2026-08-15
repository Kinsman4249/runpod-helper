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
PRESET_TABLE='
deepseek-r1-distill-32b|vllm|casperhansen/deepseek-r1-distill-qwen-32b-awq|deepseek-r1-32b|24|16384|auto|-|DeepSeek-R1-Distill-Qwen-32B (AWQ, ~19GB) - dense reasoning model
qwen3-32b|vllm|Qwen/Qwen3-32B-AWQ|qwen3-32b|24|16384|auto|-|Qwen3-32B (AWQ, ~19GB) - dense general-purpose
qwen3-coder-30b-moe|vllm|stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ|qwen3-coder-30b|24|32768|compressed-tensors|-|Qwen3-Coder-30B-A3B (AWQ, MoE ~3B active, ~17GB, quantization pinned to compressed-tensors - verified live 2026-08-14: this repos own config.json declares that method and vLLM 0.27.1 rejects --quantization auto against it, same failure class as qwen3.6-27b-awq-mtp below) - the Qwen Code MoE you asked for
qwen2.5-72b|vllm|Qwen/Qwen2.5-72B-Instruct-AWQ|qwen2.5-72b|48|8192|auto|-|Qwen2.5-72B-Instruct (AWQ, ~41GB) - bigger dense option
llama3.3-70b|vllm|casperhansen/llama-3.3-70b-instruct-awq|llama3.3-70b|48|8192|auto|-|Llama-3.3-70B-Instruct (AWQ, ~39GB) - non-Qwen/DeepSeek alternative in range
qwen3.5-40b-deckard|vllm|DavidAU/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking|qwen3.5-40b-deckard|80|262144|fp8|--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager|Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking (hybrid Gated DeltaNet/full-attention, bf16 repo, on-the-fly FP8 ~40GB weights, 256K context, needs an 80GB+ card - see CHANGELOG.md) - uncensored, tuned for tool use
qwen3.6-27b-awq-mtp|vllm|shawnw3i/Qwen3.6-27B-AWQ-MTP|qwen3.6-27b|24|16384|awq|--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager|Qwen3.6-27B-AWQ-MTP (hybrid Gated DeltaNet/full-attention, AWQ ~18GB weights, verified live 2026-08-14 on a 24GB L4) - agentic coding, MTP speculative decode support
qwen3.5-40b-deckard-gguf|llamacpp|mradermacher/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-GGUF:Q5_K_S|qwen3.5-40b-deckard|48|262144|-|-fa on --cache-type-k q8_0 --cache-type-v q8_0|Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking on llama.cpp (static GGUF, Q5_K_S ~27GB - the model cards own stated minimum for reliable tool calls, see mradermacher/...-GGUF; Q4 is smaller but the card explicitly warns against it for agentic/tool-call use), 256K context - min_vram is a first guess (hybrid arch needs far less KV cache than the dense vLLM path above at the same context, not yet measured live), bump if it OOMs
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

# --- preset + GPU selection -------------------------------------------------

pick_preset_and_gpu() {
  if [[ -f "$LAST_SESSION_FILE" && "$NEW_SESSION" != 1 ]]; then
    # shellcheck source=/dev/null
    source "$LAST_SESSION_FILE"
    [[ -n "${MODEL_REPO:-}" && -n "${GPU_ID:-}" && -n "${SERVED_MODEL_NAME:-}" && -n "${MAX_MODEL_LEN:-}" ]] && {
      # Backward compat: sessions saved before the quantization/extra-args/
      # engine columns existed have none of those vars at all - "auto"/"-"/
      # "vllm" is what every preset from that era actually ran with (vLLM's
      # own default, no extra flags, and the only engine that existed yet).
      MODEL_QUANTIZATION="${MODEL_QUANTIZATION:-auto}"
      MODEL_EXTRA_ARGS="${MODEL_EXTRA_ARGS:--}"
      ENGINE="${ENGINE:-vllm}"
      log_info "Reusing last session: model=$MODEL_REPO gpu=$GPU_ID max-model-len=$MAX_MODEL_LEN (pass --new to change)."
      return
    }
  fi

  local -a preset_values=() preset_engines=() preset_repos=() preset_served_names=() preset_min_vram=() preset_default_ctx=() preset_quants=() preset_extra_args=() preset_labels=()
  local line value engine repo served min_vram default_ctx quant extra_args label
  while IFS='|' read -r value engine repo served min_vram default_ctx quant extra_args label; do
    [[ -z "$value" ]] && continue
    preset_values+=("$value")
    preset_engines+=("$engine")
    preset_repos+=("$repo")
    preset_served_names+=("$served")
    preset_min_vram+=("$min_vram")
    preset_default_ctx+=("$default_ctx")
    preset_quants+=("$quant")
    preset_extra_args+=("$extra_args")
    preset_labels+=("$label")
  done <<< "$PRESET_TABLE"
  preset_values+=("custom")
  preset_labels+=("custom - paste any Hugging Face repo id (dense or MoE, any size - you confirm VRAM/volume needs yourself)")

  # Four-step wizard (preset, then GPU, then context length, then network
  # volume size for custom repos) where 'b' on any menu bounces back to
  # re-pick the previous one, instead of committing to a choice you can only
  # undo by re-running the whole script.
  local step="preset" preset_choice gpu_choice
  local min_vram=0 default_ctx=16384
  MODEL_QUANTIZATION="auto"
  MODEL_EXTRA_ARGS="-"
  while true; do
    case "$step" in
      preset)
        log_info ""
        log_info "Model:"
        select_from_menu "Choose a model" preset_choice "${preset_labels[@]}" || continue
        MODEL_PRESET="${preset_values[$((preset_choice - 1))]}"
        if [[ "$MODEL_PRESET" == "custom" ]]; then
          step="custom_repo"
        else
          ENGINE="${preset_engines[$((preset_choice - 1))]}"
          MODEL_REPO="${preset_repos[$((preset_choice - 1))]}"
          SERVED_MODEL_NAME="${preset_served_names[$((preset_choice - 1))]}"
          min_vram="${preset_min_vram[$((preset_choice - 1))]}"
          default_ctx="${preset_default_ctx[$((preset_choice - 1))]}"
          MODEL_QUANTIZATION="${preset_quants[$((preset_choice - 1))]}"
          MODEL_EXTRA_ARGS="${preset_extra_args[$((preset_choice - 1))]}"
          step="gpu"
        fi
        ;;
      custom_repo)
        prompt_text "Hugging Face repo id, e.g. org/model-name ($TEXT_BACK_WORD to go back): " MODEL_REPO || { step="preset"; continue; }
        [[ -n "$MODEL_REPO" ]] || die "No repo id entered."
        step="custom_served_name"
        ;;
      custom_served_name)
        prompt_text "Name to serve it as in the API (\"model\" field clients will send, $TEXT_BACK_WORD for repo id): " SERVED_MODEL_NAME || { step="custom_repo"; continue; }
        [[ -n "$SERVED_MODEL_NAME" ]] || die "No served-model-name entered."
        min_vram=0   # unknown model size - show every GPU, you check VRAM fit yourself.
        default_ctx=8192
        ENGINE="vllm"   # custom repos are vLLM-only for now - llama.cpp needs a repo:quant tag, not a bare HF repo id.
        MODEL_QUANTIZATION="auto"   # vLLM auto-detects from the repo's own config.json, same as the built-in AWQ presets.
        MODEL_EXTRA_ARGS="-"   # unknown architecture - if it's a hybrid Gated-DeltaNet model, you may need to add --gpu-memory-utilization/--kv-cache-dtype yourself; see PRESET_TABLE's comment above.
        log_warn "Custom repo: this script doesn't know its weight size, so the GPU list below isn't filtered by VRAM and the network-volume-size prompt after GPU selection isn't pre-sized either - check the model card yourself before picking."
        step="gpu"
        ;;
      gpu)
        log_info ""
        log_info "Fetching live GPU availability for datacenter $DATACENTER_ID..."
        # Filtering to the target datacenter and the preset's VRAM floor
        # here means a bad pick is no longer possible, instead of just
        # being warned about.
        local menu_rows
        menu_rows="$(list_available_gpus "$min_vram")" \
          || die "No GPUs meeting the ${min_vram}GB+ VRAM requirement are currently available in datacenter $DATACENTER_ID. Check https://www.runpod.io/console/gpu-cloud."

        local -a gpu_ids=() gpu_labels=()
        while IFS=$'\t' read -r gid dname vram price stock; do
          gpu_ids+=("$gid")
          gpu_labels+=("$(printf '%-20s %5sGB  $%s/hr  [%s]' "$dname" "$vram" "$price" "$stock")")
        done <<< "$menu_rows"

        log_info ""
        log_info "Available GPUs in $DATACENTER_ID (secure cloud \$/hr):"
        select_from_menu "Choose a GPU" gpu_choice "${gpu_labels[@]}" || { [[ "$MODEL_PRESET" == "custom" ]] && step="custom_served_name" || step="preset"; continue; }
        GPU_ID="${gpu_ids[$((gpu_choice - 1))]}"
        step="context"
        ;;
      context)
        log_info ""
        prompt_text "Context length in tokens (suggested $default_ctx for this model/GPU pairing, $TEXT_BACK_WORD to go back): " MAX_MODEL_LEN || { step="gpu"; continue; }
        [[ -z "$MAX_MODEL_LEN" ]] && MAX_MODEL_LEN="$default_ctx"
        [[ "$MAX_MODEL_LEN" =~ ^[0-9]+$ ]] || die "Context length must be a number."
        if [[ "$MODEL_PRESET" == "custom" && "$STORAGE_MODE" == "network-volume" ]]; then
          step="custom_volume_size"
        else
          break
        fi
        ;;
      custom_volume_size)
        log_info ""
        log_info "The network volume (currently attached: $NETWORK_VOLUME_ID) is what the model weights" \
                 "download into (HF_HOME) - see ensure_volume_size_at_least() below. RunPod only allows" \
                 "growing a volume, never shrinking it, and growing is a permanent, billed change."
        local custom_size
        prompt_text "Volume size this model needs, in GB (blank to leave the volume as-is, $TEXT_BACK_WORD for context length): " custom_size || { step="context"; continue; }
        if [[ -n "$custom_size" ]]; then
          [[ "$custom_size" =~ ^[0-9]+$ ]] || die "Volume size must be a number."
          ensure_volume_size_at_least "$custom_size"
        fi
        break
        ;;
    esac
  done

  mkdir -p "$CONFIG_DIR"
  ( umask 077
    printf 'MODEL_PRESET=%q\nENGINE=%q\nMODEL_REPO=%q\nSERVED_MODEL_NAME=%q\nGPU_ID=%q\nMAX_MODEL_LEN=%q\nMODEL_QUANTIZATION=%q\nMODEL_EXTRA_ARGS=%q\n' \
      "$MODEL_PRESET" "$ENGINE" "$MODEL_REPO" "$SERVED_MODEL_NAME" "$GPU_ID" "$MAX_MODEL_LEN" "$MODEL_QUANTIZATION" "$MODEL_EXTRA_ARGS" > "$LAST_SESSION_FILE"
  )
}

# --- network volume check ---------------------------------------------------

# Confirms the configured network volume still exists before we get any
# further, and offers to create a replacement (in the same datacenter,
# since a pod can only attach a volume from its own datacenter) if it's
# gone - e.g. deleted overnight to stop paying for idle storage.
ensure_network_volume() {
  runpodctl_t network-volume get "$NETWORK_VOLUME_ID" >/dev/null 2>&1 && return

  log_warn "Network volume $NETWORK_VOLUME_ID (from $CONFIG_FILE) doesn't exist anymore."
  confirm "Create a new one in datacenter $DATACENTER_ID now?" \
    || die "No network volume to attach. Run startup.sh --setup to point at a different one, or create one manually."

  log_info ""
  log_info "Sizing guide: 60GB covers one AWQ preset comfortably (~20-40GB weights" \
           "plus headroom), 100-150GB to cache several side by side. See" \
           "PREREQUISITES.md for the per-model table."
  # name/size navigate locally (nothing committed yet); this recovery flow
  # isn't part of a step sequence, so backing out of name (the first field)
  # just aborts - there's no earlier step to fall back to.
  local vol_name vol_size field="name"
  while true; do
    case "$field" in
      name)
        prompt_text "Volume name ($TEXT_BACK_WORD to cancel): " vol_name \
          || die "Cancelled. No network volume to attach. Run startup.sh --setup to point at a different one, or create one manually."
        field="size"
        ;;
      size)
        prompt_text "Volume size in GB ($TEXT_BACK_WORD for volume name): " vol_size || { field="name"; continue; }
        [[ -n "$vol_name" && "$vol_size" =~ ^[0-9]+$ ]] || die "Need a name and a numeric size in GB."
        break
        ;;
    esac
  done

  log_info "Creating volume (billed for as long as it exists, independent of" \
           "whether a pod is attached - see README for the rate)."
  create_network_volume "$vol_name" "$vol_size"

  sed -i "s|^NETWORK_VOLUME_ID=.*|NETWORK_VOLUME_ID=$NETWORK_VOLUME_ID|" "$CONFIG_FILE"
  log_ok "Saved new NETWORK_VOLUME_ID to $CONFIG_FILE."
}

# Grows the configured network volume to at least $1 GB if it's currently
# smaller - used for the custom-model path in pick_preset_and_gpu(), where a
# repo might need far more room than the sizing guide's presets assume.
# `network-volume update --size` only accepts a larger value than the
# current size (confirmed via `runpodctl network-volume update --help`,
# 2026-08-12) - growing is a one-way, billed change, so this only calls it
# when actually needed, not unconditionally.
ensure_volume_size_at_least() {
  local wanted_gb="$1"
  local current_gb
  current_gb="$(runpodctl_t network-volume get "$NETWORK_VOLUME_ID" 2>/dev/null | jq -r '.size // empty')"
  [[ -n "$current_gb" ]] || { log_warn "Could not read the current volume size - skipping the resize check. Check manually with 'runpodctl network-volume get $NETWORK_VOLUME_ID' if the download later fails for lack of space."; return; }

  if (( wanted_gb <= current_gb )); then
    log_info "Volume is already ${current_gb}GB (>= requested ${wanted_gb}GB) - no resize needed."
    return
  fi

  confirm "Grow network volume $NETWORK_VOLUME_ID from ${current_gb}GB to ${wanted_gb}GB now? (billed, permanent, cannot be undone by shrinking later)" \
    || { log_warn "Not resizing - the download may fail for lack of space if the model actually needs ${wanted_gb}GB."; return; }

  runpodctl_t network-volume update "$NETWORK_VOLUME_ID" --size "$wanted_gb" >/dev/null \
    || die "Volume resize failed. Check 'runpodctl network-volume get $NETWORK_VOLUME_ID' manually."
  log_ok "Volume $NETWORK_VOLUME_ID grown to ${wanted_gb}GB."
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

  local create_output
  create_output="$(runpodctl_t pod create \
    --cloud-type SECURE \
    --gpu-id "$GPU_ID" \
    --image "$image_name" \
    "${storage_args[@]}" \
    --terminate-after "$terminate_after" \
    --name "runpod-lab-$(date +%s)" \
    --ports "8000/http" \
    --env "$env_json" \
    --docker-args "$docker_args")" || die "Pod creation failed. Raw output:\n$create_output"

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
  log_warn "${ENGINE:-vllm} endpoint didn't respond within ${max_wait}s - it may still be loading, or something failed. Check the RunPod console (pod > Logs), or 'ssh -i $SSH_KEY_PATH root@\$SSH_PROXY_HOST.ssh.runpod.io' (resolve_pod_ssh_proxy_host() in lib/common.sh; requires a real terminal/PTY, see its comment - not scriptable)."
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

  [[ "${PREWARM:-0}" == 1 ]] && run_prewarm

  create_pod
  wait_for_pod_ready
  wait_for_vllm_ready
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
    log_info "Diagnostics: ssh -i $SSH_KEY_PATH root@$SSH_PROXY_HOST.ssh.runpod.io"
    log_info "  (proxy SSH, not direct-TCP - the bare vllm-openai image has no sshd. Requires a real terminal; needs a PTY. Key is registered with your RunPod account for this pod only - 'runpodctl ssh remove-key --fingerprint $SSH_KEY_FINGERPRINT' revokes it sooner if you want that.)"
  fi
  log_info "Pod ID: $POD_ID   Model: $MODEL_REPO   Quantization: ${MODEL_QUANTIZATION:-auto}   Context: $MAX_MODEL_LEN   Idle limit: ${IDLE_MINUTES}m   Max runtime: ${MAX_RUNTIME_HOURS}h"
}
