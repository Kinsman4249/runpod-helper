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

# Toggleable debug logging: off by default, --debug turns it on (see
# startup.sh/e2e-test.sh). Writes a full `set -x` trace to BOTH the
# terminal (visible live - e.g. to see exactly where a hang like
# 2026-08-13's runpodctl-with-no-timeout one stalls) and a timestamped file
# under $CONFIG_DIR/logs (outside the repo, no gitignore entry needed)
# tagged with the build number, so a log pasted later can be matched to the
# exact code that produced it. Must be called AFTER argument parsing (needs
# to know --debug was passed) - everything before that point in a script's
# own top-of-file var/flag setup won't be captured, only what runs after.
#
# `set -x` traces raw, fully-expanded commands with no concept of "this is a
# secret" - confirmed live 2026-08-13 that an unfiltered trace printed a
# real RUNPOD_API_KEY value in full, in both the terminal and the log file,
# the first time this feature existed at all (before this redaction filter
# was added in response). $REDACT_SED below is a BEST-EFFORT mitigation, NOT
# a guarantee: it masks known secret variable names, the JSON forms they
# take in create_pod()'s --env payload, Authorization headers, and RunPod's
# own distinctive token prefix (rpa_) - but a raw `set -x` trace can always
# leak a secret through some code path this filter doesn't anticipate.
# Treat any --debug log, and any --debug terminal output you paste
# elsewhere, as sensitive regardless - skim it before sharing it.
REDACT_SED='
  s/(RUNPOD_API_KEY|VLLM_API_KEY)=[^ '"'"']*/\1=***REDACTED***/g
  s/"(RUNPOD_API_KEY|VLLM_API_KEY)":"[^"]*"/"\1":"***REDACTED***"/g
  s/(Authorization:? ?Bearer) [A-Za-z0-9._-]+/\1 ***REDACTED***/g
  s/rpa_[A-Za-z0-9]+/***REDACTED-RUNPOD-KEY***/g
'

enable_debug_logging() {
  local script_name="$1" mode="${2:-both}"   # "both" (console+disk) or "disk" (disk only)
  local log_dir="$CONFIG_DIR/logs"
  mkdir -p "$log_dir"
  DEBUG_LOG_FILE="$log_dir/${script_name}-$(date +%Y%m%dT%H%M%S)-build${RUNPOD_LAB_BUILD}.log"

  if [[ "$mode" == "disk" ]]; then
    # `read -p` prompts write to stderr with no trailing newline (bash's
    # documented behavior) - the same stream `set -x`'s trace uses. Piping
    # stderr through sed/tee/grep to filter trace lines out of the console
    # copy risks delaying or garbling that no-newline prompt text behind a
    # pipe buffer, breaking interactivity. BASH_XTRACEFD (bash 4.1+) sidesteps
    # this entirely: it routes the trace to its own dedicated fd instead of
    # stderr, so stdout/stderr - and therefore every prompt - are completely
    # untouched; the console never sees trace output at all. That dedicated
    # fd is itself a process-substitution pipe (not a raw file) specifically
    # so $REDACT_SED still applies before anything reaches disk - buffering
    # delay here is fine since nothing interactive is waiting on this fd.
    exec {_debug_trace_fd}> >(stdbuf -oL sed -E "$REDACT_SED" >> "$DEBUG_LOG_FILE")
    BASH_XTRACEFD=$_debug_trace_fd
    set -x
    log_info "Debug mode (disk-only): trace being written to $DEBUG_LOG_FILE (build $RUNPOD_LAB_BUILD) - console stays clean, only prompts/normal output show here. Secrets are best-effort redacted in the file, NOT guaranteed - still treat it as sensitive. Note: only the trace lands in the file this way, not the wizard's own prompt/message text (which never left the console) - use the default --debug (both) instead if you need those captured too."
  else
    # `set -x`'s own trace goes to stderr - filtering and duplicating both
    # streams (rather than just stderr) also captures the wizard's normal
    # prompts/output in the same file, not just the trace lines, without
    # silencing either stream on the terminal. `stdbuf -oL` keeps sed
    # line-buffered so redacted output still appears promptly rather than
    # only once its pipe buffer fills.
    exec > >(stdbuf -oL sed -E "$REDACT_SED" | tee -a "$DEBUG_LOG_FILE") \
         2> >(stdbuf -oL sed -E "$REDACT_SED" | tee -a "$DEBUG_LOG_FILE" >&2)
    set -x
    log_info "Debug mode: full trace also being written to $DEBUG_LOG_FILE (build $RUNPOD_LAB_BUILD). Secrets are best-effort redacted, NOT guaranteed - still treat this file as sensitive."
  fi
}

# `runpodctl` has no built-in request timeout of its own, and every call
# site in this repo used to invoke it bare - confirmed live 2026-08-13 that
# validate_runpod_api_key()'s plain `runpodctl user` call hangs indefinitely
# with zero output/feedback on a network hiccup, stalling --setup right at
# the first credential prompt with nothing on screen to explain why. Every
# runpodctl invocation in this repo goes through this wrapper instead so a
# hang fails loudly (exit 124) after a bounded wait rather than silently
# blocking forever.
RUNPODCTL_TIMEOUT_SECS=20
runpodctl_t() {
  timeout "$RUNPODCTL_TIMEOUT_SECS" runpodctl "$@"
}

# --- ephemeral per-launch SSH key -------------------------------------------
# Generated fresh for every pod launch and registered with RunPod via
# `runpodctl ssh add-key` - no long-lived keypair sitting in the account
# forever the way the old setup_ssh_key() (one keypair, generated once by
# the wizard, reused by every future launch) did. Must run BEFORE
# create_pod(): RunPod bakes every currently-registered account key into a
# new pod's authorized_keys at boot (via its own PUBLIC_KEY env, confirmed
# live 2026-08-14 - a pod's `env.PUBLIC_KEY` lists every key on the
# account), so the key has to exist in the account first for a new pod to
# pick it up.
setup_ephemeral_ssh_key() {
  local key_dir
  key_dir="$(mktemp -d "${TMPDIR:-/tmp}/runpod-lab-ssh.XXXXXX")" || die "Could not create a temp dir for the ephemeral SSH key."
  SSH_KEY_PATH="$key_dir/id_ed25519"
  ssh-keygen -t ed25519 -N "" -C "runpod-lab-ephemeral-$(date +%s)" -f "$SSH_KEY_PATH" >/dev/null \
    || die "ssh-keygen failed to generate the ephemeral SSH keypair."
  chmod 600 "$SSH_KEY_PATH"
  runpodctl_t ssh add-key --key-file "$SSH_KEY_PATH.pub" \
    || die "Failed to register the ephemeral SSH key with your RunPod account (or timed out after ${RUNPODCTL_TIMEOUT_SECS}s)."
  SSH_KEY_FINGERPRINT="$(ssh-keygen -lf "$SSH_KEY_PATH.pub" | awk '{print $2}')"
  log_ok "Generated and registered a one-off SSH key for this pod ($SSH_KEY_FINGERPRINT)."
}

# Reverses setup_ephemeral_ssh_key(): removes the key from the RunPod
# account and deletes the local copy. Best-effort on the remote removal
# (`|| true` via log_warn, not die) - a leftover key in the account is a
# minor cleanup issue, not worth taking a teardown script down over, same
# reasoning as e2e-test.sh's cleanup() trap for the pod stop/delete calls
# it runs alongside this.
cleanup_ephemeral_ssh_key() {
  if [[ -n "${SSH_KEY_FINGERPRINT:-}" ]]; then
    if runpodctl_t ssh remove-key --fingerprint "$SSH_KEY_FINGERPRINT" >/dev/null 2>&1; then
      log_ok "Removed the ephemeral SSH key ($SSH_KEY_FINGERPRINT) from your RunPod account."
    else
      log_warn "Could not remove the ephemeral SSH key ($SSH_KEY_FINGERPRINT) from your RunPod account automatically - remove it by hand at https://www.runpod.io/console/user/settings if you want it fully revoked."
    fi
  fi
  [[ -n "${SSH_KEY_PATH:-}" ]] && rm -rf "$(dirname "$SSH_KEY_PATH")"
}

# Resolves $POD_ID's SSH-over-proxy target (sets SSH_PROXY_HOST to
# "<pod-id>-<hash>") for diagnostics: `ssh -i $SSH_KEY_PATH
# $SSH_PROXY_HOST@ssh.runpod.io` - the pod-host-id is the USERNAME, against
# a single shared hostname, not "<pod-host-id>.ssh.runpod.io" as a
# subdomain (that form does not resolve at all - confirmed live 2026-08-15,
# see GOTCHAS.md). This is NOT direct-TCP SSH
# (resolve_pod_ssh_endpoint() used to do that, removed 2026-08-14 along
# with the custom image - the bare vllm/vllm-openai image never starts an
# sshd, so 22/tcp is never listening for RunPod to map). RunPod's proxy
# instead execs directly into the container on their own infra side, using
# the same ephemeral key registered via setup_ephemeral_ssh_key() -
# confirmed live 2026-08-14. The "<hash>" isn't exposed by runpodctl at
# all; only RunPod's GraphQL API has it (machine.podHostId), confirmed by
# testing every runpodctl subcommand first and finding none of them
# surface it.
#
# Also confirmed live: this proxy connection REQUIRES a real PTY and
# rejects a command argument outright ("Error: Your SSH client doesn't
# support PTY" with -T; a command argument with -tt is silently ignored
# and drops into an interactive shell instead) - so this is diagnostics-
# only, not something a script can pipe a single command through cleanly.
# Not used by wait_for_pod_ready() below; readiness is wait_for_vllm_ready()
# polling the actual HTTP endpoint, same signal a real client would use.
resolve_pod_ssh_proxy_host() {
  local gql body resp
  gql='query GetPod($id: String!) { pod(input: {podId: $id}) { machine { podHostId } } }'
  body="$(jq -n --arg q "$gql" --arg id "$POD_ID" '{query: $q, variables: {id: $id}}')"
  resp="$(curl -fsS --max-time "$RUNPODCTL_TIMEOUT_SECS" -X POST \
    "https://api.runpod.io/graphql?api_key=${RUNPOD_API_KEY}" \
    -H "Content-Type: application/json" -d "$body")" || {
    log_error "GraphQL request for pod $POD_ID's SSH proxy host failed."
    return 1
  }
  SSH_PROXY_HOST="$(jq -r '.data.pod.machine.podHostId // empty' <<< "$resp")"
  [[ -n "$SSH_PROXY_HOST" ]] || {
    log_error "No podHostId in GraphQL response for pod $POD_ID: $resp"
    return 1
  }
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

# --- secrets: OS keyring (libsecret/Secret Service), not plaintext ---------
# RUNPOD_API_KEY lives in the login keyring instead of $CONFIG_FILE - the
# prior model was chmod 600 on a plain file, fine for the old throwaway
# no-passphrase SSH key but not for a credential that gates a billed API
# account. VLLM_API_KEY and CLOUDFLARE_TUNNEL_TOKEN used to live here too;
# both are gone now (see load_secrets()'s migration below and
# CHANGELOG.md) - the vLLM key is generated fresh per launch instead of
# stored, and Cloudflare is out of the picture entirely (RunPod's own
# per-pod proxy URL + the pod's own 22/tcp cover both jobs it used to do).
# Needs `secret-tool` (Debian/
# Ubuntu package libsecret-tools, Fedora/Arch libsecret) and a running,
# unlocked Secret Service (GNOME Keyring or KWallet) in this session -
# normally already true for a real desktop login. Not available in a
# headless shell with no D-Bus session bus; there's no fallback for that
# case by design (see CHANGELOG.md for why - the secret_store call below
# just fails loudly with die() rather than silently degrading to disk).
SECRET_SERVICE="runpod-lab"

secret_store() {
  local field="$1" value="$2"
  printf '%s' "$value" \
    | secret-tool store --label="runpod-lab: $field" service "$SECRET_SERVICE" field "$field" \
    || die "Failed to store '$field' in the OS keyring via secret-tool. Check that a Secret Service (GNOME Keyring/KWallet) is running and unlocked in this session."
}

secret_lookup() {
  local field="$1"
  # `|| true`: callers check emptiness of the output, not this function's
  # exit code. Without it, a lookup failure (locked keyring, no entry, a
  # D-Bus hiccup) makes THIS command substitution's exit status non-zero;
  # if a caller does `var="$(secret_lookup ...)"` as a bare assignment,
  # `set -e` treats that as the assignment's own exit status and kills the
  # whole script right there - silently, before any die() with a real
  # message gets a chance to run.
  secret-tool lookup service "$SECRET_SERVICE" field "$field" 2>/dev/null || true
}

secret_clear() {
  local field="$1"
  secret-tool clear service "$SECRET_SERVICE" field "$field" >/dev/null 2>&1 || true
}

# Populates RUNPOD_API_KEY from the keyring into the current shell. Also
# migrates it in place the first time this runs against an old-format
# config: if `source "$CONFIG_FILE"` (which the caller must do BEFORE
# calling this) left it set as a plain shell var, that means this is a
# pre-keyring config file with the secret still sitting in plaintext -
# store it in the keyring and strip the line from the file, so an existing
# install upgrades on its very next run instead of needing --setup re-run.
# Also clears out any VLLM_API_KEY/CLOUDFLARE_TUNNEL_TOKEN left behind by a
# pre-ephemeral-key install (see CHANGELOG.md) - neither is read anymore,
# no reason to leave them sitting in the keyring.
load_secrets() {
  require_cmd secret-tool
  if [[ -n "${RUNPOD_API_KEY:-}" ]]; then
    secret_store runpod_api_key "$RUNPOD_API_KEY"
    sed -i '/^RUNPOD_API_KEY=/d' "$CONFIG_FILE"
    log_ok "Migrated RUNPOD_API_KEY out of $CONFIG_FILE and into the OS keyring - removed it from the plaintext file."
  fi
  if [[ -n "$(secret_lookup vllm_api_key)" || -n "$(secret_lookup cloudflare_tunnel_token)" ]]; then
    secret_clear vllm_api_key
    secret_clear cloudflare_tunnel_token
    sed -i '/^VLLM_API_KEY=/d;/^CLOUDFLARE_TUNNEL_TOKEN=/d;/^CLOUDFLARE_SSH_HOSTNAME=/d;/^CLOUDFLARE_API_HOSTNAME=/d;/^SSH_KEY_PATH=/d' "$CONFIG_FILE"
    log_ok "Removed the old VLLM_API_KEY/Cloudflare keyring entries and config lines - both are generated fresh per launch now instead of stored."
  fi

  RUNPOD_API_KEY="$(secret_lookup runpod_api_key)"
  [[ -n "$RUNPOD_API_KEY" ]] || die "No RUNPOD_API_KEY in the OS keyring. Run 'startup.sh --setup' (or --rotate) to store one."

  # HF_TOKEN is optional and unrelated to RUNPOD_API_KEY above - it's not
  # needed for any repo in the PRESET_TABLE right now (all public/ungated),
  # but authenticating with HF's hf_xet download path is reported to be
  # faster/more reliable than anonymous requests even for public repos
  # (docs.huggingface.co/docs/huggingface_hub/en/guides/download#faster-downloads:
  # hf_xet's CAS step "confirms the user is authorized" before handing out
  # presigned chunk URLs, which anonymous requests don't get routed through
  # the same way). Silently empty if never stored - create_pod() (lib/
  # launch.sh) only adds it to a pod's env when non-empty.
  HF_TOKEN="$(secret_lookup hf_token)"
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
  # Named _prompt_text_reply, not the more obvious "reply": if a caller's
  # own result_var also happened to be literally named "reply" (confirmed
  # live 2026-08-13 - setup_vllm_api_key's did), `printf -v "$result_var"`
  # below would resolve to THIS function's own local "reply" instead of the
  # caller's, since bash's dynamic scoping lets an indirect assignment see
  # its own innermost-scope local of the same name first. The caller's var
  # would then stay genuinely unset, tripping `set -u` the next time it's
  # read. Prefixed so it can't collide with any plausible caller variable
  # name.
  local _prompt_text_reply
  if [[ "$secret" == "-s" ]]; then
    read -r -s -p "$prompt" _prompt_text_reply
    echo
  else
    read -r -p "$prompt" _prompt_text_reply
  fi
  [[ "$_prompt_text_reply" == "$TEXT_BACK_WORD" ]] && return 1
  printf -v "$result_var" '%s' "$_prompt_text_reply"
}

# Creates a network volume and sets NETWORK_VOLUME_ID from the response - no
# manual copy-paste, since the id is right there in the JSON runpodctl already
# returns. Prints a short human-readable summary instead of the raw JSON.
# Usage: create_network_volume vol_name vol_size
create_network_volume() {
  local vol_name="$1" vol_size="$2"
  local create_json
  create_json="$(runpodctl_t network-volume create --name "$vol_name" --size "$vol_size" --data-center-id "$DATACENTER_ID")" \
    || die "Volume creation failed."

  NETWORK_VOLUME_ID="$(jq -r '.id // empty' <<< "$create_json")"
  [[ -n "$NETWORK_VOLUME_ID" ]] || die "Volume created but no id found in the response: $create_json"

  log_ok "Volume created:"
  jq -r '"  ID:         \(.id)\n  Name:       \(.name)\n  Size:       \(.size) GB\n  Datacenter: \(.dataCenterId)"' <<< "$create_json"
}

# --- credential validation ---------------------------------------------------
# Exists so a key rotated or revoked outside this repo (e.g. in the RunPod
# dashboard) fails fast with a clear message - at wizard setup, at the
# start of every normal launch, and from --rotate - instead of surfacing
# later as a confusing runpodctl error, or on the pod after a billed
# create_pod call already ran.

# Live validation call - confirmed to exist (runpodctl user / alias me), exact
# output shape wasn't independently confirmed, so we only check exit status.
validate_runpod_api_key() {
  local rc=0
  runpodctl_t user >/dev/null 2>&1 || rc=$?
  if (( rc == 124 )); then
    die "RunPod API didn't respond within ${RUNPODCTL_TIMEOUT_SECS}s (runpodctl user timed out). Check your network connection or https://uptime.runpod.io for an outage, then try again."
  elif (( rc != 0 )); then
    die "RUNPOD_API_KEY was rejected. Double check it's valid and active, or run 'startup.sh --rotate' to paste a fresh one."
  fi
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
      # NOT `(( i++ ))`: post-increment evaluates to i's OLD value, so the
      # very first time this runs (i=0) the arithmetic command itself
      # evaluates "false" (0) and, under `set -e`, silently kills the whole
      # script right here with no error message - confirmed live
      # 2026-08-13, this is what made --setup exit right after the first
      # successful wizard step every time, with runpodctl_t's own timeout
      # fix (a red herring - the underlying call was succeeding fine) ruled
      # out via a --debug trace that showed rc=0 right before the silent
      # exit. Pre-increment evaluates to the NEW value instead, which is
      # never 0 on this branch (i only grows here), so it's always true.
      (( ++i ))
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
