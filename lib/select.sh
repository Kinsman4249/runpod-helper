# lib/select.sh - launch-time selection: which model/quant, which GPU, and
# (for custom repos) how big the network volume needs to be. Split out of
# lib/launch.sh 2026-08-15 to keep that file under 500 lines; the pod-creation
# and readiness machinery stays there. Sourced by startup.sh and e2e-test.sh
# after lib/launch.sh (this file calls list_available_gpus/PRESET_TABLE from
# there and the menu/prompt helpers from lib/common.sh at run time, so source
# order among the libs doesn't matter as long as all are loaded before a launch
# actually runs). The custom-GGUF path also uses lib/gguf.sh.

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
      # Floor the capacity-failure fallback (offer_alternate_gpu) re-lists
      # against. Sessions saved before this var existed don't have it; 0 just
      # means "show every available card" in that fallback, which is fine.
      GPU_MIN_VRAM="${MIN_VRAM:-0}"
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
  preset_values+=("custom-gguf")
  preset_labels+=("custom-gguf - paste any Hugging Face GGUF repo id, then pick a quant from what it actually publishes (sizes pulled live; served with llama.cpp)")

  # Step machine (preset -> GPU -> context -> network volume for custom repos),
  # where 'b' on any menu bounces back to re-pick the previous one instead of
  # committing to a choice you can only undo by re-running the whole script.
  # The custom and custom-gguf paths insert their own extra steps before GPU.
  local step="preset" preset_choice gpu_choice
  local min_vram=0 default_ctx=16384
  # custom-gguf carries a few extra locals (repo, chosen quant, the parallel
  # quant menu arrays, and a suggested volume size) - declared here so they
  # persist across step iterations within this one function call.
  local GGUF_REPO="" GGUF_QUANT="" gguf_suggested_vol_gb=0
  local -a gguf_quants=() gguf_sizes=() gguf_labels=()
  MODEL_QUANTIZATION="auto"
  MODEL_EXTRA_ARGS="-"
  while true; do
    case "$step" in
      preset)
        log_info ""
        log_info "Model:"
        select_from_menu "Choose a model" preset_choice "${preset_labels[@]}" || continue
        MODEL_PRESET="${preset_values[$((preset_choice - 1))]}"
        case "$MODEL_PRESET" in
          custom)      step="custom_repo" ;;
          custom-gguf) step="gguf_repo" ;;
          *)
            ENGINE="${preset_engines[$((preset_choice - 1))]}"
            MODEL_REPO="${preset_repos[$((preset_choice - 1))]}"
            SERVED_MODEL_NAME="${preset_served_names[$((preset_choice - 1))]}"
            min_vram="${preset_min_vram[$((preset_choice - 1))]}"
            default_ctx="${preset_default_ctx[$((preset_choice - 1))]}"
            MODEL_QUANTIZATION="${preset_quants[$((preset_choice - 1))]}"
            MODEL_EXTRA_ARGS="${preset_extra_args[$((preset_choice - 1))]}"
            step="gpu"
            ;;
        esac
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
      gguf_repo)
        prompt_text "Hugging Face GGUF repo id, e.g. mradermacher/Model-GGUF ($TEXT_BACK_WORD to go back): " GGUF_REPO || { step="preset"; continue; }
        [[ -n "$GGUF_REPO" ]] || die "No repo id entered."
        log_info "Fetching the quants $GGUF_REPO publishes (sizes from Hugging Face)..."
        local gguf_rows
        gguf_rows="$(list_gguf_quants "$GGUF_REPO")" \
          || die "Couldn't find any GGUF quants in '$GGUF_REPO'. Double-check the repo id, and that it actually holds .gguf files - browse https://huggingface.co/$GGUF_REPO/tree/main."
        gguf_quants=(); gguf_sizes=(); gguf_labels=()
        local gq gs gr
        while IFS=$'\t' read -r gq gs gr; do
          gguf_quants+=("$gq")
          gguf_sizes+=("$gs")
          # "  (recommended)" only when the repo README flags this quant that way.
          gguf_labels+=("$(printf '%-10s %9s%s' "$gq" "$(gguf_human_size "$gs")" "$([[ "$gr" == 1 ]] && printf '   (recommended)')")")
        done <<< "$gguf_rows"
        step="gguf_quant"
        ;;
      gguf_quant)
        log_info ""
        log_info "Quants in $GGUF_REPO (size on disk; VRAM needed is a bit more - see the floor below):"
        local gguf_choice weights_bytes weights_gb
        select_from_menu "Choose a quant" gguf_choice "${gguf_labels[@]}" || { step="gguf_repo"; continue; }
        GGUF_QUANT="${gguf_quants[$((gguf_choice - 1))]}"
        weights_bytes="${gguf_sizes[$((gguf_choice - 1))]}"
        weights_gb="$(gguf_weight_gb_ceil "$weights_bytes")"
        # llama.cpp takes the "<repo>:<quant tag>" form directly as --hf-repo
        # (see create_pod() and PRESET_TABLE's GGUF rows in lib/launch.sh).
        ENGINE="llamacpp"
        MODEL_REPO="$GGUF_REPO:$GGUF_QUANT"
        MODEL_QUANTIZATION="-"
        MODEL_EXTRA_ARGS="-"
        # Approximate floor: weights + a small KV/compute cushion (see
        # GGUF_VRAM_HEADROOM_GB in lib/gguf.sh). The GPU list still shows every
        # card at/above it, so a low guess just means picking a bigger one.
        min_vram=$(( weights_gb + GGUF_VRAM_HEADROOM_GB ))
        default_ctx=16384
        gguf_suggested_vol_gb=$(( weights_gb + 5 ))
        log_info "Picked $GGUF_QUANT (~$(gguf_human_size "$weights_bytes") on disk). GPU list will filter to >= ${min_vram}GB VRAM (weights + ~${GGUF_VRAM_HEADROOM_GB}GB headroom, approximate)."
        step="gguf_served_name"
        ;;
      gguf_served_name)
        local gguf_default_served="${GGUF_REPO##*/}"
        gguf_default_served="${gguf_default_served%-[Gg][Gg][Uu][Ff]}"   # drop a trailing -GGUF
        prompt_text "Name to serve it as in the API (blank for \"$gguf_default_served\", $TEXT_BACK_WORD to re-pick the quant): " SERVED_MODEL_NAME || { step="gguf_quant"; continue; }
        [[ -z "$SERVED_MODEL_NAME" ]] && SERVED_MODEL_NAME="$gguf_default_served"
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
        # Backing out of GPU returns to whichever step precedes it for this
        # path: the served-name prompt for custom/custom-gguf, else the preset.
        select_from_menu "Choose a GPU" gpu_choice "${gpu_labels[@]}" || {
          case "$MODEL_PRESET" in
            custom)      step="custom_served_name" ;;
            custom-gguf) step="gguf_served_name" ;;
            *)           step="preset" ;;
          esac
          continue
        }
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
        elif [[ "$MODEL_PRESET" == "custom-gguf" && "$STORAGE_MODE" == "network-volume" ]]; then
          # We know this quant's on-disk size, so size the volume for it
          # automatically (ensure_volume_size_at_least only grows, and confirms
          # first) instead of asking the operator to guess a number.
          log_info ""
          log_info "This quant needs roughly ${gguf_suggested_vol_gb}GB on the network volume (weights + a little headroom)."
          ensure_volume_size_at_least "$gguf_suggested_vol_gb"
          break
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

  # The VRAM floor this model was picked against - saved so a later reused
  # session (and the capacity-failure fallback offer_alternate_gpu below) can
  # re-list GPUs against the same floor. Also exported as a global for this
  # run's own fallback.
  GPU_MIN_VRAM="$min_vram"

  mkdir -p "$CONFIG_DIR"
  ( umask 077
    printf 'MODEL_PRESET=%q\nENGINE=%q\nMODEL_REPO=%q\nSERVED_MODEL_NAME=%q\nGPU_ID=%q\nMAX_MODEL_LEN=%q\nMODEL_QUANTIZATION=%q\nMODEL_EXTRA_ARGS=%q\nMIN_VRAM=%q\n' \
      "$MODEL_PRESET" "$ENGINE" "$MODEL_REPO" "$SERVED_MODEL_NAME" "$GPU_ID" "$MAX_MODEL_LEN" "$MODEL_QUANTIZATION" "$MODEL_EXTRA_ARGS" "$min_vram" > "$LAST_SESSION_FILE"
  )
}

# --- capacity-failure fallback ----------------------------------------------
# RunPod's `gpu list` (list_available_gpus) reflects datacenter-wide stock, but
# an individual `pod create` can still be rejected with a graphql "This machine
# does not have the resources to deploy your pod. Please try a different
# machine" error when the specific host it tried is momentarily full. create_pod
# classifies that as retryable (returns 2 instead of dying); this re-lists the
# cards still meeting the model's VRAM floor, drops the one that just failed,
# and lets you pick another to retry with. Returns 0 with GPU_ID updated to
# retry, or 1 to give up (no alternatives, or you backed out).
offer_alternate_gpu() {
  local failed_gpu="$1"
  log_info ""
  log_info "Re-checking live GPU availability in $DATACENTER_ID for another card meeting the ${GPU_MIN_VRAM:-0}GB+ floor..."
  local menu_rows
  menu_rows="$(list_available_gpus "${GPU_MIN_VRAM:-0}")" || {
    log_error "No GPUs meeting the ${GPU_MIN_VRAM:-0}GB+ floor are available in $DATACENTER_ID right now. Try again shortly, or check https://www.runpod.io/console/gpu-cloud."
    return 1
  }

  local -a gpu_ids=() gpu_labels=()
  while IFS=$'\t' read -r gid dname vram price stock; do
    [[ "$gid" == "$failed_gpu" ]] && continue   # the card that just failed - don't re-offer it
    gpu_ids+=("$gid")
    gpu_labels+=("$(printf '%-20s %5sGB  $%s/hr  [%s]' "$dname" "$vram" "$price" "$stock")")
  done <<< "$menu_rows"
  (( ${#gpu_ids[@]} > 0 )) || {
    log_error "No other GPUs meeting the ${GPU_MIN_VRAM:-0}GB+ floor are available right now besides the one that just failed. Try again shortly."
    return 1
  }

  log_info ""
  log_info "Other available GPUs in $DATACENTER_ID (secure cloud \$/hr):"
  local gpu_choice
  select_from_menu "Choose a different GPU to retry with" gpu_choice "${gpu_labels[@]}" || return 1
  GPU_ID="${gpu_ids[$((gpu_choice - 1))]}"

  # Keep last-session pointed at the card we're actually retrying with, so a
  # later plain `./startup.sh` reuse doesn't jump straight back to the one that
  # had no capacity. Best-effort - a missing/unwritable file just means the
  # next run re-picks normally.
  [[ -f "$LAST_SESSION_FILE" ]] && sed -i "s|^GPU_ID=.*|GPU_ID=$(printf '%q' "$GPU_ID")|" "$LAST_SESSION_FILE"
  log_info "Retrying with GPU $GPU_ID..."
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
# smaller - used for the custom-model paths in pick_preset_and_gpu(), where a
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
