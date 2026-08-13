# lib/common.sh - shared paths, logging, and small helpers for the local
# (non-pod) scripts. Sourced by startup.sh, lib/wizard.sh, and lib/launch.sh.
# Not meant to be run directly.

# Bump this string whenever a behavior-affecting change lands, so a user
# pasting output into a bug report gives us something to anchor on.
RUNPOD_LAB_BUILD="2026.08.13"

CONFIG_DIR="$HOME/.runpod-lab"
CONFIG_FILE="$CONFIG_DIR/config"
LAST_SESSION_FILE="$CONFIG_DIR/last-session"

# Plain color codes, no tput dependency (tput isn't guaranteed present, and
# these scripts avoid pulling in anything not already confirmed installed).
COLOR_RED=$'\033[31m'
COLOR_YELLOW=$'\033[33m'
COLOR_GREEN=$'\033[32m'
COLOR_RESET=$'\033[0m'

log_info()  { printf '%s\n' "$*"; }
log_ok()    { printf '%s%s%s\n' "$COLOR_GREEN" "$*" "$COLOR_RESET"; }
log_warn()  { printf '%s%s%s\n' "$COLOR_YELLOW" "$*" "$COLOR_RESET" >&2; }
log_error() { printf '%s%s%s\n' "$COLOR_RED" "$*" "$COLOR_RESET" >&2; }

# Fails loudly with a message and a non-zero exit, instead of letting a
# script die on some unrelated line with no context.
die() {
  log_error "ERROR: $*"
  exit 1
}

# Confirms a binary is on PATH before we rely on it later. Used for tools
# the wizard is supposed to have already installed, so a miss here means
# the wizard was skipped or something failed silently.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. Run 'startup.sh --setup' first."
}

# Tightens a sensitive file to 600 (owner read/write only) if it isn't
# already, warning so it's visible when it happens. Covers files we don't
# fully control the creation of - e.g. runpodctl writes ~/.runpod/config.toml
# with its own umask (644 by default), and a GitHub App .pem is often just
# downloaded from a browser (which typically leaves it group/world-readable).
secure_file() {
  local path="$1"
  [[ -e "$path" ]] || return 0
  local mode
  mode="$(stat -c %a "$path")"
  if [[ "$mode" != "600" ]]; then
    chmod 600 "$path"
    log_warn "Tightened permissions on $path (was $mode, now 600) - it holds a credential."
  fi
  return 0
}

# Simple yes/no prompt. Defaults to "no" on empty input so an accidental
# Enter key never confirms something destructive or costly.
confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# Safeword for free-text prompts (see prompt_text below). Distinct from the
# numbered-menu safeword ('b') on purpose: a bare "b" is plausible real input
# for a text field (e.g. someone naming a volume "b"), so it can't double as
# an escape hatch there the way it safely can in a 1-N menu.
TEXT_BACK_WORD=":b"

# Free-text prompt with the same 'back out' contract as select_from_menu:
# typing the safeword ($TEXT_BACK_WORD) returns 1 and leaves the result var
# unset, so the caller can re-do (or bounce back to) whatever came before
# this prompt. Pass -s as a 4th arg for hidden input (API keys, tokens).
# Usage: prompt_text "Prompt text: " result_var [-s]
prompt_text() {
  local prompt="$1" result_var="$2" secret="${3:-}"
  local reply
  if [[ "$secret" == "-s" ]]; then
    read -r -s -p "$prompt" reply
    echo
  else
    read -r -p "$prompt" reply
  fi
  [[ "$reply" == "$TEXT_BACK_WORD" ]] && return 1
  printf -v "$result_var" '%s' "$reply"
}

# Creates a network volume and sets NETWORK_VOLUME_ID from the response - no
# manual copy-paste, since the id is right there in the JSON runpodctl already
# returns. Prints a short human-readable summary instead of the raw JSON.
# Usage: create_network_volume vol_name vol_size
create_network_volume() {
  local vol_name="$1" vol_size="$2"
  local create_json
  create_json="$(runpodctl network-volume create --name "$vol_name" --size "$vol_size" --data-center-id "$DATACENTER_ID")" \
    || die "Volume creation failed."

  NETWORK_VOLUME_ID="$(jq -r '.id // empty' <<< "$create_json")"
  [[ -n "$NETWORK_VOLUME_ID" ]] || die "Volume created but no id found in the response: $create_json"

  log_ok "Volume created:"
  jq -r '"  ID:         \(.id)\n  Name:       \(.name)\n  Size:       \(.size) GB\n  Datacenter: \(.dataCenterId)"' <<< "$create_json"
}

# --- credential validation ---------------------------------------------------
# Both checks below exist so a key/token rotated or revoked outside this repo
# (e.g. in the RunPod or Cloudflare dashboard) fails fast with a clear message
# - at wizard setup, at the start of every normal launch, and from --rotate -
# instead of surfacing later as a confusing runpodctl/cloudflared error, or on
# the pod after a billed create_pod call already ran.

# Live validation call - confirmed to exist (runpodctl user / alias me), exact
# output shape wasn't independently confirmed, so we only check exit status.
validate_runpod_api_key() {
  runpodctl user >/dev/null 2>&1 \
    || die "RUNPOD_API_KEY was rejected. Double check it's valid and active, or run 'startup.sh --rotate' to paste a fresh one."
}

# Cloudflare's dashboard shows the tunnel token embedded in a full install/
# run command (e.g. Windows: "cloudflared.exe service install eyJh...",
# Linux/run: "cloudflared tunnel run --token eyJh..."), and it's easy to
# copy-paste the whole line by habit. The token itself is always base64 of
# JSON starting with {"a": (account tag), so it always starts with "eyJhIjoi"
# - extract just that so pasting the full command works as well as the bare
# token.
extract_cloudflare_token() {
  grep -oE 'eyJhIjoi[A-Za-z0-9_+/=-]+' <<< "$1" | head -n1
}

# No cloudflared subcommand validates a token without actually connecting, so
# this briefly runs `cloudflared tunnel run` and watches its log for the
# success line ("Registered tunnel connection") or the rejection line
# ("Unauthorized: ..."), then tears the connection down either way. Log
# strings confirmed via Cloudflare's troubleshooting docs and community
# reports of revoked-token errors (docs.cloudflare.com/cloudflare-one/
# networks/connectors/cloudflare-tunnel/troubleshoot-tunnels/common-errors/).
validate_cloudflare_tunnel_token() {
  require_cmd cloudflared
  local logfile
  logfile="$(mktemp)"
  # --loglevel/--logfile are TUNNEL COMMAND options and only take effect
  # *before* the "run" subcommand (confirmed via `cloudflared tunnel run
  # --help`, which lists them under "TUNNEL COMMAND OPTIONS" vs. --token
  # under "SUBCOMMAND OPTIONS") - putting them after "run" silently drops
  # them, leaving $logfile empty and this check permanently timing out
  # regardless of whether the token is actually valid.
  cloudflared tunnel --loglevel info --logfile "$logfile" run --token "$CLOUDFLARE_TUNNEL_TOKEN" \
    >/dev/null 2>&1 &
  local cf_pid=$!

  local waited=0 max_wait=15 result="timeout"
  while (( waited < max_wait )); do
    if grep -q "Registered tunnel connection" "$logfile" 2>/dev/null; then
      result="ok"; break
    fi
    if grep -qi "Unauthorized" "$logfile" 2>/dev/null; then
      result="rejected"; break
    fi
    sleep 1; waited=$((waited + 1))
  done

  kill "$cf_pid" 2>/dev/null || true
  wait "$cf_pid" 2>/dev/null || true
  rm -f "$logfile"

  case "$result" in
    ok)       log_ok "Cloudflare tunnel token validated." ;;
    rejected) die "CLOUDFLARE_TUNNEL_TOKEN was rejected (rotated/revoked?). Run 'startup.sh --rotate' to paste a fresh one." ;;
    timeout)  die "Could not confirm the Cloudflare tunnel token within ${max_wait}s - check network connectivity, or run 'startup.sh --rotate' to paste a fresh one." ;;
  esac
}

# Runs an ordered list of step functions (each named in the $1 array),
# letting any step "go back" by returning 1 - the runner then re-invokes the
# previous step instead of advancing. Steps are responsible for their own
# internal back/forward navigation (e.g. between fields within one step);
# they should only return 1 to hand control to whatever step came before
# them. Returning 1 from the very first step just re-runs that same step,
# since there's nothing earlier to fall back to.
# Usage: local -a steps=(step_one step_two step_three); run_step_sequence steps
run_step_sequence() {
  local -n steps_ref="$1"
  local i=0
  local n=${#steps_ref[@]}
  while (( i < n )); do
    if "${steps_ref[$i]}"; then
      (( i++ ))
    else
      (( i > 0 )) && (( i-- ))
    fi
  done
}

# Numbered-menu prompt shared by every "pick one of these" spot (preset,
# GPU, datacenter) so they all look and behave the same instead of each
# hand-rolling its own read/case. Prints the options, loops until a valid
# number is entered, and writes that 1-based index into $2 (the caller maps
# it back to whatever value array it cares about). Typing 'b' backs out
# without picking: the function returns 1 and leaves $2 unset, so the
# caller can go re-do whatever step came before this menu.
# Usage: select_from_menu "Choose a preset" result_var "label one" "label two" ...
select_from_menu() {
  local prompt="$1" result_var="$2"
  shift 2
  local -a labels=("$@")
  local n=${#labels[@]}
  local i
  for (( i = 0; i < n; i++ )); do
    log_info "  $((i + 1))) ${labels[$i]}"
  done
  local choice
  while true; do
    read -r -p "$prompt (1-$n, or b to go back): " choice
    [[ "$choice" == "b" || "$choice" == "B" ]] && return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )) && break
    log_warn "Enter a number between 1 and $n, or 'b' to go back."
  done
  printf -v "$result_var" '%s' "$choice"
}
