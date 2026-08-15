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

# --- step 2b: optional HF token ---------------------------------------------

# Optional and skippable: not needed for any repo currently in
# PRESET_TABLE (all public/ungated), but authenticated hf_xet downloads are
# reported faster/more reliable than anonymous ones even for public repos
# (see load_secrets() in lib/common.sh for the doc citation) and it's
# required for any gated/private repo added later. A read-only token is
# enough - this repo never uploads anything.
setup_hf_token() {
  log_info ""
  log_info "== Step 2b: Hugging Face token (optional) =="
  log_info "Not required for the presets in this repo today, but can speed up" \
           "model downloads and is needed for any gated/private repo. Get a" \
           "read-only one at https://huggingface.co/settings/tokens if you want one."
  local hf_token
  prompt_text "Paste an HF token, or leave blank to skip ($TEXT_BACK_WORD to go back): " hf_token -s || return 1
  if [[ -n "$hf_token" ]]; then
    secret_store hf_token "$hf_token"
    log_ok "HF token stored in the OS keyring."
  else
    log_info "Skipped - no HF token stored."
  fi
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
  local dc_json gpu_json
  dc_json="$(runpodctl_t datacenter list)" || die "Could not list datacenters (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s) - check availability at https://www.runpod.io/console/gpu-cloud instead."
  # `datacenter list`'s own gpuAvailability[] can disagree with what `gpu
  # list` (the endpoint list_available_gpus() in lib/launch.sh actually
  # filters on at GPU-pick time) reports for the same datacenter - confirmed
  # live 2026-08-15, e.g. EU-SE-1 showed RTX A5000 in stock via `datacenter
  # list` but "none" via `gpu list`'s dataCenterAvailability. Since the
  # datacenter choice below is a one-way lock (network volume), the stock
  # shown here is pulled from `gpu list` instead so this menu doesn't
  # advertise a card that GPU selection won't actually offer.
  gpu_json="$(runpodctl_t gpu list)" || die "Could not list GPUs (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s) - check availability at https://www.runpod.io/console/gpu-cloud instead."

  # Field names (gpuId, displayName, dataCenterAvailability[].dataCenterId/
  # .stockStatus) confirmed against live `runpodctl gpu list` JSON output -
  # same fields list_available_gpus() (lib/launch.sh) reads.
  local -A dc_gpu_stock=()
  local stock_dcid stock_gpus
  while IFS=$'\t' read -r stock_dcid stock_gpus; do
    [[ -z "$stock_dcid" ]] && continue
    dc_gpu_stock["$stock_dcid"]="$stock_gpus"
  done < <(jq -r '
    [.[] | .displayName as $d | .dataCenterAvailability[]? | select(.stockStatus != "none") | {dc: .dataCenterId, name: $d}]
    | group_by(.dc)
    | map({dc: .[0].dc, gpus: ([.[].name] | join(", "))})
    | .[]
    | [.dc, .gpus] | @tsv
  ' <<< "$gpu_json")

  # Field names (id, location) confirmed against live `runpodctl datacenter
  # list` JSON output this session.
  local menu_rows
  menu_rows="$(jq -r '
    .[]
    | [.id, .location]
    | @tsv
  ' <<< "$dc_json")"

  [[ -n "$menu_rows" ]] || die "No datacenter data returned - check https://www.runpod.io/console/gpu-cloud instead."

  # Five/Nine/Fourteen Eyes intelligence-sharing alliances, keyed by ISO 3166
  # country code (en.wikipedia.org/wiki/Five_Eyes: 5 = US/UK/CA/AU/NZ; 9 adds
  # DK/FR/NL/NO; 14 adds DE/BE/IT/ES/SE). A code absent here counts as outside
  # all three - the privacy-preferred group.
  local -A eyes_tier=(
    [US]=5 [GB]=5 [CA]=5 [AU]=5 [NZ]=5
    [DK]=9 [FR]=9 [NL]=9 [NO]=9
    [DE]=14 [BE]=14 [IT]=14 [ES]=14 [SE]=14
  )
  # RunPod's `.location` is a specific country for some datacenters but the
  # generic "Europe" for most EU ones (confirmed live 2026-08-15). Map the
  # specific names to a code here; "Europe" and anything unmapped fall through
  # to the id's own country-code token below. Doing location-first matters:
  # US-DE-1's location is "United States", so it classifies as US (5) rather
  # than mis-reading the "DE" (Delaware, not Germany) token in its id.
  local -A loc_code=(
    ["United States"]=US ["Canada"]=CA ["Australia"]=AU ["New Zealand"]=NZ
    ["United Kingdom"]=GB ["France"]=FR ["Germany"]=DE ["Netherlands"]=NL
    ["Norway"]=NO ["Denmark"]=DK ["Sweden"]=SE ["Belgium"]=BE ["Italy"]=IT
    ["Spain"]=ES ["India"]=IN ["Japan"]=JP ["Singapore"]=SG ["SE Asia"]=SG
  )
  # Code -> country name, only for display when the location came back as the
  # generic "Europe" (so the menu shows "Romania", not "Europe").
  local -A cc_name=(
    [CZ]=Czechia [DK]=Denmark [NL]=Netherlands [IS]=Iceland [NO]=Norway
    [RO]=Romania [SE]=Sweden [FR]=France [DE]=Germany [BE]=Belgium [IT]=Italy
    [ES]=Spain [PL]=Poland [FI]=Finland [CH]=Switzerland [AT]=Austria
  )

  # Build "<rank><id><location><code><tier><gpus>" rows (US-separated, see
  # below), then sort rank ascending so outside-Eyes (rank 0) lands first,
  # 14/9/5 after.
  #
  # Fields are joined/split on ASCII Unit Separator (\x1f), not a real tab.
  # Confirmed live 2026-08-15: bash's `read` treats an all-whitespace IFS
  # (tab included) as "IFS whitespace", which collapses RUNS of the
  # delimiter and drops empty fields, same as it does for plain word
  # splitting. `tier` is empty for every outside-Eyes datacenter (the
  # recommended ones) whenever `gpus` isn't - i.e. constantly - so a
  # tab-delimited round-trip silently shifts every field after the empty
  # one, and `tier` ends up holding a GPU name that matches no `case`
  # branch below, leaving `tag` unset. \x1f isn't classified as IFS
  # whitespace, so `read` preserves empty fields with it.
  local US=$'\x1f'
  local sortable="" id location gpus code tier rank
  while IFS=$'\t' read -r id location; do
    [[ -z "$id" ]] && continue
    gpus="${dc_gpu_stock[$id]:-}"
    code="${loc_code[$location]:-}"
    # Generic/unmapped location -> the id's 2nd '-'-separated field is the
    # country code (EU-RO-1 -> RO, EUR-IS-1 -> IS); only reached when the
    # location itself didn't already resolve a code, so US states can't leak in.
    [[ -z "$code" ]] && code="$(cut -d- -f2 <<< "$id")"
    tier="${eyes_tier[$code]:-}"
    case "$tier" in
      "")  rank=0 ;;
      14)  rank=1 ;;
      9)   rank=2 ;;
      5)   rank=3 ;;
    esac
    sortable+="$rank$US$id$US$location$US$code$US$tier$US$gpus"$'\n'
  done <<< "$menu_rows"
  sortable="$(printf '%s' "$sortable" | sort -t"$US" -k1,1n -k2,2 -s)"

  local -a dc_ids=() dc_labels=()
  local rank_out cname loc_disp tag
  while IFS="$US" read -r rank_out id location code tier gpus; do
    [[ -z "$id" ]] && continue
    cname="${cc_name[$code]:-}"
    # Prefer a resolved country name over a bare "Europe".
    if [[ "$location" == "Europe" && -n "$cname" ]]; then loc_disp="$cname"; else loc_disp="$location"; fi
    case "$tier" in
      "")  tag="${COLOR_GREEN}[outside 5/9/14 Eyes - recommended]${COLOR_RESET}" ;;
      14)  tag="[14 Eyes]" ;;
      9)   tag="[9 Eyes]" ;;
      5)   tag="[5 Eyes]" ;;
    esac
    dc_ids+=("$id")
    # tag carries color escapes, so it goes last (unwidthed) - a fixed-width
    # column would count the invisible bytes and misalign every highlighted row.
    dc_labels+=("$(printf '%-10s %-14s %s  ' "$id" "$loc_disp" "${gpus:-no stock}")$tag")
  done <<< "$sortable"

  log_info ""
  log_info "Datacenters grouped by intelligence-sharing alliance (en.wikipedia.org/wiki/Five_Eyes):"
  log_info "those OUTSIDE the 5/9/14 Eyes are listed first (privacy-preferred, shown in green); Eyes"
  log_info "members follow but are all still selectable - pick whichever you want. The grouping is"
  log_info "best-effort from each datacenter's id/location; confirm the real jurisdiction yourself."
  log_info "(Changing datacenter later means re-running --setup, since the network volume is locked to it.)"
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
    setup_hf_token
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
