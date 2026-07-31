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

install_gh() {
  command -v gh >/dev/null 2>&1 && { log_info "gh: already present."; return; }
  local url tmp_dir extracted_bin
  url="$(github_release_asset_url "cli/cli" 'linux_amd64\.tar\.gz$')"
  [[ -n "$url" ]] || die "Could not find a linux_amd64 gh release asset. Check https://github.com/cli/cli/releases manually."
  tmp_dir="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp_dir/gh.tar.gz"
  tar -xzf "$tmp_dir/gh.tar.gz" -C "$tmp_dir"
  # Don't assume the internal path (e.g. "gh_X.Y.Z_linux_amd64/bin/gh") -
  # that layout wasn't independently confirmed this session. Find it instead.
  extracted_bin="$(find "$tmp_dir" -type f -name gh -perm -u+x | head -n1)"
  [[ -n "$extracted_bin" ]] || die "Downloaded gh release but couldn't find the 'gh' binary inside it. Check $tmp_dir manually."
  cp "$extracted_bin" "$HOME/.local/bin/gh"
  chmod +x "$HOME/.local/bin/gh"
  rm -rf "$tmp_dir"
  command -v gh >/dev/null 2>&1 || die "gh installed to ~/.local/bin but isn't on PATH. Add ~/.local/bin to PATH and re-run."
  log_ok "gh: installed."
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

install_gh_token_extension() {
  require_cmd gh
  if gh extension list 2>/dev/null | grep -q 'Link-/gh-token'; then
    log_info "gh-token extension: already present."
    return
  fi
  gh extension install Link-/gh-token || die "Failed to install the gh-token extension (Link-/gh-token). gh may need 'gh auth login' first - that happens in step 6 below."
  log_ok "gh-token extension: installed."
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
  # Live validation call - confirmed to exist (runpodctl user / alias me),
  # exact output shape wasn't independently confirmed, so we only check
  # exit status here, not parse the output.
  if ! runpodctl user >/dev/null 2>&1; then
    die "RUNPOD_API_KEY set but a live call (runpodctl user) failed. Double check the key is valid and active."
  fi
  log_ok "RunPod API key validated."
}

# --- step 3: register local SSH public key --------------------------------

setup_ssh_key() {
  log_info ""
  log_info "== Step 3: SSH public key =="
  local pub_key=""
  for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    [[ -f "$candidate" ]] && { pub_key="$candidate"; break; }
  done
  if [[ -z "$pub_key" ]]; then
    die "No SSH keypair found (~/.ssh/id_ed25519.pub or id_rsa.pub). Run 'ssh-keygen -t ed25519' yourself and re-run startup.sh --setup. This script will not generate a keypair for you."
  fi
  SSH_KEY_PATH="${pub_key%.pub}"
  # Confirmed subcommand: docs.runpod.io/runpodctl/reference/runpodctl-ssh
  runpodctl ssh add-key --key-file "$pub_key" || die "Failed to register $pub_key with your RunPod account."
  log_ok "Registered $pub_key with RunPod."
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
  dc_json="$(runpodctl datacenter list)" || die "Could not list datacenters - check availability at https://www.runpod.io/console/gpu-cloud instead."

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

  # Only the two fields *before* the (billed, non-undoable) create call get
  # back-out: name/size navigate between each other locally, and backing out
  # of name (the first field) hands control to the previous wizard step. The
  # ID paste after creation stays a plain read - the volume already exists
  # by then, so "going back" wouldn't undo anything real.
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
  runpodctl network-volume create --name "$vol_name" --size "$vol_size" --data-center-id "$DATACENTER_ID" \
    || die "Volume creation failed."
  echo
  read -r -p "Paste the network volume ID shown above: " NETWORK_VOLUME_ID
  [[ -n "$NETWORK_VOLUME_ID" ]] || die "No volume ID entered."
}

# --- step 6: GitHub App -----------------------------------------------------

setup_github_app() {
  log_info ""
  log_info "== Step 6: GitHub App (cannot be automated - one-time manual step) =="
  log_info "1. Go to: https://github.com/settings/apps/new"
  log_info "   (or https://github.com/organizations/YOUR_ORG/settings/apps/new for an org)"
  log_info "2. Leave Callback URL blank - this app never does user OAuth login."
  log_info "3. Under Webhook, uncheck 'Active' - nothing listens for events, so Webhook URL/Secret can stay empty."
  log_info "4. Under Repository permissions, set:"
  log_info "     Contents      -> Read and write"
  log_info "     Pull requests -> Read and write"
  log_info "   Leave Organization permissions and Account permissions untouched."
  log_info "5. Under 'Where can this GitHub App be installed?', choose 'Only on this account'."
  log_info "6. Create the App, then generate and download a private key (.pem) from the App's settings page."
  log_info "7. Install the App (top of the App's settings page: 'Install App') on only the specific repos this box should touch."
  log_info ""
  read -r -p "Press Enter once the App is created, its key downloaded, and it's installed on the right repos... "

  # app_id/key_path/installation_id all navigate locally (no billed or
  # otherwise irreversible resource gets created here - 'gh token
  # installations' is a read-only lookup, safe to re-run). Backing out of
  # app_id, the first field, hands control to the previous wizard step.
  local app_id key_path installation_id field="app_id"
  while true; do
    case "$field" in
      app_id)
        prompt_text "GitHub App ID ($TEXT_BACK_WORD to go back): " app_id || return 1
        [[ "$app_id" =~ ^[0-9]+$ ]] || die "App ID should be numeric."
        field="key_path"
        ;;
      key_path)
        prompt_text "Path to the downloaded private key (.pem) ($TEXT_BACK_WORD for App ID): " key_path || { field="app_id"; continue; }
        key_path="${key_path/#\~/$HOME}"
        [[ -r "$key_path" ]] || die "Can't read '$key_path'."

        install_gh_token_extension
        log_info "Looking up installations for this App (no JWT hand-rolling needed -" \
                 "gh-token's 'installations' subcommand signs the JWT itself)..."
        log_info "Check the 'repository_selection' field in the output below: if it says" \
                 "'all' instead of 'selected', the App got installed on every repo instead" \
                 "of just the ones this box should touch. Fix it at" \
                 "https://github.com/settings/installations/<id> (Repository access ->" \
                 "Only select repositories) before continuing."
        gh token installations --key "$key_path" --app-id "$app_id" || die "gh-token couldn't list installations - check the App ID and key path."
        echo
        field="installation_id"
        ;;
      installation_id)
        prompt_text "Paste the installation ID matching where you installed the App above ($TEXT_BACK_WORD for key path): " installation_id || { field="key_path"; continue; }
        [[ "$installation_id" =~ ^[0-9]+$ ]] || die "Installation ID should be numeric."
        break
        ;;
    esac
  done

  GITHUB_APP_ID="$app_id"
  GITHUB_APP_KEY_PATH="$key_path"
  GITHUB_APP_INSTALLATION_ID="$installation_id"
  log_ok "GitHub App configured."
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
  log_info "5. Add a second Public Hostname on the same tunnel for the OpenHands UI:"
  log_info "     Subdomain: whatever you want, e.g. 'pod-ui'"
  log_info "     Domain:    same domain as above"
  log_info "     Type:      HTTP"
  log_info "     URL:       localhost:<OpenHands port> (default OpenHands port is 3000,"
  log_info "                unconfirmed until the paired OpenHands image is finalized -"
  log_info "                check that image's docs/config before relying on 3000)."
  log_info "6. Lock both hostnames down with Cloudflare Access so only you can reach"
  log_info "   them (RunPod pods are otherwise open to anyone who guesses the URL):"
  log_info "     a. Go to Zero Trust > Access > Applications > Add an application. On"
  log_info "        the type-picker modal, stay on the 'Self-hosted and private' tab"
  log_info "        (ignore the Private destinations/Workers/Public DNS/Service auth"
  log_info "        sub-tabs shown as examples) and click 'Continue with Self-hosted"
  log_info "        and private'."
  log_info "     b. On the Destinations section: under 'Public hostnames', enter the"
  log_info "        SSH subdomain from step 4 (Subdomain field) with your domain"
  log_info "        already selected, Path left blank. Click '+ Add public hostname'"
  log_info "        and add a second entry with the OpenHands subdomain from step 5."
  log_info "        (One app supports up to 5 destinations, so both hostnames can"
  log_info "        share this single Access application.) Ignore the 'Workers'"
  log_info "        section - that's unrelated to this tunnel."
  log_info "     c. Add a policy (e.g. name it 'me-only', action Allow) with an Include"
  log_info "        rule of type Emails, listing your own GitHub/Cloudflare email."
  log_info "     d. Save."
  log_info "   Without this, anything listening on localhost:22 or the OpenHands port"
  log_info "   is reachable by anyone on the internet who finds the hostname."
  log_info "7. Sanity check: on the tunnel's 'Routes' tab, both hostnames should be"
  log_info "   listed with a 'Published application' badge next to them - that badge is"
  log_info "   what confirms the Access policy from step 6 is actually attached. If a"
  log_info "   hostname is missing that badge, its Access application wasn't saved"
  log_info "   correctly - go back and fix it before continuing."
  log_info ""
  read -r -p "Press Enter once the tunnel, both hostnames, and the Access policy exist... "

  # Nothing here creates or commits anything server-side (the tunnel/
  # hostnames/policy were already made manually above), so both fields
  # navigate locally and backing out of hostname (the first) exits the step.
  local field="hostname"
  while true; do
    case "$field" in
      hostname)
        prompt_text "SSH hostname (e.g. pod-ssh.yourdomain.com) ($TEXT_BACK_WORD to go back): " CLOUDFLARE_SSH_HOSTNAME || return 1
        [[ -n "$CLOUDFLARE_SSH_HOSTNAME" ]] || die "No SSH hostname entered."
        field="token"
        ;;
      token)
        prompt_text "Paste the tunnel token ($TEXT_BACK_WORD for hostname): " CLOUDFLARE_TUNNEL_TOKEN -s || { field="hostname"; continue; }
        # No cloudflared subcommand exists to validate a token's shape
        # (confirmed absent from current docs) - non-empty is the only
        # check available.
        [[ -n "$CLOUDFLARE_TUNNEL_TOKEN" ]] || die "No tunnel token entered."
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

# --- step 9: git identity ---------------------------------------------------

setup_git_identity() {
  log_info ""
  log_info "== Step 9: git identity (used inside the pod, passed via --env) =="
  local field="name"
  while true; do
    case "$field" in
      name)
        prompt_text "git user.name ($TEXT_BACK_WORD to go back): " GIT_USER_NAME || return 1
        field="email"
        ;;
      email)
        prompt_text "git user.email ($TEXT_BACK_WORD for user.name): " GIT_USER_EMAIL || { field="name"; continue; }
        [[ -n "$GIT_USER_NAME" && -n "$GIT_USER_EMAIL" ]] || die "Both git user.name and user.email are required."
        break
        ;;
    esac
  done
}

# --- step 10: write config --------------------------------------------------

write_config() {
  mkdir -p "$CONFIG_DIR"
  # Written with a restrictive umask for the duration of this call so the
  # file is never briefly world-readable between creation and chmod.
  ( umask 077
    cat > "$CONFIG_FILE" <<EOF
RUNPOD_API_KEY=$RUNPOD_API_KEY
SSH_KEY_PATH=$SSH_KEY_PATH
DATACENTER_ID=$DATACENTER_ID
NETWORK_VOLUME_ID=$NETWORK_VOLUME_ID
GITHUB_APP_ID=$GITHUB_APP_ID
GITHUB_APP_KEY_PATH=$GITHUB_APP_KEY_PATH
GITHUB_APP_INSTALLATION_ID=$GITHUB_APP_INSTALLATION_ID
CLOUDFLARE_SSH_HOSTNAME=$CLOUDFLARE_SSH_HOSTNAME
CLOUDFLARE_TUNNEL_TOKEN=$CLOUDFLARE_TUNNEL_TOKEN
GIT_USER_NAME=$GIT_USER_NAME
GIT_USER_EMAIL=$GIT_USER_EMAIL
EOF
  )
  chmod 600 "$CONFIG_FILE"
  # Confirm by presence/length only - never echo the values themselves.
  log_ok "Saved config to $CONFIG_FILE ($(wc -l < "$CONFIG_FILE") lines, mode $(stat -c %a "$CONFIG_FILE"))."
}

# --- entry point -------------------------------------------------------------

run_setup_wizard() {
  log_info "No config found (or --setup was passed) - running the one-time setup wizard."
  log_info "runpod-lab build $RUNPOD_LAB_BUILD"
  mkdir -p "$HOME/.local/bin"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) log_warn "~/.local/bin isn't on PATH yet - add it to your shell profile, or tools installed this run won't be found until you do." ;;
  esac

  log_info ""
  log_info "== Step 1: local tools =="
  install_runpodctl
  install_gh
  install_cloudflared
  install_gh_token_extension

  # Steps 2-9 run as a back-able sequence: any step can return 1 (e.g. the
  # user typed the safeword on its first prompt) to hand control to the
  # step before it, instead of the whole wizard only being restartable from
  # scratch. setup_ssh_key and setup_ssh_config have no prompts of their own
  # (they just re-run their side effects) but stay in the list so stepping
  # back past setup_datacenter/setup_git_identity lands somewhere sensible.
  local -a wizard_steps=(
    setup_runpod_api_key
    setup_ssh_key
    setup_datacenter
    setup_network_volume
    setup_github_app
    setup_cloudflare_tunnel
    setup_ssh_config
    setup_git_identity
  )
  run_step_sequence wizard_steps
  write_config

  log_info ""
  log_ok "Setup complete. Run ./startup.sh again (without --setup) to launch a pod."
  log_info "PREREQUISITES.md in this repo documents everything this wizard just asked for - if that list and this wizard ever disagree, the wizard wins and the doc needs an update."
}
