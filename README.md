# runpod-helper

One-time-setup, mostly-hands-off tooling to run OpenHands + llama.cpp
coding agents on a rented RunPod Secure Cloud GPU pod, with the code disk
destroyed every session and nothing long-lived stored on RunPod's side.

## What this does

- `startup.sh` (runs on your own machine): pick a GPU tier and model
  preset once, then silently reuse that choice on every future run
  (`--new` to change it). Creates the RunPod Secure Cloud pod, attaches
  the persistent model-weights volume, waits for the Cloudflare
  Tunnel/SSH path to come up, then mints a short-lived GitHub App
  installation token locally and pushes it into the pod over SSH. No
  GitHub credential ever touches RunPod's stored pod config.
- `onstart.sh` (runs once when the pod boots): installs `gh`
  (unauthenticated - auth arrives later over SSH), starts the Cloudflare
  Tunnel, and launches the idle watchdog.
- `idle-watchdog.sh` + `safety-commit.sh` (run inside the pod): after a
  configurable idle period with no active SSH session, commit and push
  any uncommitted work to a timestamped safety branch, then stop and
  delete the pod.
- Model serving: llama.cpp (`llama-server`), not Ollama, so
  quantization, KV-cache type, and speculative decoding are all directly
  configurable. Two presets: a dense Qwen3.6-27B build with MTP
  speculative decoding on by default, and a Qwen3-Coder-Next (MoE) build
  for larger-context/quality work on bigger cards, without assuming
  speculative decoding helps there.
- OpenHands runs in Local Runtime mode (no Docker - RunPod Pods can't
  nest containers anyway), accepting the reduced sandbox isolation
  specifically because the code disk this runs on is destroyed every
  session.

## Why

- RunPod Secure Cloud was picked for predictable, zero-egress billing
  (RunPod's own datacenters, not third-party community hosts).
- Nothing long-lived sits on RunPod's platform: no PAT in `--env`, no
  static secret in the pod's stored config. The only long-lived
  credential (a GitHub App private key) stays on the local machine; only
  a short-lived (about one hour) installation token ever reaches the
  pod.
- Code and secrets that actually matter never live on the rented box at
  all; they stay on the local machine. The pod's code disk existing only
  per-session is a feature here, not a limitation.

## Status

Scaffold and community-health files only, as of this commit. Scripts
land as they're built.

## Requirements

- `runpodctl`, `gh`, and the `gh-token` extension (`Link-/gh-token`)
  installed locally as user-level binaries. This project's author runs
  an immutable-OS setup (Bazzite/Fedora, rpm-ostree based) where these
  go in `~/.local/bin` rather than through the system package manager -
  see comments in `startup.sh` once it lands if that applies to you too.
- A RunPod account with Secure Cloud access and a persistent Network
  Volume for model weights.
- A GitHub App, installed only on the repos this tooling should be able
  to push to, with its private key stored locally - never in this repo.
- A Cloudflare account with a named Tunnel configured for the pod's
  SSH/OpenHands UI ingress.

## Testing

Manual, for now: run `startup.sh`, confirm the pod comes up, confirm
`gh auth status` succeeds on the pod after the SSH push step, and
confirm the idle watchdog fires a safety commit and shuts the pod down
after the configured idle window with no SSH session open.

## License

Not yet decided - add one before the first tagged release if this repo
becomes public-facing beyond personal use.
