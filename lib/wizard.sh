# lib/wizard.sh - first-run setup wizard (startup.sh section 1a).
# Sourced by startup.sh; defines run_setup_wizard, called only when
# ~/.runpod-lab/config is missing or --setup was passed.
#
# Every external command name/flag below was checked against current
# vendor docs as of 2026-07-30 (docs.runpod.io, docs.github.com,
# cli.github.com, developers.cloudflare.com). Anywhere the exact output
# *format* of a command wasn't independently verified (vs. just its
# existence), this script shows the raw output and asks you to confirm
# or paste the value, rather than silently parsing something unverified.

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

install_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && { log_info "cloudflared: already present."; return; }
  # Confirmed URL pattern: developers.cloudflare.com/tunnel/downloads/
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -o "$HOME/.local/bin/cloudflared"
  chmod +x "$HOME/.local/bin/cloudflared"
  command -v cloudflared >/dev/null 2>&1 || die "cloudflared installed to ~/.local/bin but isn't on PATH. Add ~/.local/bin to PATH and re-run."
  log_ok "cloudflared: installed."
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

# --- step 3: generate/register a dedicated SSH keypair for pod access ------

# Deliberately its own keypair, not the user's personal/default identity key,
# and deliberately generated without a passphrase: the pods this repo creates
# are ephemeral (idle-watchdog.sh auto-terminates them, see IDLE_MINUTES) and
# SSH access to them is diagnostics-only, never how the endpoint itself is
# used - so a passphrase here buys little (there's nothing long-lived behind
# it worth protecting beyond what's already in $CONFIG_FILE, chmod 600 in the
# same directory) while actively breaking `ssh runpod-lab` in any
# non-interactive context (e2e test scripts, an agent session with no way to
# type a passphrase in) - the actual bug this rewrite fixes.
setup_ssh_key() {
  log_info ""
  log_info "== Step 3: SSH key for pod access =="
  SSH_KEY_PATH="$CONFIG_DIR/ssh_key"
  if [[ -f "$SSH_KEY_PATH" ]]; then
    log_info "Reusing existing dedicated keypair at $SSH_KEY_PATH."
  else
    ssh-keygen -t ed25519 -N "" -C "runpod-lab" -f "$SSH_KEY_PATH" >/dev/null \
      || die "ssh-keygen failed to generate $SSH_KEY_PATH."
    log_ok "Generated a new dedicated (no-passphrase) keypair at $SSH_KEY_PATH."
  fi
  chmod 600 "$SSH_KEY_PATH"
  # Confirmed subcommand: docs.runpod.io/runpodctl/reference/runpodctl-ssh
  runpodctl_t ssh add-key --key-file "$SSH_KEY_PATH.pub" || die "Failed to register $SSH_KEY_PATH.pub with your RunPod account (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s)."
  log_ok "Registered $SSH_KEY_PATH.pub with RunPod."
}

# --- step 4: datacenter choice ---------------------------------------------

setup_datacenter() {
  log_info ""
  log_info "== Step 4: Datacenter =="
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

# --- step 5: network volume -------------------------------------------------

setup_network_volume() {
  log_info ""
  log_info "== Step 5: Network volume (persistent model-weights storage) =="
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

# --- step 6: vLLM API key ---------------------------------------------------

# Gates the OpenAI-compatible endpoint with a bearer token (vLLM's own
# --api-key flag - see image/entrypoint.sh). Generated locally, never sent
# anywhere but into the pod's --env at launch time, same trust model as the
# other secrets in this file. Deliberately NOT put behind Cloudflare Access
# the way the SSH hostname is: most OpenAI-compatible client tools (the
# openai SDK, Continue, Aider, etc.) can set a bearer token but have no way
# to add Access's custom CF-Access-Client-Id/Secret headers, so Access would
# make the endpoint unusable from them rather than just gating it.
setup_vllm_api_key() {
  log_info ""
  log_info "== Step 6: OpenAI-endpoint API key =="
  log_info "This gates the vLLM endpoint itself (Authorization: Bearer <key>) - it's" \
           "what your OpenAI-compatible client tools authenticate with, since the" \
           "endpoint's Public Hostname (next step) is intentionally not behind" \
           "Cloudflare Access."
  local reply
  prompt_text "Paste your own key, or leave blank to generate a random one ($TEXT_BACK_WORD to go back): " reply || return 1
  if [[ -z "$reply" ]]; then
    reply="$(openssl rand -hex 32)"
    log_info "Generated a random key (will be shown once more in the final config summary)."
  fi
  VLLM_API_KEY="$reply"
  log_ok "vLLM API key set."
}

# --- step 7: Cloudflare Tunnel ----------------------------------------------

setup_cloudflare_tunnel() {
  log_info ""
  log_info "== Step 7: Cloudflare Tunnel (cannot be automated - one-time manual step) =="
  log_info "1. In the Cloudflare dashboard, pick the account/zone that has your domain,"
  log_info "   then go to Networking > Tunnels > Create a tunnel."
  log_info "2. Choose 'Cloudflared' as the connector type, then give the tunnel a name"
  log_info "   (e.g. 'runpod-lab') and click Save tunnel. This is a *named* tunnel with"
  log_info "   its own credentials/token - not the quick/trycloudflare kind that expires"
  log_info "   when the process exits."
  log_info "3. Cloudflare shows an install/run command containing the tunnel token (the"
  log_info "   long eyJ... string after '--token'). Copy that whole token now - you'll"
  log_info "   paste it below. You can also find it later on the tunnel's Overview page"
  log_info "   under 'Install and run a connector' if you lose it."
  log_info "4. Click 'Next' to reach the Public Hostname step (or open the tunnel later"
  log_info "   and go to its 'Public Hostname' tab) and add a route for SSH:"
  log_info "     Subdomain: whatever you want, e.g. 'pod-ssh'"
  log_info "     Domain:    the domain you added to this Cloudflare account"
  log_info "     Path:      leave blank"
  log_info "     Type:      SSH"
  log_info "     URL:       localhost:22"
  log_info "5. Add a second Public Hostname on the same tunnel for the OpenAI-compatible"
  log_info "   API (fixed at port 8000 - that's vLLM's own documented default, not"
  log_info "   configurable per launch the way the old frontend port was):"
  log_info "     Subdomain: whatever you want, e.g. 'pod-api'"
  log_info "     Domain:    same domain as above"
  log_info "     Type:      HTTP"
  log_info "     URL:       localhost:8000"
  log_info "6. Lock the SSH hostname down with Cloudflare Access so only you can reach"
  log_info "   it (RunPod pods are otherwise open to anyone who guesses the URL). The"
  log_info "   API hostname is deliberately left OUT of this Access application - it's"
  log_info "   gated by vLLM's own --api-key bearer token instead (Step 6 above),"
  log_info "   since most OpenAI-compatible client tools can send a bearer token but"
  log_info "   can't add Access's custom CF-Access-Client-Id/Secret headers:"
  log_info "     a. Go to Zero Trust > Access > Applications > Add an application. On"
  log_info "        the type-picker modal, stay on the 'Self-hosted and private' tab"
  log_info "        (ignore the Private destinations/Workers/Public DNS/Service auth"
  log_info "        sub-tabs shown as examples) and click 'Continue with Self-hosted"
  log_info "        and private'."
  log_info "     b. On the Destinations section: under 'Public hostnames', enter the"
  log_info "        SSH subdomain from step 4, with your domain already selected and"
  log_info "        Path left blank. Do NOT add the API subdomain here."
  log_info "     c. Add a policy (e.g. name it 'me-only', action Allow) with an Include"
  log_info "        rule of type Emails, listing your own GitHub/Cloudflare email."
  log_info "     d. Save."
  log_info "   Without this, localhost:22 is reachable by anyone who finds the SSH"
  log_info "   hostname. The API hostname is intentionally reachable by anyone who"
  log_info "   finds it AND has the API key - if that's not an acceptable tradeoff for"
  log_info "   you, add a second Access application covering it too and expect to lose"
  log_info "   compatibility with OpenAI-client tools that can't add Access headers."
  log_info "7. Sanity check: on the tunnel's 'Routes' tab, the SSH hostname should be"
  log_info "   listed with a 'Published application' badge next to it - that badge is"
  log_info "   what confirms the Access policy from step 6 actually attached. The API"
  log_info "   hostname should NOT have that badge (by design, per step 6)."
  log_info ""
  read -r -p "Press Enter once the tunnel, both hostnames, and the SSH Access policy exist... "

  # Nothing here creates or commits anything server-side (the tunnel/
  # hostnames/policy were already made manually above), so all three fields
  # navigate locally and backing out of ssh_hostname (the first) exits the step.
  local field="ssh_hostname"
  while true; do
    case "$field" in
      ssh_hostname)
        prompt_text "SSH hostname (e.g. pod-ssh.yourdomain.com) ($TEXT_BACK_WORD to go back): " CLOUDFLARE_SSH_HOSTNAME || return 1
        [[ -n "$CLOUDFLARE_SSH_HOSTNAME" ]] || die "No SSH hostname entered."
        field="api_hostname"
        ;;
      api_hostname)
        prompt_text "API hostname (e.g. pod-api.yourdomain.com) ($TEXT_BACK_WORD for SSH hostname): " CLOUDFLARE_API_HOSTNAME || { field="ssh_hostname"; continue; }
        [[ -n "$CLOUDFLARE_API_HOSTNAME" ]] || die "No API hostname entered."
        field="token"
        ;;
      token)
        prompt_text "Paste the tunnel token, or the whole install/run command Cloudflare showed ($TEXT_BACK_WORD for API hostname): " CLOUDFLARE_TUNNEL_TOKEN -s || { field="api_hostname"; continue; }
        CLOUDFLARE_TUNNEL_TOKEN="$(extract_cloudflare_token "$CLOUDFLARE_TUNNEL_TOKEN")"
        [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]] || die "No tunnel token found in what was pasted."
        validate_cloudflare_tunnel_token
        break
        ;;
    esac
  done
  log_ok "Cloudflare Tunnel configured."
}

# --- step 8: local SSH config ----------------------------------------------

setup_ssh_config() {
  log_info ""
  log_info "== Step 8: local SSH config =="
  local ssh_config="$HOME/.ssh/config"
  local marker_begin="# >>> runpod-lab (managed) >>>"
  local marker_end="# <<< runpod-lab (managed) <<<"
  # Remove any previous managed block first so re-running --setup doesn't
  # duplicate entries.
  if [[ -f "$ssh_config" ]] && grep -qF "$marker_begin" "$ssh_config"; then
    sed -i "/$marker_begin/,/$marker_end/d" "$ssh_config"
  fi
  {
    echo "$marker_begin"
    echo "Host runpod-lab"
    echo "  HostName $CLOUDFLARE_SSH_HOSTNAME"
    echo "  User root"
    echo "  IdentityFile $SSH_KEY_PATH"
    # Confirmed syntax: developers.cloudflare.com .../ssh-cloudflared-authentication/
    echo "  ProxyCommand cloudflared access ssh --hostname %h"
    echo "$marker_end"
  } >> "$ssh_config"
  chmod 600 "$ssh_config"
  log_ok "Wrote 'Host runpod-lab' to ~/.ssh/config (ssh/scp/rsync all work against that alias from now on)."
}

# --- step 9: write config --------------------------------------------------

write_config() {
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  # RUNPOD_API_KEY/VLLM_API_KEY/CLOUDFLARE_TUNNEL_TOKEN deliberately NOT
  # written here - see load_secrets() (lib/common.sh) for why they go in the
  # OS keyring instead. Written with a restrictive umask for the duration of
  # this call so the file is never briefly world-readable between creation
  # and chmod, and %q-quoted so a value containing spaces or shell
  # metacharacters can't break `source "$CONFIG_FILE"` later.
  ( umask 077
    printf 'SSH_KEY_PATH=%q\n' "$SSH_KEY_PATH" > "$CONFIG_FILE"
    printf 'DATACENTER_ID=%q\n' "$DATACENTER_ID" >> "$CONFIG_FILE"
    printf 'NETWORK_VOLUME_ID=%q\n' "$NETWORK_VOLUME_ID" >> "$CONFIG_FILE"
    printf 'CLOUDFLARE_SSH_HOSTNAME=%q\n' "$CLOUDFLARE_SSH_HOSTNAME" >> "$CONFIG_FILE"
    printf 'CLOUDFLARE_API_HOSTNAME=%q\n' "$CLOUDFLARE_API_HOSTNAME" >> "$CONFIG_FILE"
  )
  chmod 600 "$CONFIG_FILE"

  secret_store runpod_api_key "$RUNPOD_API_KEY"
  secret_store vllm_api_key "$VLLM_API_KEY"
  secret_store cloudflare_tunnel_token "$CLOUDFLARE_TUNNEL_TOKEN"

  # Confirm by presence/length only - never echo the values themselves.
  log_ok "Saved config to $CONFIG_FILE ($(wc -l < "$CONFIG_FILE") lines, mode $(stat -c %a "$CONFIG_FILE")); RunPod/vLLM/Cloudflare secrets stored in the OS keyring, not the file."
}

# --- --rotate: quick credential refresh --------------------------------------

# Re-prompts for just the credentials that actually expire/rotate outside
# this repo (RunPod API key, Cloudflare tunnel token) or that you might want
# to roll on suspicion of compromise (the dedicated SSH keypair), instead of
# re-running the whole wizard. The vLLM API key doesn't expire (it's
# generated by us, not issued externally), so it isn't part of this - edit
# VLLM_API_KEY in $CONFIG_FILE by hand, or re-run --setup, if you want to
# change it.
# Requires the rest of the config to already be sourced by the caller.
rotate_credentials() {
  log_info "Rotating credentials in $CONFIG_FILE. Leave a prompt blank to keep the current value."

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

  log_info ""
  log_info "== Cloudflare tunnel token =="
  log_info "Find it on the tunnel's Overview page (Cloudflare dashboard) under 'Install and run a connector'."
  local new_tunnel_token
  prompt_text "Paste a new tunnel token, or the whole install/run command (blank to keep the current one): " new_tunnel_token -s
  if [[ -n "$new_tunnel_token" ]]; then
    CLOUDFLARE_TUNNEL_TOKEN="$(extract_cloudflare_token "$new_tunnel_token")"
    [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]] || die "No tunnel token found in what was pasted."
    validate_cloudflare_tunnel_token
  fi

  log_info ""
  log_info "== Dedicated SSH keypair =="
  log_info "Regenerating replaces $SSH_KEY_PATH and registers the new public key with" \
           "RunPod. 'runpodctl ssh add-key' adds a key rather than replacing the old" \
           "one (confirmed via docs.runpod.io/runpodctl/reference/runpodctl-ssh), so" \
           "the old key is explicitly removed from your account below via its" \
           "fingerprint ('remove-key --name' would be ambiguous once two keys share" \
           "the 'runpod-lab' comment)."
  log_info "Any pod already running was provisioned with the OLD public key baked" \
           "into its authorized_keys at boot and will NOT pick up the new one - SSH" \
           "to it (diagnostics only, see PREREQUISITES.md) stops working until that" \
           "pod is recreated. Safe to do any time; just recreate the pod before you" \
           "next need SSH into it."
  if confirm "Regenerate the dedicated SSH keypair?"; then
    local old_fingerprint=""
    if [[ -f "$SSH_KEY_PATH.pub" ]]; then
      old_fingerprint="$(ssh-keygen -lf "$SSH_KEY_PATH.pub" | awk '{print $2}')"
    fi
    rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    ssh-keygen -t ed25519 -N "" -C "runpod-lab" -f "$SSH_KEY_PATH" >/dev/null \
      || die "ssh-keygen failed to generate $SSH_KEY_PATH."
    chmod 600 "$SSH_KEY_PATH"
    log_ok "Generated a new dedicated (no-passphrase) keypair at $SSH_KEY_PATH."
    runpodctl_t ssh add-key --key-file "$SSH_KEY_PATH.pub" \
      || die "Failed to register the new $SSH_KEY_PATH.pub with your RunPod account (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s)."
    log_ok "Registered the new public key with RunPod."
    if [[ -n "$old_fingerprint" ]]; then
      if runpodctl_t ssh remove-key --fingerprint "$old_fingerprint" >/dev/null 2>&1; then
        log_ok "Removed the old key ($old_fingerprint) from your RunPod account."
      else
        log_warn "Could not remove the old key ($old_fingerprint) from your RunPod account automatically - remove it by hand at https://www.runpod.io/console/user/settings if you want it fully revoked."
      fi
    fi
  fi

  write_config
}

# --- entry point -------------------------------------------------------------

run_setup_wizard() {
  log_info "No config found (or --setup was passed) - running the one-time setup wizard."
  log_info "runpod-lab build $RUNPOD_LAB_BUILD"
  mkdir -p "$HOME/.local/bin"
  # Created here (not just in write_config, the last step) because
  # setup_ssh_key - step 3, below - needs it to exist first to write the
  # dedicated keypair into.
  mkdir -p "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) log_warn "~/.local/bin isn't on PATH yet - add it to your shell profile, or tools installed this run won't be found until you do." ;;
  esac

  log_info ""
  log_info "== Step 1: local tools =="
  install_runpodctl
  install_cloudflared
  command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH - needed to generate the vLLM API key (setup_vllm_api_key). Install it via your distro's package manager; this repo doesn't auto-install it (it's a near-universal base-system tool, unlike the release binaries above)."
  command -v secret-tool >/dev/null 2>&1 || die "secret-tool not found on PATH - needed to store credentials in the OS keyring instead of a plaintext file (see load_secrets() in lib/common.sh). Install it via your distro's package manager (libsecret-tools on Debian/Ubuntu, libsecret on Fedora/Arch) and make sure a Secret Service (GNOME Keyring or KWallet) is running and unlocked in this session, then re-run."

  # Steps 2-8 run as a back-able sequence: any step can return 1 (e.g. the
  # user typed the safeword on its first prompt) to hand control to the
  # step before it, instead of the whole wizard only being restartable from
  # scratch. setup_ssh_key and setup_ssh_config have no prompts of their own
  # (they just re-run their side effects) but stay in the list so stepping
  # back past setup_datacenter lands somewhere sensible.
  local -a wizard_steps=(
    setup_runpod_api_key
    setup_ssh_key
    setup_datacenter
    setup_network_volume
    setup_vllm_api_key
    setup_cloudflare_tunnel
    setup_ssh_config
  )
  run_step_sequence wizard_steps
  write_config

  log_info ""
  log_ok "Setup complete. Run ./startup.sh again (without --setup) to launch a pod."
  log_info "Your OpenAI-compatible endpoint will be: https://$CLOUDFLARE_API_HOSTNAME/v1"
  log_info "API key (Authorization: Bearer <key> - shown once, not stored anywhere but $CONFIG_FILE): $VLLM_API_KEY"
  log_info "PREREQUISITES.md in this repo documents everything this wizard just asked for - if that list and this wizard ever disagree, the wizard wins and the doc needs an update."
}
