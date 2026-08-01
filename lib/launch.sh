# lib/launch.sh - normal pod launch (startup.sh section 1b), run every time
# except during the first-run setup wizard. Sourced by startup.sh.

CONTAINER_DISK_GB=25   # code + OS only; models live on the network volume.

# Built by ../image/Dockerfile, published by
# ../.github/workflows/build-image.yml on every push to image/**. Not yet
# confirmed pullable by a live pod - see this repo's handoff.md.
IMAGE_NAME="ghcr.io/kinsman4249/runpod-helper-image:latest"

# --- preset + GPU selection -------------------------------------------------

pick_preset_and_gpu() {
  if [[ -f "$LAST_SESSION_FILE" && "$NEW_SESSION" != 1 ]]; then
    # shellcheck source=/dev/null
    source "$LAST_SESSION_FILE"
    [[ -n "${MODEL_PRESET:-}" && -n "${GPU_ID:-}" && -n "${FRONTEND:-}" ]] && {
      log_info "Reusing last session: preset=$MODEL_PRESET gpu=$GPU_ID frontend=$FRONTEND (pass --new to change)."
      return
    }
  fi

  local -a preset_values=("qwen36-27b" "qwen3-coder-next")
  local -a preset_labels=(
    "qwen36-27b       - dense model, runs on any GPU tier including RTX 4090"
    "qwen3-coder-next - MoE model, needs 40GB+ VRAM (A6000 / L40S / A100 class)"
  )

  # Only one frontend runs per pod (see image/entrypoint.sh) - all three
  # listen on port 3000, the one port the Cloudflare tunnel forwards, so
  # this is a straight either/or, not a multi-select.
  local -a frontend_values=("openhands" "llama-webui" "open-webui")
  local -a frontend_labels=(
    "openhands   - OpenHands coding agent GUI"
    "llama-webui - llama.cpp's own built-in chat UI (lightest option)"
    "open-webui  - Open WebUI, general-purpose chat frontend"
  )

  # Three-step wizard (preset, then GPU, then frontend) where 'b' on any
  # menu bounces back to re-pick the previous one, instead of committing to
  # a choice you can only undo by re-running the whole script.
  local step="preset" preset_choice gpu_choice frontend_choice
  while true; do
    case "$step" in
      preset)
        log_info ""
        log_info "Model preset:"
        select_from_menu "Choose a preset" preset_choice "${preset_labels[@]}" || continue
        MODEL_PRESET="${preset_values[$((preset_choice - 1))]}"
        step="gpu"
        ;;
      gpu)
        log_info ""
        log_info "Fetching live GPU availability for datacenter $DATACENTER_ID..."
        local gpu_json
        gpu_json="$(runpodctl gpu list)" || die "Could not list GPUs - check https://www.runpod.io/console/gpu-cloud instead."

        local min_vram=0
        [[ "$MODEL_PRESET" == "qwen3-coder-next" ]] && min_vram=40

        # Field names (gpuId, displayName, memoryInGb, securePricePerHr,
        # dataCenterAvailability[].stockStatus) confirmed against live
        # `runpodctl gpu list` JSON output this session. Filtering to the
        # target datacenter and the preset's VRAM floor here means a bad
        # pick is no longer possible, instead of just being warned about.
        local menu_rows
        menu_rows="$(jq -r --arg dc "$DATACENTER_ID" --argjson minvram "$min_vram" '
          .[]
          | . as $g
          | ($g.dataCenterAvailability[]? | select(.dataCenterId == $dc) | .stockStatus) as $stock
          | select($stock != "none")
          | select($g.memoryInGb >= $minvram)
          | [$g.gpuId, $g.displayName, ($g.memoryInGb | tostring), ($g.securePricePerHr | tostring), $stock]
          | @tsv
        ' <<< "$gpu_json" | sort -t $'\t' -k4 -n)"

        [[ -n "$menu_rows" ]] || die "No GPUs meeting the ${min_vram}GB+ VRAM requirement are currently available in datacenter $DATACENTER_ID. Check https://www.runpod.io/console/gpu-cloud."

        local -a gpu_ids=() gpu_labels=()
        while IFS=$'\t' read -r gid dname vram price stock; do
          gpu_ids+=("$gid")
          gpu_labels+=("$(printf '%-20s %5sGB  $%s/hr  [%s]' "$dname" "$vram" "$price" "$stock")")
        done <<< "$menu_rows"

        log_info ""
        log_info "Available GPUs in $DATACENTER_ID (secure cloud \$/hr):"
        select_from_menu "Choose a GPU" gpu_choice "${gpu_labels[@]}" || { step="preset"; continue; }
        GPU_ID="${gpu_ids[$((gpu_choice - 1))]}"
        step="frontend"
        ;;
      frontend)
        log_info ""
        log_info "Frontend (the one thing served on port 3000 through the tunnel):"
        select_from_menu "Choose a frontend" frontend_choice "${frontend_labels[@]}" || { step="gpu"; continue; }
        FRONTEND="${frontend_values[$((frontend_choice - 1))]}"
        break
        ;;
    esac
  done

  mkdir -p "$CONFIG_DIR"
  ( umask 077
    printf 'MODEL_PRESET=%q\nGPU_ID=%q\nFRONTEND=%q\n' "$MODEL_PRESET" "$GPU_ID" "$FRONTEND" > "$LAST_SESSION_FILE"
  )
}

# --- network volume check ---------------------------------------------------

# Confirms the configured network volume still exists before we get any
# further, and offers to create a replacement (in the same datacenter,
# since a pod can only attach a volume from its own datacenter) if it's
# gone - e.g. deleted overnight to stop paying for idle storage.
ensure_network_volume() {
  runpodctl network-volume get "$NETWORK_VOLUME_ID" >/dev/null 2>&1 && return

  log_warn "Network volume $NETWORK_VOLUME_ID (from $CONFIG_FILE) doesn't exist anymore."
  confirm "Create a new one in datacenter $DATACENTER_ID now?" \
    || die "No network volume to attach. Run startup.sh --setup to point at a different one, or create one manually."

  log_info ""
  log_info "Sizing guide: 60GB for 4-bit weights, 100GB for 8-bit or a single" \
           "fp16 model, 150-200GB to keep both presets side by side."
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

# --- prewarm: toolchain + model download on a cheap CPU pod -----------------

# CPU pods are billed at a small fraction of GPU rates (RunPod pricing, not
# independently re-quoted here - check https://www.runpod.io/console/gpu-cloud
# for current CPU pod rates). Running the multi-GB toolchain install and
# model download on one of these instead of the GPU pod means you're not
# paying GPU-hour rates for pure network/CPU-bound work. Both pods mount the
# same network volume at the same path (/workspace/persistent), so anything
# written here is immediately visible to the GPU pod that launches after it.
maybe_run_prewarm() {
  if [[ "${FORCE_PREWARM:-0}" != 1 && "${PREWARMED_VOLUME_ID:-}" == "$NETWORK_VOLUME_ID" ]]; then
    log_info "Volume already prewarmed (toolchain cached) - skipping. Pass --prewarm to force a re-run."
    return
  fi

  log_info ""
  log_info "Prewarming network volume: installing gh/cloudflared/uv/OpenHands/Open WebUI and downloading $MODEL_PRESET weights on a cheap CPU pod..."

  # RUNPOD_API_KEY is needed so entrypoint.sh's PREWARM_ONLY branch can
  # self-terminate this pod via runpodctl once it's done - see the big
  # comment on the wait loop below for why that's not optional.
  local env_json create_output prewarm_pod_id
  env_json=$(printf '{"PREWARM_ONLY":"1","MODEL_PRESET":"%s","RUNPOD_API_KEY":"%s"}' "$MODEL_PRESET" "$RUNPOD_API_KEY")

  # --compute-type confirmed against a live `runpodctl pod create` call
  # (2026-07-31, pod id 4xfim5k1etd6xs) - CPU pods take no --gpu-id, and
  # there's no --vcpu/--mem flag at all (unlike the deprecated top-level
  # `runpodctl create pod` alias, which has different, camelCase flag names -
  # don't confuse the two). Defaults to 2 vcpu/4GB mem, $0.06/hr in EUR-IS-1.
  create_output="$(runpodctl pod create \
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
  trap 'runpodctl pod stop "'"$prewarm_pod_id"'" >/dev/null 2>&1 || true; runpodctl pod delete "'"$prewarm_pod_id"'" >/dev/null 2>&1 || true' RETURN

  # Confirmed live (2026-08-01): RunPod restarts a pod's container on ANY
  # exit, including a clean `exit 0` - polling for status to merely leave
  # "running" never works, since a pod that just finishes and exits gets
  # immediately relaunched by RunPod itself and looks "running" forever.
  # entrypoint.sh's PREWARM_ONLY branch now self-terminates via runpodctl
  # once it's done (needs $RUNPOD_API_KEY, passed above), so completion here
  # means the `pod get` call itself starts erroring (pod no longer exists) -
  # that's the real signal, not the status text. The still-running check
  # stays as a secondary signal in case self-termination didn't fire.
  #
  # BUT: "pod get errors / not running" also happens if the pod never
  # actually started (image pull failure, capacity/scheduling problem) and
  # RunPod cleans it up on its own - confirmed live 2026-08-01, a prewarm
  # pod vanished (404 on `pod get`) within ~20-30s, and this loop reported
  # "Prewarm finished" even though the volume had no toolchain or model on
  # it at all. gh/cloudflared/uv installs plus a multi-GB model download
  # cannot genuinely finish that fast, so MIN_PREWARM_SECONDS below is a
  # floor: disappearing before it elapses is treated as a failure, not
  # success, same as the max_wait timeout branch already does.
  log_info "Waiting for prewarm to finish (installs + model download can take a while on first run)..."
  local waited=0 max_wait=3600 min_wait=120 get_output
  while (( waited < max_wait )); do
    get_output="$(runpodctl pod get "$prewarm_pod_id" 2>&1)"
    { grep -qi '"error"' <<< "$get_output" || ! grep -qi running <<< "$get_output"; } && break
    sleep 15; waited=$((waited + 15))
  done

  if (( waited >= max_wait )); then
    log_warn "Prewarm pod still reports running after ${max_wait}s - stopping it now regardless. Toolchain/model may be incomplete; the GPU pod will finish the job itself if so, or rerun with --prewarm later."
    return
  fi

  if (( waited < min_wait )); then
    log_warn "Prewarm pod disappeared after only ${waited}s - too fast to be a genuine finish (installs + model download take much longer). Likely a scheduling/image-pull failure, not success. Not marking this volume as prewarmed; the GPU pod will do the install itself, or rerun with --prewarm after checking the console."
    return
  fi

  log_ok "Prewarm finished."
  sed -i '/^PREWARMED_VOLUME_ID=/d' "$CONFIG_FILE"
  printf 'PREWARMED_VOLUME_ID=%q\n' "$NETWORK_VOLUME_ID" >> "$CONFIG_FILE"
}

# --- pod creation ------------------------------------------------------------

create_pod() {
  local terminate_after
  # --terminate-after is a confirmed native runpodctl flag (absolute
  # ISO-8601 datetime) - a hard backstop that fires even if idle-watchdog.sh
  # itself has crashed or its SSH-session detection is misbehaving.
  terminate_after="$(date -u -d "+${MAX_RUNTIME_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"

  log_info ""
  log_info "Creating pod (GPU $GPU_ID, preset $MODEL_PRESET, auto-terminate at $terminate_after UTC)..."

  # --env deliberately carries ONLY these six names. No GitHub credential
  # goes here - see the comment above push_github_token() for why.
  local env_json
  env_json=$(printf '{"CLOUDFLARE_TUNNEL_TOKEN":"%s","GIT_USER_NAME":"%s","GIT_USER_EMAIL":"%s","MODEL_PRESET":"%s","FRONTEND":"%s","IDLE_MINUTES":"%s","RUNPOD_API_KEY":"%s"}' \
    "$CLOUDFLARE_TUNNEL_TOKEN" "$GIT_USER_NAME" "$GIT_USER_EMAIL" "$MODEL_PRESET" "$FRONTEND" "$IDLE_MINUTES" "$RUNPOD_API_KEY")

  local create_output
  create_output="$(runpodctl pod create \
    --cloud-type SECURE \
    --gpu-id "$GPU_ID" \
    --image "$IMAGE_NAME" \
    --network-volume-id "$NETWORK_VOLUME_ID" \
    --volume-mount-path /workspace/persistent \
    --container-disk-in-gb "$CONTAINER_DISK_GB" \
    --terminate-after "$terminate_after" \
    --name "runpod-lab-$(date +%s)" \
    --env "$env_json")" || die "Pod creation failed. Raw output:\n$create_output"

  # Picking specific fields (rather than printing $create_output raw) is
  # deliberate: the response's "env" array echoes back RUNPOD_API_KEY and
  # CLOUDFLARE_TUNNEL_TOKEN in plaintext, which has no business hitting the
  # terminal or a captured log.
  POD_ID="$(jq -r '.id // empty' <<< "$create_output")"
  [[ -n "$POD_ID" ]] || die "Pod created but no id found in the response: $create_output"

  log_ok "Pod created:"
  jq -r '"  ID:     \(.id)\n  Name:   \(.name)\n  GPU:    \(.machine.gpuDisplayName) x\(.gpuCount)\n  Cost:   $\(.costPerHr)/hr\n  Status: \(.desiredStatus)"' <<< "$create_output"
}

# --- wait for the pod to actually be reachable ------------------------------

wait_for_pod_ready() {
  log_info ""
  log_info "Waiting for pod $POD_ID to report running..."
  local waited=0 max_wait=600
  while (( waited < max_wait )); do
    if runpodctl pod get "$POD_ID" 2>/dev/null | grep -qi running; then
      break
    fi
    sleep 10; waited=$((waited + 10))
  done
  (( waited < max_wait )) || die "Pod didn't report running within ${max_wait}s. Check the console."
  log_ok "Pod reports running."

  # Pod status alone doesn't mean sshd + cloudflared are up yet inside it -
  # actually reaching it over SSH (through the tunnel alias from step 8) is
  # the real readiness signal, not just the API's status field.
  log_info "Waiting for SSH to come up through the tunnel..."
  waited=0
  while (( waited < max_wait )); do
    if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new runpod-lab true 2>/dev/null; then
      log_ok "SSH reachable."
      return
    fi
    sleep 10; waited=$((waited + 10))
  done
  die "SSH never came up through the tunnel within ${max_wait}s. Pod is running but onstart.sh/cloudflared may have failed - check manually: ssh runpod-lab"
}

# --- mint + push a GitHub App installation token ----------------------------

push_github_token() {
  # The App's long-lived private key never leaves this machine. Only a
  # short-lived (1 hour, per docs.github.com) installation token is minted
  # locally and pushed over SSH - so nothing durable ever sits in RunPod's
  # stored pod config, even though RunPod's own storage isn't a trust
  # boundary we control. --git-protocol https is required: installation
  # tokens authenticate git only over HTTPS
  # (git clone https://x-access-token:TOKEN@github.com/...), there's no SSH
  # equivalent for this token type.
  log_info ""
  log_info "Minting a GitHub App installation token and pushing it to the pod..."
  local b64_key token
  b64_key="$(base64 -w0 < "$GITHUB_APP_KEY_PATH")"
  token="$(gh token generate \
    --base64-key "$b64_key" \
    --app-id "$GITHUB_APP_ID" \
    --installation-id "$GITHUB_APP_INSTALLATION_ID" 2>&1)"
  if [[ -z "$token" ]]; then
    log_warn "Token generation failed - gh-token produced no output. GitHub auth on the pod will need to be done manually (ssh runpod-lab, then gh auth login)."
    return
  fi
  if ssh runpod-lab 'gh auth login --with-token --git-protocol https' <<< "$token"; then
    log_ok "GitHub token pushed - pod is authenticated."
  else
    log_warn "Pushing the token over SSH failed. GitHub auth on the pod will need to be done manually (ssh runpod-lab, then gh auth login)."
  fi
}

# --- entry point -------------------------------------------------------------

run_normal_launch() {
  ensure_network_volume
  pick_preset_and_gpu
  maybe_run_prewarm

  if [[ "${PREWARM_ONLY:-0}" == 1 ]]; then
    log_info ""
    log_ok "Prewarm-only run done - no GPU pod created. Launch normally when you're ready."
    return
  fi

  create_pod
  wait_for_pod_ready
  push_github_token

  log_info ""
  log_ok "Pod ready."
  log_info "Connect with: ssh runpod-lab"
  log_info "Frontend on port 3000 (via the tunnel): $FRONTEND"
  log_info "Pod ID: $POD_ID   Preset: $MODEL_PRESET   Idle limit: ${IDLE_MINUTES}m   Max runtime: ${MAX_RUNTIME_HOURS}h"
}
