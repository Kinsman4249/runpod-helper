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
  log_info "  1) qwen36-27b       - dense model, runs on any GPU tier including RTX 4090"
  log_info "  2) qwen3-coder-next - MoE model, needs 40GB+ VRAM (A6000 / L40S / A100 class)"
  local choice
  read -r -p "Choose 1 or 2: " choice
  case "$choice" in
    1) MODEL_PRESET="qwen36-27b" ;;
    2) MODEL_PRESET="qwen3-coder-next" ;;
    *) die "Enter 1 or 2." ;;
  esac

  log_info ""
  log_info "Live GPU availability and on-demand rates for datacenter $DATACENTER_ID:"
  # Shown raw (exact column/field names for VRAM size weren't independently
  # confirmed this session) so you can apply the preset's VRAM requirement
  # yourself rather than trusting an unverified automated filter.
  runpodctl gpu list || log_warn "Could not list GPUs - check https://www.runpod.io/console/gpu-cloud instead."
  if [[ "$MODEL_PRESET" == "qwen3-coder-next" ]]; then
    log_warn "qwen3-coder-next needs 40GB+ VRAM - do not pick an RTX 4090 (24GB) from the list above."
  fi
  echo
  read -r -p "Enter the GPU ID to use: " GPU_ID
  [[ -n "$GPU_ID" ]] || die "No GPU ID entered."

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
