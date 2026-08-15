#!/usr/bin/env bash
#
# Pushes a launch's baseURL/apiKey into Kilo Code's, opencode's, and DeepSeek
# Harness's configs inside vscodium-box, so any of them can reach the pod
# without hand-editing config after every launch.
#
# Why this is needed: this repo generates a brand-new proxy URL and a
# one-off API key on every launch - no stable hostname, nothing stored, by
# design (see README.md). vscodium-box's own `podman exec` only forwards a
# fixed set of env vars (compute_env_args() in vscodium-for-immutable's
# install-vscodium.sh), which doesn't include anything this repo prints. So
# the fresh values have to be written into the container's config files
# directly, which is what this script does.
#
# How it reaches the files without touching any container at all: both
# configs live under ~/.config/ *inside* the container, but that whole
# directory is that container's own private home on the host, bind-mounted
# straight through (CONTAINER_HOME in vscodium-for-immutable's
# install-vscodium.sh), so editing the host copy edits the container's copy
# - no podman exec, no running container required. Defaults to
# vscodium-box's private home; pass --container-home to point it at a
# different one (see Usage below).
#
# Kilo Code and opencode are covered because both are actually installed in
# vscodium-box and, confirmed live, both had gone stale pointing at the same
# torn-down pod. Cline and Roo were not found installed there (checked via
# `find ~/.config ~/.vscode-oss/extensions`); they use a similar
# provider.<name>.options.{baseURL,apiKey} shape in their own settings
# files, so add an entry to CONFIGS below if you install one and hit this
# same staleness problem.
#
# Kilo Code needs a restart after this script runs; opencode does not. Kilo
# caches the provider's API key (and, in practice, the rest of the provider
# config with it) in its own sqlite store on session start
# (~/.local/share/kilo/kilo.db, `credential` table, one `Imported` row) and
# doesn't appear to re-read kilo.jsonc per request - confirmed live
# 2026-08-15, a running Kilo session kept 404ing against an already-replaced
# pod's proxy hostname well after this script had rewritten kilo.jsonc with
# the new one. Reload the VSCodium window or quit/relaunch Kilo after every
# re-sync. See GOTCHAS.md for the full writeup.
#
# DeepSeek Harness is a third case, structurally different from the other
# two: its config (`$DSH_HOME/settings.yaml`, `~/.dsh/settings.yaml` when
# unset) is YAML, not JSON, so the shared jq filter below can't touch it -
# it gets its own yq-based block. It also only supports `apiKeyEnv` (a
# credential *reference*), never a literal key in the file
# (@deepseek-ai/dsh-llm-pi-ai's own README, "Supported profile fields" -
# apiKey is not among them), so the key itself has nowhere to live in YAML
# and instead gets exported from `~/.bashrc` under CONTAINER_HOME. That file
# is only sourced by *interactive non-login* shells (confirmed live: `bash
# -lc`, what this script's own commands and `podman exec`'s default use, does
# NOT source it; `bash -ic` does) - which is exactly what VSCodium's
# integrated terminal opens, so `dsh` run there picks it up, but it needs a
# new terminal (not a reload) to see a re-synced key.
#
# lib/launch.sh calls this script directly with --base-url/--api-key/--model
# right after a launch, offering to run it via a y/N prompt (confirm() in
# lib/common.sh) - see run_normal_launch. The piped/--log modes below exist
# for running it by hand afterward, e.g. against a saved log, or a launch
# you declined to sync at the time.
#
# Usage:
#   ./sync-runpod-endpoint.sh --base-url URL --api-key KEY --model NAME
#                                               sync explicit values directly
#                                               (what lib/launch.sh calls)
#   ./startup.sh | ./sync-runpod-endpoint.sh   pipe a live launch straight in
#   ./sync-runpod-endpoint.sh --log FILE       parse output saved to a file instead
#   ./sync-runpod-endpoint.sh --container-home DIR
#                                               target a different container's private home
#                                               instead of vscodium-box's (e.g. another
#                                               project built the same way, or a second
#                                               vscodium-box under a different name)
#   ./sync-runpod-endpoint.sh --debug          same, but print every command run
#   ./sync-runpod-endpoint.sh --help           show this help
#
set -euo pipefail

# Bump this whenever the script's parsing or write logic changes. Only shown
# in --debug output, so you can tell which version produced a given log.
BUILD="2026.08.15-4"

PROVIDER_NAME="runpod-helper"

# vscodium-box's own private home, as computed by CONTAINER_HOME in
# vscodium-for-immutable's install-vscodium.sh - the default target.
# Override with --container-home to point this at some other container
# built the same way (a straight bind mount of a private home directory at
# ~).
CONTAINER_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/vscodium-box/home"

DEBUG=0
LOG_FILE=""
BASE_URL=""
API_KEY=""
MODEL_NAME=""

die() {
  echo "Error: $*" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)
      [ -n "${2:-}" ] || die "--base-url requires a URL."
      BASE_URL="$2"
      shift 2
      ;;
    --base-url=*)
      BASE_URL="${1#*=}"
      shift
      ;;
    --api-key)
      [ -n "${2:-}" ] || die "--api-key requires a key."
      API_KEY="$2"
      shift 2
      ;;
    --api-key=*)
      API_KEY="${1#*=}"
      shift
      ;;
    --model)
      [ -n "${2:-}" ] || die "--model requires a name."
      MODEL_NAME="$2"
      shift 2
      ;;
    --model=*)
      MODEL_NAME="${1#*=}"
      shift
      ;;
    --log)
      [ -n "${2:-}" ] || die "--log requires a file path."
      LOG_FILE="$2"
      shift 2
      ;;
    --log=*)
      LOG_FILE="${1#*=}"
      shift
      ;;
    --container-home)
      [ -n "${2:-}" ] || die "--container-home requires a directory path."
      CONTAINER_HOME="$2"
      shift 2
      ;;
    --container-home=*)
      CONTAINER_HOME="${1#*=}"
      shift
      ;;
    --debug)
      DEBUG=1
      shift
      ;;
    -h|--help)
      # Everything between the shebang and `set -euo pipefail` - a line
      # count would go stale every time this comment block grows (it
      # already had, cutting the old Usage list off mid-way).
      awk 'NR>1 && /^set -euo pipefail/ { exit } NR>1' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      die "Unknown option: $1 (use --help)"
      ;;
  esac
done

if [ "$DEBUG" -eq 1 ]; then
  echo "[debug] sync-runpod-endpoint.sh build $BUILD"
  set -x
fi

[ -d "$CONTAINER_HOME" ] \
  || die "container home not found: $CONTAINER_HOME (pass --container-home if it's not vscodium-box)"

# path|schema-url pairs, one per config file to patch. Built after arg
# parsing so --container-home takes effect. Both use the identical
# provider.<name>.options.{baseURL,apiKey} shape, so one jq filter (below)
# covers all of them - only the $schema used when creating a missing file
# differs.
CONFIGS=(
  "${CONTAINER_HOME}/.config/kilo/kilo.jsonc|https://app.kilo.ai/config.json"
  "${CONTAINER_HOME}/.config/opencode/opencode.jsonc|https://opencode.ai/config.json"
)

command -v jq >/dev/null 2>&1 \
  || die "jq is not installed. See https://jqlang.org/download/"

if [ -n "$BASE_URL" ] || [ -n "$API_KEY" ] || [ -n "$MODEL_NAME" ]; then
  # Direct-value mode (what lib/launch.sh uses): all three or none, so a
  # caller can never end up syncing a config with one field silently blank.
  [ -n "$BASE_URL" ] && [ -n "$API_KEY" ] && [ -n "$MODEL_NAME" ] \
    || die "--base-url, --api-key, and --model must all be given together."
else
  # Read the launch output either from --log or stdin. Not from a
  # positional arg: this is meant to be piped straight from startup.sh, and
  # the output easily runs to 50+ lines.
  INPUT=""
  if [ -n "$LOG_FILE" ]; then
    [ -f "$LOG_FILE" ] || die "log file not found: $LOG_FILE"
    INPUT="$(cat "$LOG_FILE")"
  elif [ ! -t 0 ]; then
    INPUT="$(cat)"
  else
    die "no input. Pipe startup.sh's output in, pass --log FILE, or use --base-url/--api-key/--model (use --help)."
  fi

  # These three grep patterns match this repo's launch-summary lines
  # exactly (lib/launch.sh's run_normal_launch). tail -n1 in case the input
  # has more than one launch summary in it (e.g. a full session log with a
  # retried GPU).
  BASE_URL="$(grep -oP '(?<=OpenAI-compatible endpoint: )\S+' <<<"$INPUT" | tail -n1 || true)"
  API_KEY="$(grep -oP '(?<=not stored anywhere\): )\S+' <<<"$INPUT" | tail -n1 || true)"
  MODEL_NAME="$(grep -oP '(?<=Model name for clients: )\S+' <<<"$INPUT" | tail -n1 || true)"

  [ -n "$BASE_URL" ] \
    || die "couldn't find an 'OpenAI-compatible endpoint:' line in the input. Is this startup.sh's output?"
  [ -n "$API_KEY" ] \
    || die "couldn't find an API key line ('...not stored anywhere): <key>') in the input."
  [ -n "$MODEL_NAME" ] \
    || die "couldn't find a 'Model name for clients:' line in the input."
fi

echo "Pod endpoint:  $BASE_URL"
echo "Model:         $MODEL_NAME"

for entry in "${CONFIGS[@]}"; do
  config_file="${entry%%|*}"
  schema_url="${entry#*|}"

  mkdir -p "$(dirname "$config_file")"
  if [ ! -f "$config_file" ]; then
    echo "No existing $config_file - creating one with just the $PROVIDER_NAME provider."
    printf '{"$schema": "%s", "provider": {}}' "$schema_url" > "$config_file"
  fi

  echo "Writing into:  $config_file"

  # Write via a temp file in the same directory, then mv, so a crash or
  # Ctrl-C mid-write can never leave the config truncated or half-written -
  # mv within the same filesystem is atomic.
  TMP_FILE="$(mktemp "${config_file}.XXXXXX")"
  trap 'rm -f "$TMP_FILE"' EXIT

  # //= only fills these in if absent, so a provider block you've hand-edited
  # (e.g. added more models) keeps anything this script doesn't know about.
  jq --arg url "$BASE_URL" --arg key "$API_KEY" --arg model "$MODEL_NAME" --arg name "$PROVIDER_NAME" '
    .provider[$name].name //= $name |
    .provider[$name].npm //= "@ai-sdk/openai-compatible" |
    .provider[$name].options.baseURL = $url |
    .provider[$name].options.apiKey = $key |
    .provider[$name].models[$model].name = $model
  ' "$config_file" > "$TMP_FILE"

  chmod --reference="$config_file" "$TMP_FILE" 2>/dev/null || chmod 0600 "$TMP_FILE"
  mv "$TMP_FILE" "$config_file"
  trap - EXIT
done

# --- DeepSeek Harness: separate block, see the file header for why -----------
DSH_CONFIG="${CONTAINER_HOME}/.dsh/settings.yaml"
DSH_API_KEY_ENV_NAME="RUNPOD_HELPER_API_KEY"
DSH_BASHRC="${CONTAINER_HOME}/.bashrc"

if ! command -v yq >/dev/null 2>&1 || ! yq --version 2>&1 | grep -q mikefarah; then
  echo "Note: mikefarah/yq not found (https://github.com/mikefarah/yq#install)" >&2
  echo "  - skipping DeepSeek Harness's settings.yaml (Kilo Code and opencode are unaffected)." >&2
else
  mkdir -p "$(dirname "$DSH_CONFIG")"
  if [ ! -f "$DSH_CONFIG" ]; then
    echo "No existing $DSH_CONFIG - creating one with just the $PROVIDER_NAME provider."
    printf '{}' > "$DSH_CONFIG"
  fi

  echo "Writing into:  $DSH_CONFIG"

  TMP_FILE="$(mktemp "${DSH_CONFIG}.XXXXXX")"
  trap 'rm -f "$TMP_FILE"' EXIT

  # Same fill-if-absent-vs-always-refresh split as the jq filter above, but
  # spelled as `.x = (.x // "default")` instead of jq's `//=` - confirmed
  # live (yq v4.53.3), `//=` anywhere in this expression breaks the `//`
  # used lower down for the models-array fallback with "'//' expects 2 args
  # but there is 1", even though each works fine on its own. `models` is a
  # YAML array (not a dict like the jq configs' `.models[$model]`), so
  # switching between launch presets needs an explicit append-if-missing
  # instead of a keyed merge, to avoid re-adding a duplicate entry on every
  # re-sync of the same model. yq has no jq-style if/then/else/end either -
  # `select(cond) // fallback` stands in for it.
  PROVIDER_NAME="$PROVIDER_NAME" BASE_URL="$BASE_URL" MODEL_NAME="$MODEL_NAME" \
  DSH_API_KEY_ENV_NAME="$DSH_API_KEY_ENV_NAME" \
    yq '
      .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].displayName = (
        .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].displayName // "RunPod Helper"
      ) |
      .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].api = "openai-completions" |
      .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].baseURL = strenv(BASE_URL) |
      .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].apiKeyEnv = strenv(DSH_API_KEY_ENV_NAME) |
      .["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].models = (
        (.["llm-pi-ai"].providers[strenv(PROVIDER_NAME)].models // []) as $existing |
        ($existing | select([$existing.[].id] | contains([strenv(MODEL_NAME)])))
          // ($existing + [{"id": strenv(MODEL_NAME)}])
      ) |
      .["agent-default-model"].provider = strenv(PROVIDER_NAME) |
      .["agent-default-model"].model = strenv(MODEL_NAME)
    ' "$DSH_CONFIG" > "$TMP_FILE"

  chmod --reference="$DSH_CONFIG" "$TMP_FILE" 2>/dev/null || chmod 0600 "$TMP_FILE"
  mv "$TMP_FILE" "$DSH_CONFIG"
  trap - EXIT

  # The key itself can't go in settings.yaml (see file header) - export it
  # from ~/.bashrc instead, replacing a previous export of the same name so
  # re-syncing doesn't pile up duplicate lines.
  touch "$DSH_BASHRC"
  if grep -q "^export ${DSH_API_KEY_ENV_NAME}=" "$DSH_BASHRC"; then
    sed -i "s|^export ${DSH_API_KEY_ENV_NAME}=.*|export ${DSH_API_KEY_ENV_NAME}=\"${API_KEY}\"|" "$DSH_BASHRC"
  else
    printf '\nexport %s="%s"\n' "$DSH_API_KEY_ENV_NAME" "$API_KEY" >> "$DSH_BASHRC"
  fi
  echo "Writing into:  $DSH_BASHRC (export ${DSH_API_KEY_ENV_NAME}=...)"
fi

echo "Done. The $PROVIDER_NAME provider under $CONTAINER_HOME now points at the pod above."
