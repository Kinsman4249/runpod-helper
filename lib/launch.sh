# lib/launch.sh - normal pod launch (startup.sh section 1b), run every time
# except during the first-run setup wizard. Sourced by startup.sh.

CONTAINER_DISK_GB=40   # holds the vLLM image + OS only; weights live on the
                       # network volume (HF_HOME, see image/entrypoint.sh).
                       # vllm/vllm-openai is a much heavier base image than
                       # the old llama.cpp one (full CUDA/PyTorch/vLLM
                       # stack) - not yet measured against a real pull, bump
                       # this if it turns out too small.

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

# Built by ../image/Dockerfile, published by
# ../.github/workflows/build-image.yml on every push to image/**.
IMAGE_NAME="ghcr.io/kinsman4249/runpod-helper-image:latest"

# --- model presets -----------------------------------------------------------
# Every repo below was confirmed to exist via the HF API
# (huggingface.co/api/models/<repo>) as of 2026-08-12. Quantization method
# for the AWQ presets is auto-detected by vLLM from each repo's own
# config.json ("auto" here is literally passed as --quantization auto,
# vLLM's own default - not a magic value, just makes the flag unconditional
# for every preset including the on-the-fly ones below). min_vram is a floor
# (the GPU list is still filtered live against it, same as the old preset
# system), not a recommendation - a bigger card than the floor buys more
# KV-cache headroom and lets you push max-model-len higher than the
# suggested default below. Weight sizes are approximate (param count x
# ~4-8 bits/byte + overhead).
#
# Columns: value | HF repo | served-model-name | min_vram_gb | default max-model-len | quantization | label
PRESET_TABLE='
deepseek-r1-distill-32b|casperhansen/deepseek-r1-distill-qwen-32b-awq|deepseek-r1-32b|24|16384|auto|DeepSeek-R1-Distill-Qwen-32B (AWQ, ~19GB) - dense reasoning model
qwen3-32b|Qwen/Qwen3-32B-AWQ|qwen3-32b|24|16384|auto|Qwen3-32B (AWQ, ~19GB) - dense general-purpose
qwen3-coder-30b-moe|stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ|qwen3-coder-30b|24|32768|auto|Qwen3-Coder-30B-A3B (AWQ, MoE ~3B active, ~17GB) - the Qwen Code MoE you asked for
qwen2.5-72b|Qwen/Qwen2.5-72B-Instruct-AWQ|qwen2.5-72b|48|8192|auto|Qwen2.5-72B-Instruct (AWQ, ~41GB) - bigger dense option
llama3.3-70b|casperhansen/llama-3.3-70b-instruct-awq|llama3.3-70b|48|8192|auto|Llama-3.3-70B-Instruct (AWQ, ~39GB) - non-Qwen/DeepSeek alternative in range
qwen3.5-40b-deckard|DavidAU/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking|qwen3.5-40b-deckard|48|8192|fp8|Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking (bf16 repo, on-the-fly FP8, ~40GB) - uncensored, tuned for tool use
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
      # Backward compat: sessions saved before the quantization column
      # existed have no MODEL_QUANTIZATION at all - "auto" is what every
      # preset from that era actually ran with (vLLM's own default).
      MODEL_QUANTIZATION="${MODEL_QUANTIZATION:-auto}"
      log_info "Reusing last session: model=$MODEL_REPO gpu=$GPU_ID max-model-len=$MAX_MODEL_LEN (pass --new to change)."
      return
    }
  fi

  local -a preset_values=() preset_repos=() preset_served_names=() preset_min_vram=() preset_default_ctx=() preset_quants=() preset_labels=()
  local line value repo served min_vram default_ctx quant label
  while IFS='|' read -r value repo served min_vram default_ctx quant label; do
    [[ -z "$value" ]] && continue
    preset_values+=("$value")
    preset_repos+=("$repo")
    preset_served_names+=("$served")
    preset_min_vram+=("$min_vram")
    preset_default_ctx+=("$default_ctx")
    preset_quants+=("$quant")
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
          MODEL_REPO="${preset_repos[$((preset_choice - 1))]}"
          SERVED_MODEL_NAME="${preset_served_names[$((preset_choice - 1))]}"
          min_vram="${preset_min_vram[$((preset_choice - 1))]}"
          default_ctx="${preset_default_ctx[$((preset_choice - 1))]}"
          MODEL_QUANTIZATION="${preset_quants[$((preset_choice - 1))]}"
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
        MODEL_QUANTIZATION="auto"   # vLLM auto-detects from the repo's own config.json, same as the built-in AWQ presets.
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
    printf 'MODEL_PRESET=%q\nMODEL_REPO=%q\nSERVED_MODEL_NAME=%q\nGPU_ID=%q\nMAX_MODEL_LEN=%q\nMODEL_QUANTIZATION=%q\n' \
      "$MODEL_PRESET" "$MODEL_REPO" "$SERVED_MODEL_NAME" "$GPU_ID" "$MAX_MODEL_LEN" "$MODEL_QUANTIZATION" > "$LAST_SESSION_FILE"
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

# --- prewarm: model download on a cheap CPU pod -----------------------------

# CPU pods are billed at a small fraction of GPU rates (RunPod pricing, not
# independently re-quoted here - check https://www.runpod.io/console/gpu-cloud
# for current CPU pod rates). Downloading multi-GB model weights here instead
# of on the GPU pod means you're not paying GPU-hour rates for pure
# network-bound work. Both pods mount the same network volume at the same
# path (/workspace/persistent), so anything written here is immediately
# visible to the GPU pod that launches after it.
maybe_run_prewarm() {
  if [[ "${FORCE_PREWARM:-0}" != 1 && "${PREWARMED_MODEL_REPO:-}" == "$MODEL_REPO" && "${PREWARMED_VOLUME_ID:-}" == "$NETWORK_VOLUME_ID" ]]; then
    log_info "Volume already prewarmed for $MODEL_REPO - skipping. Pass --prewarm to force a re-run."
    return
  fi

  log_info ""
  log_info "Prewarming network volume: downloading $MODEL_REPO weights on a cheap CPU pod..."

  # RUNPOD_API_KEY is needed so entrypoint.sh's PREWARM_ONLY branch can
  # self-terminate this pod via runpodctl once it's done - see the big
  # comment on the wait loop below for why that's not optional.
  local env_json create_output prewarm_pod_id
  env_json=$(printf '{"PREWARM_ONLY":"1","MODEL_REPO":"%s","RUNPOD_API_KEY":"%s"}' "$MODEL_REPO" "$RUNPOD_API_KEY")

  # --compute-type confirmed against a live `runpodctl pod create` call
  # (2026-07-31, pod id 4xfim5k1etd6xs) - CPU pods take no --gpu-id, and
  # there's no --vcpu/--mem flag at all (unlike the deprecated top-level
  # `runpodctl create pod` alias, which has different, camelCase flag names -
  # don't confuse the two). Defaults to 2 vcpu/4GB mem, $0.06/hr in EUR-IS-1.
  create_output="$(runpodctl_t pod create \
    --compute-type CPU \
    --image "$IMAGE_NAME" \
    --network-volume-id "$NETWORK_VOLUME_ID" \
    --volume-mount-path /workspace/persistent \
    --container-disk-in-gb 10 \
    --name "runpod-lab-prewarm-$(date +%s)" \
    --env "$env_json")" || die "Prewarm pod creation failed. Raw output:\n$create_output"

  prewarm_pod_id="$(jq -r '.id // empty' <<< "$create_output")"
  [[ -n "$prewarm_pod_id" ]] || die "Prewarm pod created but no id found in the response: $create_output"
  log_ok "Prewarm pod created: $prewarm_pod_id"

  # A stuck prewarm pod is still real money (if not much) - clean it up on
  # every exit path out of this function, not just the happy one.
  # `|| true` on both: the pod usually self-terminates already (see below),
  # so these normally fail (pod not found) - under `set -e`, a failing
  # command inside a RETURN trap was observed live (2026-08-01) to make the
  # whole script exit non-zero despite everything actually succeeding.
  trap 'runpodctl_t pod stop "'"$prewarm_pod_id"'" >/dev/null 2>&1 || true; runpodctl_t pod delete "'"$prewarm_pod_id"'" >/dev/null 2>&1 || true' RETURN

  # Confirmed live (2026-08-01): RunPod restarts a pod's container on ANY
  # exit, including a clean `exit 0` - polling for status to merely leave
  # "running" never works, since a pod that just finishes and exits gets
  # immediately relaunched by RunPod itself and looks "running" forever.
  # entrypoint.sh's PREWARM_ONLY branch self-terminates via runpodctl once
  # it's done (needs $RUNPOD_API_KEY, passed above), so completion here
  # means the `pod get` call itself starts erroring (pod no longer exists) -
  # that's the real signal, not the status text. The still-running check
  # stays as a secondary signal in case self-termination didn't fire.
  #
  # BUT: "pod get errors / not running" also happens if the pod never
  # actually started (image pull failure, capacity/scheduling problem) and
  # RunPod cleans it up on its own - confirmed live 2026-08-01, a prewarm
  # pod vanished (404 on `pod get`) within ~20-30s, and this loop reported
  # "Prewarm finished" even though the volume had nothing on it at all.
  # A multi-GB model download cannot genuinely finish that fast, so
  # MIN_PREWARM_SECONDS below is a floor: disappearing before it elapses is
  # treated as a failure, not success, same as the max_wait timeout branch
  # already does.
  #
  # The completion check itself also used to grep the raw JSON for the
  # substring '"error"' - wrong, because `pod get`'s response nests
  # {"ssh": {"error": "pod not ready", ...}} for as long as SSH isn't up
  # yet, completely unrelated to whether the pod itself is fine. Checking
  # for the absence of `.desiredStatus` (only present on a real pod object)
  # is the precise signal instead. min_wait alone is NOT proof of a real
  # finish either (confirmed live twice, 2026-08-01 and 2026-08-03, that a
  # pod stuck at uptimeSeconds=0 the whole time can still sit around past
  # min_wait before vanishing) - track whether uptimeSeconds was EVER
  # observed > 0 and require it before trusting min_wait.
  log_info "Waiting for prewarm to finish (model download can take a while on first run)..."
  local waited=0 max_wait=3600 min_wait=60 get_output pod_status uptime saw_real_uptime=0
  while (( waited < max_wait )); do
    # `|| true`: runpodctl exits non-zero once the pod is gone (404), and
    # under `set -e` a failing command substitution assignment kills the
    # whole script right here - before the jq check below, which is the
    # code that's actually supposed to handle a gone pod, ever runs.
    get_output="$(runpodctl_t pod get "$prewarm_pod_id" 2>&1)" || true
    if ! pod_status="$(jq -e -r '.desiredStatus' <<< "$get_output" 2>/dev/null)"; then
      break  # response is a bare error object (no pod fields at all) - genuinely gone.
    fi
    uptime="$(jq -r '.uptimeSeconds // 0' <<< "$get_output" 2>/dev/null)"
    [[ "${uptime:-0}" =~ ^[0-9]+$ && "$uptime" -gt 0 ]] && saw_real_uptime=1
    [[ "$pod_status" != "RUNNING" ]] && break  # stopped/exited but not yet deleted.
    sleep 15; waited=$((waited + 15))
  done

  if (( waited >= max_wait )); then
    log_warn "Prewarm pod still reports running after ${max_wait}s - stopping it now regardless. Model download may be incomplete; the GPU pod will finish the job itself if so, or rerun with --prewarm later."
    return
  fi

  if (( waited < min_wait )); then
    log_warn "Prewarm pod disappeared after only ${waited}s - too fast to be a genuine finish (a multi-GB download takes much longer). Likely a scheduling/image-pull failure, not success. Not marking this volume as prewarmed; the GPU pod will do the download itself, or rerun with --prewarm after checking the console."
    return
  fi

  if (( saw_real_uptime == 0 )); then
    log_warn "Prewarm pod never reported uptimeSeconds > 0 in ${waited}s before disappearing - it never actually booted far enough to run entrypoint.sh (RunPod-side flakiness, e.g. stuck ssh.error/'pod not ready'), so nothing was downloaded. Not marking this volume as prewarmed; rerun with --prewarm once RunPod is stable."
    return
  fi

  log_ok "Prewarm finished."
  sed -i '/^PREWARMED_VOLUME_ID=/d;/^PREWARMED_MODEL_REPO=/d' "$CONFIG_FILE"
  printf 'PREWARMED_VOLUME_ID=%q\nPREWARMED_MODEL_REPO=%q\n' "$NETWORK_VOLUME_ID" "$MODEL_REPO" >> "$CONFIG_FILE"
}

# --- pod creation ------------------------------------------------------------

create_pod() {
  local terminate_after
  # --terminate-after is a confirmed native runpodctl flag (absolute
  # ISO-8601 datetime) - a hard backstop that fires even if idle-watchdog.sh
  # itself has crashed or its request-activity detection is misbehaving.
  terminate_after="$(date -u -d "+${MAX_RUNTIME_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

  # One-off keypair (registered with RunPod, baked into this pod's
  # authorized_keys at boot) and one-off vLLM bearer token, both generated
  # fresh right here instead of reused from setup - see
  # setup_ephemeral_ssh_key() in lib/common.sh. Must run before the
  # `pod create` call below: RunPod only bakes keys that are ALREADY
  # registered to the account into a new pod's authorized_keys at boot.
  setup_ephemeral_ssh_key
  VLLM_API_KEY="$(openssl rand -hex 32)"

  log_info ""
  log_info "Creating pod (GPU $GPU_ID, model $MODEL_REPO, auto-terminate at $terminate_after UTC)..."

  # --env deliberately carries ONLY these seven names - no GitHub
  # credential, no git identity, no Cloudflare token: this pod only serves
  # inference, reached directly over its own 22/tcp and RunPod's own HTTP
  # proxy (see wait_for_pod_ready()/run_normal_launch() below), nothing on
  # it edits or commits code anymore.
  local env_json
  env_json=$(printf '{"MODEL_REPO":"%s","SERVED_MODEL_NAME":"%s","MAX_MODEL_LEN":"%s","QUANTIZATION":"%s","VLLM_API_KEY":"%s","IDLE_MINUTES":"%s","RUNPOD_API_KEY":"%s","DISABLE_LOGGING":"%s"}' \
    "$MODEL_REPO" "$SERVED_MODEL_NAME" "$MAX_MODEL_LEN" "${MODEL_QUANTIZATION:-auto}" "$VLLM_API_KEY" "$IDLE_MINUTES" "$RUNPOD_API_KEY" "${NUKE_LOGGING:-0}")

  # STORAGE_MODE=container-disk omits --network-volume-id/--volume-mount-path
  # entirely - with nothing mounted at /workspace/persistent, entrypoint.sh's
  # `mkdir -p "$PERSIST_DIR/..."` calls just create plain directories on the
  # pod's own (bigger) container disk instead, no entrypoint.sh change
  # needed. See CONTAINER_DISK_GB_STANDALONE above for the sizing rationale.
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

  local create_output
  create_output="$(runpodctl_t pod create \
    --cloud-type SECURE \
    --gpu-id "$GPU_ID" \
    --image "$IMAGE_NAME" \
    "${storage_args[@]}" \
    --terminate-after "$terminate_after" \
    --name "runpod-lab-$(date +%s)" \
    --env "$env_json")" || die "Pod creation failed. Raw output:\n$create_output"

  # Picking specific fields (rather than printing $create_output raw) is
  # deliberate: the response's "env" array echoes back RUNPOD_API_KEY and
  # VLLM_API_KEY in plaintext, which has no business hitting the terminal
  # or a captured log.
  POD_ID="$(jq -r '.id // empty' <<< "$create_output")"
  [[ -n "$POD_ID" ]] || die "Pod created but no id found in the response: $create_output"

  # RunPod auto-exposes any HTTP port a pod's process listens on at this
  # URL, no config needed (confirmed live 2026-08-14: curling
  # https://<pod-id>-8000.proxy.runpod.net/v1/models against a plain
  # vllm-openai pod worked immediately, 401 without the bearer token, 200
  # with it) - this is what used to need a whole Cloudflare Tunnel setup.
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

  # Pod status alone doesn't mean sshd is up yet inside it - actually
  # reaching it over its own direct 22/tcp (resolve_pod_ssh_endpoint(),
  # lib/common.sh) is the real readiness signal, not just the API's status
  # field. Also sets SSH_HOST/SSH_PORT for anything later that needs to ssh
  # in (diagnostics, the final launch summary).
  log_info "Resolving the pod's direct SSH endpoint..."
  resolve_pod_ssh_endpoint || die "Pod is running but never got a direct SSH endpoint - check the console."

  log_info "Waiting for SSH to come up..."
  waited=0
  while (( waited < max_wait )); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null \
         -i "$SSH_KEY_PATH" -p "$SSH_PORT" "root@$SSH_HOST" true 2>/dev/null; then
      log_ok "SSH reachable."
      return
    fi
    sleep 10; waited=$((waited + 10))
  done
  die "SSH never came up within ${max_wait}s. Pod is running but entrypoint.sh may have failed - check the console."
}

# SSH being up only means entrypoint.sh started - it says nothing about
# whether vLLM has finished loading a (potentially tens-of-GB) model into
# VRAM yet. Poll the actual public endpoint (RunPod's own per-pod proxy
# URL, the same path a real client uses) so "Pod ready" means the API
# genuinely works, not just that the container booted.
wait_for_vllm_ready() {
  log_info ""
  log_info "Waiting for the vLLM endpoint to finish loading $MODEL_REPO (this can take several minutes for a large model)..."
  local waited=0 max_wait=1800
  while (( waited < max_wait )); do
    if curl -fsS --max-time 5 -o /dev/null \
         -H "Authorization: Bearer $VLLM_API_KEY" \
         "https://$API_HOSTNAME/v1/models"; then
      log_ok "vLLM endpoint is serving."
      return
    fi
    sleep 15; waited=$((waited + 15))
  done
  log_warn "vLLM endpoint didn't respond within ${max_wait}s - it may still be loading, or something failed. Check 'ssh -i $SSH_KEY_PATH -p $SSH_PORT root@$SSH_HOST' and look at the container's own stdout (RunPod console > pod > Logs), since this script doesn't have a way to tail that remotely."
}

# --- entry point -------------------------------------------------------------

run_normal_launch() {
  if [[ "$STORAGE_MODE" == "network-volume" ]]; then
    ensure_network_volume
  else
    log_info "STORAGE_MODE=container-disk: no network volume, model weights will download fresh onto the pod's own disk this run."
  fi
  pick_preset_and_gpu
  if [[ "$STORAGE_MODE" == "network-volume" ]]; then
    maybe_run_prewarm
  fi

  if [[ "${PREWARM_ONLY:-0}" == 1 ]]; then
    log_info ""
    log_ok "Prewarm-only run done - no GPU pod created. Launch normally when you're ready."
    return
  fi

  create_pod
  wait_for_pod_ready
  wait_for_vllm_ready

  log_info ""
  log_ok "Pod ready."
  log_info "OpenAI-compatible endpoint: https://$API_HOSTNAME/v1"
  log_info "Model name for clients: $SERVED_MODEL_NAME"
  log_info "API key (Authorization: Bearer <key> - one-off, generated for this pod, shown once, not stored anywhere): $VLLM_API_KEY"
  log_info "Diagnostics: ssh -i $SSH_KEY_PATH -p $SSH_PORT root@$SSH_HOST"
  log_info "  (that SSH key is registered with your RunPod account for this pod only - it stops being useful once the pod is stopped/deleted, and 'runpodctl ssh remove-key --fingerprint $SSH_KEY_FINGERPRINT' revokes it from your account sooner if you want that.)"
  log_info "Pod ID: $POD_ID   Model: $MODEL_REPO   Quantization: ${MODEL_QUANTIZATION:-auto}   Context: $MAX_MODEL_LEN   Idle limit: ${IDLE_MINUTES}m   Max runtime: ${MAX_RUNTIME_HOURS}h"
}
