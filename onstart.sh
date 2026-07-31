#!/usr/bin/env bash
# onstart.sh - runs ON THE POD, once at boot (RunPod's container start
# command). Baked into the pod image; NOT distributed by startup.sh.
#
# idle-watchdog.sh and safety-commit.sh are fetched fresh from this repo's
# main branch every boot instead of being baked into the image, so a repo
# update takes effect on the next pod launch without an image rebuild.
# (Confirmed decision, not a guess: repo is public, so an unauthenticated
# curl of raw.githubusercontent.com works even before any GitHub auth
# exists in this pod - see the "no gh auth login here" note below.)
set -euo pipefail

RUNPOD_LAB_BUILD="2026.07.30"
REPO_RAW_BASE="https://raw.githubusercontent.com/Kinsman4249/runpod-helper/main"
RUN_DIR="/run/runpod-lab"
SCRIPT_DIR="/opt/runpod-lab"

mkdir -p "$RUN_DIR" "$SCRIPT_DIR"
echo "onstart.sh build $RUNPOD_LAB_BUILD starting."

# --- gh CLI (installed, but deliberately NOT authenticated here) -----------
# No GitHub credential exists in this context by design (see startup.sh's
# push_github_token comment) - the short-lived installation token only
# arrives later, pushed over SSH from the local machine once the tunnel is
# confirmed reachable. An unauthenticated `gh` on the pod at this point is
# expected, not a bug; don't "fix" this by adding gh auth login here.
if ! command -v gh >/dev/null 2>&1; then
  echo "Installing gh..."
  gh_url="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
    | grep -o '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
    | sed -E 's/.*"(https[^"]+)"/\1/' | head -n1)"
  tmp_dir="$(mktemp -d)"
  curl -fsSL "$gh_url" -o "$tmp_dir/gh.tar.gz"
  tar -xzf "$tmp_dir/gh.tar.gz" -C "$tmp_dir"
  install -m 755 "$(find "$tmp_dir" -type f -name gh -perm -u+x | head -n1)" /usr/local/bin/gh
  rm -rf "$tmp_dir"
fi

# --- git identity (from --env, not a secret) --------------------------------
git config --global user.name "${GIT_USER_NAME:?GIT_USER_NAME not set}"
git config --global user.email "${GIT_USER_EMAIL:?GIT_USER_EMAIL not set}"

# --- cloudflared: SSH + OpenHands UI ingress --------------------------------
# One process, one token. Ingress rules (SSH -> localhost:22, HTTP ->
# localhost:<OpenHands port>) live in Cloudflare's dashboard config for this
# named tunnel (set up once during the local wizard's step 7), not in a
# local config.yml - confirmed that token-based "cloudflared tunnel run"
# picks up dashboard-defined routes automatically, so no local ingress file
# is needed here.
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "Installing cloudflared..."
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
    -o /usr/local/bin/cloudflared
  chmod +x /usr/local/bin/cloudflared
fi

if [[ -f "$RUN_DIR/cloudflared.pid" ]] && kill -0 "$(cat "$RUN_DIR/cloudflared.pid")" 2>/dev/null; then
  echo "cloudflared already running (pid $(cat "$RUN_DIR/cloudflared.pid")) - leaving it alone."
else
  echo "Starting cloudflared tunnel..."
  nohup cloudflared tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN:?CLOUDFLARE_TUNNEL_TOKEN not set}" \
    >"$RUN_DIR/cloudflared.log" 2>&1 &
  echo $! > "$RUN_DIR/cloudflared.pid"
fi

# --- fetch + launch the idle watchdog ---------------------------------------
curl -fsSL "$REPO_RAW_BASE/idle-watchdog.sh" -o "$SCRIPT_DIR/idle-watchdog.sh"
curl -fsSL "$REPO_RAW_BASE/safety-commit.sh" -o "$SCRIPT_DIR/safety-commit.sh"
chmod +x "$SCRIPT_DIR/idle-watchdog.sh" "$SCRIPT_DIR/safety-commit.sh"

if [[ -f "$RUN_DIR/idle-watchdog.pid" ]] && kill -0 "$(cat "$RUN_DIR/idle-watchdog.pid")" 2>/dev/null; then
  echo "idle-watchdog.sh already running (pid $(cat "$RUN_DIR/idle-watchdog.pid")) - leaving it alone."
else
  echo "Starting idle-watchdog.sh..."
  nohup "$SCRIPT_DIR/idle-watchdog.sh" >"$RUN_DIR/idle-watchdog.log" 2>&1 &
  echo $! > "$RUN_DIR/idle-watchdog.pid"
fi

echo "onstart.sh done."
