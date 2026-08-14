# lib/wizard.sh - first-run setup wizard (startup.sh section 1a).
# Sourced by startup.sh; defines run_setup_wizard, called only when
# ~/.runpod-lab/config is missing or --setup was passed.
#
# Every external command name/flag below was checked against current
# vendor docs (docs.runpod.io, docs.github.com, cli.github.com). Anywhere
# the exact output *format* of a command wasn't independently verified (vs.
# just its existence), this script shows the raw output and asks you to
# confirm or paste the value, rather than silently parsing something
# unverified.

# --- step 1: install local tools into ~/.local/bin ------------------------

# Downloads whichever release asset matches a regex from a repo's *latest*
# GitHub release, without hardcoding an exact filename/version - GitHub's
# release asset naming has changed for some of these tools before, and
# pinning a filename we haven't independently confirmed this session would
# violate the "don't hardcode what you haven't confirmed" rule. Requires no
# auth (public repos, unauthenticated API rate limit is enough for this).
github_release_asset_url() {
  local repo="$1" pattern="$2"
  local api_json
  api_json="$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest")" \
    || die "Could not reach GitHub API to find a release for $repo."
  # Pull every browser_download_url line, then keep the one matching pattern.
  printf '%s\n' "$api_json" \
    | grep -o '"browser_download_url": *"[^"]*"' \
    | sed -E 's/.*"(https[^"]+)"/\1/' \
    | grep -E "$pattern" \
    | head -n1
}

install_runpodctl() {
  command -v runpodctl >/dev/null 2>&1 && { log_info "runpodctl: already present."; return; }
  local url
  url="$(github_release_asset_url "runpod/runpodctl" 'linux.*amd64|amd64.*linux')"
  [[ -n "$url" ]] || die "Could not find a linux/amd64 runpodctl release asset. Check https://github.com/runpod/runpodctl/releases manually."
  curl -fsSL "$url" -o "$HOME/.local/bin/runpodctl"
  chmod +x "$HOME/.local/bin/runpodctl"
  command -v runpodctl >/dev/null 2>&1 || die "runpodctl installed to ~/.local/bin but isn't on PATH. Add ~/.local/bin to PATH and re-run."
  log_ok "runpodctl: installed."
}

# --- step 2: RunPod API key ------------------------------------------------

setup_runpod_api_key() {
  log_info ""
  log_info "== Step 2: RunPod API key =="
  log_info "Generate one at https://www.runpod.io/console/user/settings (Settings > API Keys) if you haven't already."
  local api_key
  prompt_text "Paste your RunPod API key ($TEXT_BACK_WORD to go back): " api_key -s || return 1
  [[ -n "$api_key" ]] || die "No API key entered."
  # `runpodctl config --apiKey` is deprecated in current releases and fails
  # outright (tries to write .runpod.yaml before the directory/file exist).
  # The CLI's own --help now points at exporting RUNPOD_API_KEY instead, so
  # we do that and let every later runpodctl call in this script pick it up.
  export RUNPOD_API_KEY="$api_key"
  validate_runpod_api_key
  log_ok "RunPod API key validated."
}

# --- step 3: datacenter choice ---------------------------------------------

setup_datacenter() {
  log_info ""
  log_info "== Step 3: Datacenter =="
  log_info "The network volume you're about to create is locked to whichever"
  log_info "datacenter you pick here, which in turn limits which GPUs you can"
  log_info "use later (not every datacenter stocks every card)."
  log_info ""
  log_info "Fetching current datacenter / GPU availability..."
  local dc_json
  dc_json="$(runpodctl_t datacenter list)" || die "Could not list datacenters (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s) - check availability at https://www.runpod.io/console/gpu-cloud instead."

  # Field names (id, location, gpuAvailability[].displayName/.stockStatus)
  # confirmed against live `runpodctl datacenter list` JSON output this
  # session.
  local menu_rows
  menu_rows="$(jq -r '
    .[]
    | [.id, .location, ([.gpuAvailability[]? | select(.stockStatus != "" and .stockStatus != "none") | .displayName] | join(", "))]
    | @tsv
  ' <<< "$dc_json")"

  [[ -n "$menu_rows" ]] || die "No datacenter data returned - check https://www.runpod.io/console/gpu-cloud instead."

  local -a dc_ids=() dc_labels=()
  while IFS=$'\t' read -r id location gpus; do
    dc_ids+=("$id")
    dc_labels+=("$(printf '%-10s %-15s %s' "$id" "$location" "${gpus:-no stock}")")
  done <<< "$menu_rows"

  log_info ""
  local dc_choice
  select_from_menu "Choose a datacenter" dc_choice "${dc_labels[@]}" || return 1
  DATACENTER_ID="${dc_ids[$((dc_choice - 1))]}"
}

# --- step 4: network volume -------------------------------------------------

setup_network_volume() {
  log_info ""
  log_info "== Step 4: Network volume (persistent model-weights storage) =="
  log_info "Sizing guide: 60GB for 4-bit weights, 100GB for 8-bit or a" \
           "single fp16 model, 150-200GB to keep both presets or an fp16 +" \
           "quantized copy side by side. See PREREQUISITES.md for the table."

  # The two fields before the (billed, non-undoable) create call get
  # back-out: name/size navigate between each other locally, and backing out
  # of name (the first field) hands control to the previous wizard step.
  # There's no back-out after that - the volume already exists by then, so
  # "going back" wouldn't undo anything real.
  local vol_name vol_size field="name"
  while true; do
    case "$field" in
      name)
        prompt_text "Volume name ($TEXT_BACK_WORD to go back): " vol_name || return 1
        field="size"
        ;;
      size)
        prompt_text "Volume size in GB ($TEXT_BACK_WORD for volume name): " vol_size || { field="name"; continue; }
        [[ -n "$vol_name" && "$vol_size" =~ ^[0-9]+$ ]] || die "Need a name and a numeric size in GB."
        break
        ;;
    esac
  done

  log_info "Creating volume (this is a billed resource for as long as it exists," \
           "independent of whether a pod is attached - see README for the rate)."
  create_network_volume "$vol_name" "$vol_size"
}

# --- step 5: write config --------------------------------------------------

write_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  # RUNPOD_API_KEY deliberately NOT written here - see load_secrets()
  # (lib/common.sh) for why it goes in the OS keyring instead. Written with
  # a restrictive umask for the duration of this call so the file is never
  # briefly world-readable between creation and chmod, and %q-quoted so a
  # value containing spaces or shell metacharacters can't break
  # `source "$CONFIG_FILE"` later.
  ( umask 077
    printf 'DATACENTER_ID=%q\n' "$DATACENTER_ID" > "$CONFIG_FILE"
    printf 'NETWORK_VOLUME_ID=%q\n' "$NETWORK_VOLUME_ID" >> "$CONFIG_FILE"
  )
  chmod 600 "$CONFIG_FILE"

  secret_store runpod_api_key "$RUNPOD_API_KEY"

  # Confirm by presence/length only - never echo the value itself.
  log_ok "Saved config to $CONFIG_FILE ($(wc -l < "$CONFIG_FILE") lines, mode $(stat -c %a "$CONFIG_FILE")); RunPod API key stored in the OS keyring, not the file."
}

# --- --rotate: quick credential refresh --------------------------------------

# Re-prompts for the RunPod API key - the only credential left that expires/
# rotates outside this repo. The vLLM API key and the pod's SSH keypair are
# both generated fresh per launch now (see setup_ephemeral_ssh_key() in
# lib/common.sh and create_pod() in lib/launch.sh), so there's nothing
# long-lived left to roll for either of them.
# Requires the rest of the config to already be sourced by the caller.
rotate_credentials() {
  log_info "Rotating credentials in $CONFIG_FILE. Leave the prompt blank to keep the current value."

  log_info ""
  log_info "== RunPod API key =="
  log_info "Generate one at https://www.runpod.io/console/user/settings (Settings > API Keys) if you need a new one."
  local new_api_key
  prompt_text "Paste a new RunPod API key (blank to keep the current one): " new_api_key -s
  if [[ -n "$new_api_key" ]]; then
    export RUNPOD_API_KEY="$new_api_key"
    validate_runpod_api_key
    log_ok "RunPod API key validated."
  fi

  write_config
}

# --- entry point -------------------------------------------------------------

run_setup_wizard() {
  log_info "No config found (or --setup was passed) - running the one-time setup wizard."
  log_info "runpod-lab build $RUNPOD_LAB_BUILD"
  mkdir -p "$HOME/.local/bin"
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) log_warn "~/.local/bin isn't on PATH yet - add it to your shell profile, or tools installed this run won't be found until you do." ;;
  esac

  log_info ""
  log_info "== Step 1: local tools =="
  install_runpodctl
  command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH - needed to generate a fresh vLLM API key on every launch (see create_pod() in lib/launch.sh). Install it via your distro's package manager; this repo doesn't auto-install it (it's a near-universal base-system tool, unlike the release binary above)."
  command -v secret-tool >/dev/null 2>&1 || die "secret-tool not found on PATH - needed to store the RunPod API key in the OS keyring instead of a plaintext file (see load_secrets() in lib/common.sh). Install it via your distro's package manager (libsecret-tools on Debian/Ubuntu, libsecret on Fedora/Arch) and make sure a Secret Service (GNOME Keyring or KWallet) is running and unlocked in this session, then re-run."

  # Steps 2-4 run as a back-able sequence: any step can return 1 (e.g. the
  # user typed the safeword on its first prompt) to hand control to the
  # step before it, instead of the whole wizard only being restartable from
  # scratch.
  local -a wizard_steps=(
    setup_runpod_api_key
    setup_datacenter
    setup_network_volume
  )
  run_step_sequence wizard_steps
  write_config

  log_info ""
  log_ok "Setup complete. Run ./startup.sh again (without --setup) to launch a pod."
  log_info "Every launch now generates its own one-off SSH key and vLLM API key and prints them at the end - nothing else to configure."
  log_info "PREREQUISITES.md in this repo documents everything this wizard just asked for - if that list and this wizard ever disagree, the wizard wins and the doc needs an update."
}
