# lib/launch.sh - normal pod launch (startup.sh section 1b), run every time
# except during the first-run setup wizard. Sourced by startup.sh.

CONTAINER_DISK_GB=25   # code + OS only; models live on the network volume.

# TODO(image): placeholder until the OpenHands + llama.cpp image (built by
# the paired prompt that runs *inside* the pod this script creates) exists.
# This is RunPod's official CUDA/PyTorch base image - it will boot and run
# onstart.sh fine, but has none of the OpenHands/llama.cpp stack baked in
# yet. Swap this for the real image name/tag (or a --template-id) once
# that build exists. NOT independently verified against the RunPod image
# registry this session - confirm the tag still exists before relying on it.
IMAGE_NAME="runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"

# --- preset + GPU selection -------------------------------------------------

pick_preset_and_gpu() {
  if [[ -f "$LAST_SESSION_FILE" && "$NEW_SESSION" != 1 ]]; then
    # shellcheck source=/dev/null
    source "$LAST_SESSION_FILE"
    [[ -n "${MODEL_PRESET:-}" && -n "${GPU_ID:-}" ]] && {
      log_info "Reusing last session: preset=$MODEL_PRESET gpu=$GPU_ID (pass --new to change)."
      return
    }
  fi

  log_info ""
  log_info "Model preset:"
  local -a preset_values=("qwen36-27b" "qwen3-coder-next")
  local -a preset_labels=(
    "qwen36-27b       - dense model, runs on any GPU tier including RTX 4090"
    "qwen3-coder-next - MoE model, needs 40GB+ VRAM (A6000 / L40S / A100 class)"
  )
  local preset_choice
  select_from_menu "Choose a preset" preset_choice "${preset_labels[@]}"
  MODEL_PRESET="${preset_values[$((preset_choice - 1))]}"

  log_info ""
  log_info "Fetching live GPU availability for datacenter $DATACENTER_ID..."
  local gpu_json
  gpu_json="$(runpodctl gpu list)" || die "Could not list GPUs - check https://www.runpod.io/console/gpu-cloud instead."

  local min_vram=0
  [[ "$MODEL_PRESET" == "qwen3-coder-next" ]] && min_vram=40

  # Field names (gpuId, displayName, memoryInGb, securePricePerHr,
  # dataCenterAvailability[].stockStatus) confirmed against live `runpodctl
  # gpu list` JSON output this session. Filtering to the target datacenter
  # and the preset's VRAM floor here means a bad pick is no longer possible,
  # instead of just being warned about.
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
  local gpu_choice
  select_from_menu "Choose a GPU" gpu_choice "${gpu_labels[@]}"
  GPU_ID="${gpu_ids[$((gpu_choice - 1))]}"

  mkdir -p "$CONFIG_DIR"
  ( umask 077
    cat > "$LAST_SESSION_FILE" <<EOF
MODEL_PRESET=$MODEL_PRESET
GPU_ID=$GPU_ID
EOF
  )
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

  # --env deliberately carries ONLY these five names. No GitHub credential
  # goes here - see the comment above push_github_token() for why.
  local env_json
  env_json=$(printf '{"CLOUDFLARE_TUNNEL_TOKEN":"%s","GIT_USER_NAME":"%s","GIT_USER_EMAIL":"%s","MODEL_PRESET":"%s","IDLE_MINUTES":"%s","RUNPOD_API_KEY":"%s"}' \
    "$CLOUDFLARE_TUNNEL_TOKEN" "$GIT_USER_NAME" "$GIT_USER_EMAIL" "$MODEL_PRESET" "$IDLE_MINUTES" "$RUNPOD_API_KEY")

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

  log_info "$create_output"
  # Pod-ID extraction from output isn't parsed here (format unconfirmed) -
  # instead we list pods and let the user confirm which one just came up,
  # since RUNPOD_POD_ID only becomes reliably knowable from *inside* the pod.
  echo
  runpodctl pod list || true
  read -r -p "Paste the pod ID shown above for the pod that was just created: " POD_ID
  [[ -n "$POD_ID" ]] || die "No pod ID entered."
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
  pick_preset_and_gpu
  create_pod
  wait_for_pod_ready
  push_github_token

  log_info ""
  log_ok "Pod ready."
  log_info "Connect with: ssh runpod-lab"
  log_info "Pod ID: $POD_ID   Preset: $MODEL_PRESET   Idle limit: ${IDLE_MINUTES}m   Max runtime: ${MAX_RUNTIME_HOURS}h"
}
