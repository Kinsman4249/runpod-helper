# lib/common.sh - shared paths, logging, and small helpers for the local
# (non-pod) scripts. Sourced by startup.sh, lib/wizard.sh, and lib/launch.sh.
# Not meant to be run directly.

# Bump this string whenever a behavior-affecting change lands, so a user
# pasting output into a bug report gives us something to anchor on.
RUNPOD_LAB_BUILD="2026.07.30"

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

# Simple yes/no prompt. Defaults to "no" on empty input so an accidental
# Enter key never confirms something destructive or costly.
confirm() {
  local prompt="$1"
  local reply
  read -r -p "$prompt [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}
