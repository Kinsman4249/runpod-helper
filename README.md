# runpod-helper

One-time-setup, mostly-hands-off tooling to run OpenHands (or a plain
chat frontend) against llama.cpp on a rented RunPod Secure Cloud GPU pod,
with the code disk destroyed every session and nothing long-lived stored
on RunPod's side.

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
- Frontend is a per-launch choice, not fixed: the pod image
  (`image/Dockerfile`) ships OpenHands, llama.cpp's own built-in chat UI,
  and Open WebUI side by side, but only ever runs one at a time - whichever
  `FRONTEND` you pick in the wizard - on port 3000, the one port forwarded
  through the Cloudflare tunnel. Switching frontends just means picking a
  different option on the next `./startup.sh --new` launch, no rebuild.

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

All five scripts (`startup.sh`, `onstart.sh`, `idle-watchdog.sh`,
`safety-commit.sh`, plus the `lib/` helpers `startup.sh` sources) are
written and pass `bash -n`, and `IMAGE_NAME` in `lib/launch.sh` now
points at a real image (`image/Dockerfile`, published by
`.github/workflows/build-image.yml`) instead of the old generic
placeholder. None of this has been run against a real pod yet, though -
the first live launch attempt caught the placeholder-image gap (no
`onstart.sh` baked in, so `cloudflared` never started) before the image
existed; that's now fixed, but the actual image hasn't been built/pushed
or exercised on a pod. The SSH idle-detection method in
`idle-watchdog.sh` also hasn't been verified against a real
cloudflared-proxied session yet - see the caveat comment at the top of
that file.

## Setup

First run: `./startup.sh` detects there's no local config yet and walks
you through a one-time setup wizard - installing the local tools it
needs, taking your RunPod API key, creating the model-weights volume,
and pausing at the right moments for the GitHub App and Cloudflare Tunnel
steps that have to happen on those sites directly.

Every run after that: GPU tier and model preset are picked once and
silently reused from then on (`--new` to change them), and everything
else - the pod, the tunnel, GitHub auth, shutdown - just happens.

See [PREREQUISITES.md](./PREREQUISITES.md) for the itemized list of what
needs to exist on RunPod, Cloudflare, and GitHub before that first run,
including datacenter privacy tradeoffs and GPU/volume sizing guidance
for the two model presets.

## Testing

Manual, for now: run `startup.sh`, confirm the pod comes up, confirm
`gh auth status` succeeds on the pod after the SSH push step, and
confirm the idle watchdog fires a safety commit and shuts the pod down
after the configured idle window with no SSH session open.

## License

Not yet decided - add one before the first tagged release if this repo
becomes public-facing beyond personal use.
