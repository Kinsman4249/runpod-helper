# Changelog

## Change history

### Unreleased

### Added
- New `cleanup-ssh-keys.sh` script: finds and removes orphaned `runpod-lab-ephemeral-*` SSH keys left in the RunPod account by launches whose `cleanup_ephemeral_ssh_key()` teardown never ran (crash, kill, Ctrl-C before the trap fires). Matches only this repo's ephemeral-key naming pattern, lists age before touching anything, supports `--dry-run`, `--older-than-hours N`, `--yes`, and the usual `--debug`/`--debug-quiet`. Confirmed live: found and removed 16 real orphaned keys (ages 40m-19h) from a real account.

## [2.6.0] - 2026-08-15

### Added

- New `sync-runpod-endpoint.sh` script (moved here from `vscodium-for-immutable`, where it lived first as a standalone consumer script) that writes a launch's baseURL, API key, and model name into Kilo Code's and opencode's configs inside vscodium-box. It reaches the config files through vscodium-box's private-home bind mount, so no podman exec or running container is needed. Alongside its original piped-stdin and `--log FILE` modes, it now also accepts `--base-url`, `--api-key`, and `--model` flags for syncing explicit values directly (all three required together).
- After a normal launch, `run_normal_launch` now asks (a y/N prompt, default N) whether to run `sync-runpod-endpoint.sh` automatically with that launch's endpoint, API key, and model; declining leaves the launch unaffected, and a sync failure only logs a warning rather than aborting the launch.

## [2.5.0] - 2026-08-15

### Added
- `--norotate` flag, a modifier for `--setup` (`startup.sh`, `lib/wizard.sh`): keeps the existing RunPod API key and HF token from the OS keyring instead of re-pasting them, and keeps the existing network volume instead of creating a new (billed) one, as long as the datacenter picked this run matches the one already on file. Picking a different datacenter still creates a new volume, since a volume is locked to its datacenter. Has no effect without `--setup`. Default `--setup` behavior (no `--norotate`) is unchanged - still re-prompts for both credentials and always creates a fresh volume.

## [2.4.3] - 2026-08-15

### Fixed
- Datacenter picker (`setup_datacenter`, `lib/wizard.sh`) crashed with "tag: unbound variable" while building the menu label for any GPU-stocked datacenter outside the 5/9/14 Eyes groupings - the common, recommended case (confirmed live against India, Iceland, Romania, and Czechia). Cause: the picker's internal row format was tab-delimited and re-parsed with `IFS=$'\t' read`, but bash treats tab as "IFS whitespace" and collapses runs of it, dropping empty fields the same way plain word-splitting does. The `tier` field is empty for every outside-Eyes datacenter, so whenever the following `gpus` field was non-empty, the empty `tier` field vanished and every field after it shifted left, leaving `tier` holding a GPU name that matched no `case` branch and `tag` unset. Rows are now delimited with the ASCII Unit Separator (`\x1f`) instead of a tab, which bash does not collapse, so empty fields round-trip correctly.

## [2.4.2] - 2026-08-15

### Fixed
- Datacenter picker (`setup_datacenter`, `lib/wizard.sh`) showed GPU stock from the `datacenter list` endpoint's own `gpuAvailability[]`, which can disagree with `gpu list`'s `dataCenterAvailability[]` - the endpoint `list_available_gpus()` (`lib/launch.sh`) actually filters on at GPU-pick time. Confirmed live: `datacenter list` reported RTX A5000 in stock at EU-SE-1 while `gpu list` reported none there, and six other (GPU, datacenter) pairs disagreed the same way. Since the datacenter choice is a one-way lock (the network volume is pinned to it), the wizard's menu now sources per-datacenter stock from `gpu list` instead, so it no longer advertises a card the GPU-selection step won't actually offer.

## [2.4.1] - 2026-08-15

### Added
- Launch script now outputs a fully-populated OpenCode provider configuration (ready to paste into ~/.config/opencode/opencode.json), eliminating manual substitution of the one-off baseURL and API key. Configuration schema verified against opencode.ai/config.json.

### Changed
- GOTCHAS.md expanded with three new documented behaviors: `runpodctl pod create` writes errors to stderr (not stdout), critical for capacity-error detection; datacenter `.location` field is generic "Europe" for most EU datacenters (read the id's country-code token instead); and clarification on how the new stderr capture enables the capacity-failure retry logic.

## [2.4.0] - 2026-08-15

### Added
- `custom-gguf` model option (`lib/gguf.sh`, wired into `pick_preset_and_gpu` in the new `lib/select.sh`): paste any Hugging Face GGUF repo id and pick a quant from what it actually publishes. Quant list and byte sizes come live from the HF tree API (`huggingface.co/api/models/<repo>/tree/main`, `lfs.size` per file, `mmproj` sidecars skipped, multi-part quants summed), sorted smallest-first; quants the repo README flags "recommended" (mradermacher/bartowski layouts) are marked as such. Serves via llama.cpp (`<repo>:<quant>` as `--hf-repo`), computes an approximate GPU VRAM floor (weights + a small KV/compute cushion), and auto-sizes the network volume from the chosen quant's on-disk size.
- Datacenter picker (`setup_datacenter`, `lib/wizard.sh`) now groups datacenters by the Five/Nine/Fourteen Eyes intelligence-sharing alliances: those outside all three are listed first (privacy-preferred, shown in green), Eyes members follow but stay selectable. Classification is by country - `.location` when specific, else the datacenter id's country-code token - so US-DE-1 correctly reads as United States rather than Germany. Verified against all 49 live datacenters.

### Changed
- Preset menu labels (`PRESET_TABLE`, `lib/launch.sh`) trimmed to just model, quant, approximate size, the VRAM floor, and whether that floor is "tested live" or "napkin math" (a conservative estimate). The detailed floor derivations moved into a comment above the table.
- Split `lib/launch.sh` (was over 700 lines) under 500: launch-time model/GPU/volume selection moved to a new `lib/select.sh`, and the custom-GGUF enumeration lives in `lib/gguf.sh`. Pod creation, readiness polling, and the preset table stay in `lib/launch.sh`. `startup.sh` and `e2e-test.sh` source the new files; no behavior change for existing presets.

## [2.3.0] - 2026-08-15

### Added
- Capacity-failure fallback on pod create: RunPod can reject a `pod create` with a graphql "This machine does not have the resources to deploy your pod. Please try a different machine" error even when `runpodctl gpu list` shows that GPU in stock (stock is datacenter-wide; a specific host can still be full). `create_pod()` (`lib/launch.sh`) now captures runpodctl's stderr (where that JSON error actually lands - previously the `die` message's "Raw output:" was blank because it only had stdout), classifies capacity/placement errors as retryable, and returns a distinct status instead of dying. `startup.sh` then offers the other cards currently meeting the model's VRAM floor (`offer_alternate_gpu()`) to retry with; `e2e-test.sh` auto-advances cheapest-first through every candidate card. The model's VRAM floor is now saved to `~/.runpod-lab/last-session` (`MIN_VRAM`) so a reused session can still re-list correctly.
- `--extra-args "ARGS"` (`startup.sh` and `e2e-test.sh`): appends arbitrary flags verbatim to the engine's serve command (`vllm serve` or `llama-server`), for a model/quant needing a knob the script doesn't expose (e.g. vLLM `--rope-scaling`, llama.cpp `--split-mode`). Applied after the preset's own `MODEL_EXTRA_ARGS` so a user value wins on last-one-wins flags; space-separated (a single flag value can't contain spaces); not applied to the prewarm pod.

## [2.2.0] - 2026-08-15

### Added
- New preset `qwen3.5-40b-deckard-gguf-40gb` (`lib/launch.sh`): same GGUF weights as `qwen3.5-40b-deckard-gguf` but capped at 196608 tokens (~192K) of context instead of the model's native 262144 max, sized to fit a 40GB VRAM floor using the same KV-cache formula as the existing preset's own `min_vram` calc.
- `startup.sh` now offers to prewarm before a real GPU launch when there is no local record that the chosen preset's weights are already cached on the attached network volume (`is_marked_prewarmed`/`mark_prewarmed`, `lib/prewarm.sh`), instead of requiring the operator to remember `--prewarm` up front. The record is written after either a successful `--prewarm` run or a successful real launch, and lives at `~/.runpod-lab/prewarmed`.
- `GOTCHAS.md`: non-obvious RunPod/dependency behavior confirmed live while building this repo (SSH-over-proxy's real address format, RunPod CPU pod sizing, EU-RO-1 network-volume tiers, vLLM's `--quantization auto` rejection against a repo with its own `quantization_method`, and more) - `README.md` now points to it.

### Fixed
- `qwen3.5-40b-deckard-gguf` confirmed live end-to-end for the first time: after prewarming its GGUF onto the network volume, pod-create to llamacpp-ready took 114s and `GET /v1/models` passed.
- `wait_for_vllm_ready()` (`lib/launch.sh`) now returns 1 on a timeout instead of always reporting success, needed so the new prewarm-offer logic can tell a genuine ready state apart from a timeout before recording a preset as cached. Its three existing call sites (`startup.sh` via `run_normal_launch`, `e2e-test.sh`, `lib/prewarm.sh`) were bare calls under `set -euo pipefail` and would have aborted their script on any timeout without an added `|| true` at each - fixed alongside the return-value change so this ships without introducing that regression.

## [2.1.0] - 2026-08-14

### Added
- `--prewarm` (`startup.sh`) and `--prewarm-only` (`e2e-test.sh`), backed by new `lib/prewarm.sh`: downloads a preset's weights onto the network volume via a cheap CPU pod (2 vCPU/4GB, ~$0.06/hr - RunPod gives no way to size a CPU pod via `runpodctl`, confirmed live) instead of paying the real GPU's hourly rate to sit through the download. `--prewarm-only` skips creating a GPU pod entirely. Reintroduces the idea behind the pre-2.0.0 `--prewarm` flag removed alongside the custom image, rebuilt from scratch against the bare official images: for vLLM presets, a small Python image runs `hf download <repo>` into `HF_HOME` (the same standard HF Hub cache layout vLLM itself reads later); for llama.cpp presets, the real `ghcr.io/ggml-org/llama.cpp:server` (CPU-only) binary runs with `--n-gpu-layers 0`, guaranteeing the `LLAMA_CACHE` it writes is something a later real launch can actually reuse. Neither path puts `RUNPOD_API_KEY` on the prewarm pod - since a RunPod pod does not stop on its own when its process exits (confirmed live: it crash-loops instead), the prewarm pod instead serves a plain HTTP 200/503 on port 8000 and the existing `wait_for_vllm_ready()` polls it exactly like a real launch, so the local machine (not the pod) decides when to tear it down. Verified live end-to-end: prewarming `qwen3-coder-30b-moe` then launching it for real came up in 146s (pod-create to ready), against the multi-minute wait a fresh ~17GB download would otherwise cost at the GPU's hourly rate.

### Fixed
- `qwen3-coder-30b-moe` preset (`lib/launch.sh`) was pinned to `--quantization auto`, but `stelterlab/Qwen3-Coder-30B-A3B-Instruct-AWQ`'s own `config.json` declares `compressed-tensors` explicitly - vLLM 0.27.1 rejects `auto` against a repo that already states a method (same failure class as `qwen3.6-27b-awq-mtp`, see 2.0.0 below), so the pod boot-looped on every launch attempt until this preset had an actual real GPU launch tested against it. Now pins `--quantization compressed-tensors`.

## [2.0.0] - 2026-08-14

### Added
- llama.cpp as a second serving engine alongside vLLM: `PRESET_TABLE` (`lib/launch.sh`) gained an `engine` column (`vllm` or `llamacpp`) and a `LLAMACPP_IMAGE_NAME` pointing at `ggml-org/llama.cpp:server-cuda`. `create_pod()` branches on `ENGINE` to build the right `--docker-args` (`--hf-repo`/`--alias`/`--ctx-size`/`--n-gpu-layers 999`/`--metrics` for llamacpp vs. `--model`/`--served-model-name`/`--max-model-len`/`--quantization` for vLLM) and env (`LLAMA_CACHE` vs. `HF_HOME` on the network volume). New preset `qwen3.5-40b-deckard-gguf` (`mradermacher/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking-GGUF:Q5_K_S`, 256K context) is the first to use it, verified live through RunPod's proxy for both `/v1/models` and `/v1/chat/completions`.
- New preset `qwen3.6-27b-awq-mtp` (`shawnw3i/Qwen3.6-27B-AWQ-MTP`), verified live end-to-end on a 24GB L4: AWQ weights (~18GB), `--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager`, confirmed serving real completions through the fixed proxy URL. Unlike the other AWQ presets it pins `--quantization awq` rather than `auto`, since vLLM rejects `auto` against a repo whose `config.json` already declares an explicit quantization method.
- `PRESET_TABLE` gained an `extra_args` column (space-separated per-preset `vllm serve`/`llama-server` flags, `-` for none), added because hybrid Gated-DeltaNet/full-attention models (the Qwen3.5/3.6 architecture) need extra fixed memory for recurrent/mamba state on top of normal KV cache - confirmed live when the default `--gpu-memory-utilization 0.9` left only 0.39GiB free after AWQ weights loaded on a 24GB L4, crashing `_initialize_kv_caches`.
- `resolve_pod_ssh_proxy_host()` (`lib/common.sh`): resolves a pod's SSH-over-proxy target via RunPod's GraphQL API (`machine.podHostId`), since no `runpodctl` subcommand surfaces it.
- Optional Hugging Face token setup: a new wizard step (`setup_hf_token()`, `lib/wizard.sh`) stores an HF token in the OS keyring, and `load_secrets()` (`lib/common.sh`) loads it into `HF_TOKEN`, passed to the pod's env when set. Not required for any preset today (all public/ungated repos), but authenticated `hf_xet` downloads are documented as faster/more reliable than anonymous ones, and it is needed for any gated/private repo added later.

### Changed
- Pods now run the official `vllm/vllm-openai:latest` or `ggml-org/llama.cpp:server-cuda` images directly instead of a custom-built pod image, with model/runtime settings passed as `--docker-args` appended to each image's fixed entrypoint rather than `--env` vars a custom wrapper script used to translate.
- `create_pod()` now passes `--ports "8000/http"` to `runpodctl pod create`. Without it, RunPod's proxy 404s on `<pod-id>-8000.proxy.runpod.net` forever even once the engine is fully healthy inside the container - confirmed live: `curl localhost:8000/health` inside the pod returned 200 while the external proxy 404'd for 10+ minutes straight, until `--ports` was added, after which the same URL went 404 -> 502 (booting) -> 200 (ready) normally. This is very likely the real cause of most prior "pod launch failed" reports, independent of model or GPU choice.
- Diagnostics now reach the pod through RunPod's own SSH-over-proxy (`resolve_pod_ssh_proxy_host()`, `lib/common.sh`) instead of direct-TCP SSH or a Cloudflare Tunnel - the bare official images never start an `sshd`, so 22/tcp is never listening. This execs into the container on RunPod's own infra side and needs no `sshd`, but requires a real PTY and rejects a piped command, so it is diagnostics-only, not scriptable.
- `idle-watchdog.sh` now runs on the operator's own machine (launched detached by the new `maybe_start_idle_watchdog()` in `lib/launch.sh`) instead of on the pod, since the bare images have no room to host a second background process. It polls the engine's own `/metrics` through RunPod's proxy (with the bearer token) instead of `localhost` on the pod, is engine-aware (vLLM's `vllm:request_success_total`/`vllm:num_requests_running` vs. llama.cpp's `llamacpp:tokens_predicted_total`/`llamacpp:requests_processing`, per llama.cpp's server docs), and calls `runpodctl_t` directly instead of a bare `runpodctl` call baked into the container. `RUNPOD_API_KEY` no longer needs to be placed on the pod's `--env` at all, since nothing running on the pod needs to call the RunPod API to self-terminate anymore - a real reduction in credential exposure, not just incidental to the image removal.
- `--no-logging` is now engine-generic: it maps to `--disable-log-stats --disable-uvicorn-access-log` for vLLM presets or `--log-disable` for llama.cpp presets, instead of a single vLLM-specific pair of flags.
- `IMAGE_NAME` (`lib/launch.sh`) changed from the custom `ghcr.io/kinsman4249/runpod-helper-image:latest` to `vllm/vllm-openai:latest`.
- `qwen3.5-40b-deckard`'s `min_vram` and default context were raised to 80GB and 262144 (from 48GB/8192) after confirming its hybrid Gated-DeltaNet/full-attention architecture needs substantially more headroom than a dense model at the same context length; it also picked up the same `--gpu-memory-utilization 0.95 --kv-cache-dtype fp8 --enforce-eager` extra args as `qwen3.6-27b-awq-mtp`.
- Setup wizard (`lib/wizard.sh`) gained the optional HF-token step described above between the RunPod API key and datacenter steps.
- `README.md` and `PREREQUISITES.md` rewritten to describe the official-image, RunPod-proxy-only setup and endpoint access flow, including llama.cpp presets.

### Removed
- The custom pod image end to end: `image/Dockerfile`, `image/entrypoint.sh`, and `.github/workflows/build-image.yml`.
- The prewarm workflow (`maybe_run_prewarm()` and the `--prewarm`/`--prewarm-only` flags on `startup.sh`) - it depended entirely on the custom entrypoint's `PREWARM_ONLY` branch (download weights on a cheap CPU pod, then self-terminate instead of exec-ing into the server), which no longer exists once the custom image is gone. The official images' fixed entrypoints have no way to download-without-serving, so this is no longer possible to implement the same way.
- Cloudflare Tunnel integration end to end: `cloudflared` install/download, tunnel-token validation and extraction, the Cloudflare Tunnel wizard step, and tunnel process/log handling.
- `sshd` on the pod, and with it `lock_ssh_to_first_client()`'s SSH IP-pinning and `resolve_pod_ssh_endpoint()`'s direct-TCP-22 readiness check - the official images never start an `sshd`, so 22/tcp is never listening.
- `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_SSH_HOSTNAME`, and `CLOUDFLARE_API_HOSTNAME` from the config file, keyring, and pod `--env` payload.

## [1.0.0] - 2026-08-13

### Added
- Ephemeral, per-launch SSH keypair (`setup_ephemeral_ssh_key()` / `cleanup_ephemeral_ssh_key()` in `lib/common.sh`): generated fresh for every pod, registered with RunPod via `runpodctl ssh add-key`, and revoked again on teardown, replacing the old single long-lived dedicated keypair.
- `resolve_pod_ssh_endpoint()` (`lib/common.sh`) to look up a pod's direct public SSH IP/port via `runpodctl ssh info`, used by `wait_for_pod_ready()`, `e2e-test.sh`, and the final launch summary.
- SSH IP-pinning on the pod image: `lock_ssh_to_first_client()` in `image/entrypoint.sh` locks port 22 to whichever IP connects first, best-effort and not yet confirmed against RunPod's proxy behavior.
- One-off vLLM API key generated per launch in `create_pod()` (`lib/launch.sh`) and printed once in the launch summary, instead of being generated once at setup and stored.
- `--gpu-id` flag on `e2e-test.sh` to manually pick a GPU instead of always auto-selecting the cheapest one meeting the VRAM floor.

### Changed
- Pods are now reached directly through RunPod's own per-pod SSH (`22/tcp`) and HTTP proxy (`https://<pod-id>-8000.proxy.runpod.net`) instead of a Cloudflare Tunnel with a stable custom hostname.
- Setup wizard (`lib/wizard.sh`) cut from 8 steps to 4: dropped the dedicated-SSH-key, vLLM-API-key, Cloudflare Tunnel, and local `~/.ssh/config` steps, since those are now either automatic per launch or unnecessary.
- `load_secrets()` (`lib/common.sh`) now clears out any leftover `VLLM_API_KEY`/`CLOUDFLARE_TUNNEL_TOKEN` keyring entries and related config-file lines from a pre-pivot install on the next run, alongside its existing `RUNPOD_API_KEY` plaintext-to-keyring migration.
- `README.md` and `PREREQUISITES.md` rewritten to describe the RunPod-only setup and endpoint access flow.

### Removed
- Cloudflare Tunnel integration end to end: `cloudflared` install/download (`lib/wizard.sh`, `image/Dockerfile`), the tunnel-token validation and extraction functions, the Cloudflare Tunnel wizard step, and the tunnel process/log handling in `image/entrypoint.sh`.
- Persistent dedicated SSH keypair setup and the managed `Host runpod-lab` block it used to write to `~/.ssh/config`.
- `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_SSH_HOSTNAME`, and `CLOUDFLARE_API_HOSTNAME` from the config file, keyring, and pod `--env` payload.

## [0.10.0] - 2026-08-13

### Added
- Added `--storage-mode container-disk` as an alternative to the default `network-volume` mode, using a larger local per-pod disk instead of a persistent volume - faster with no network-mount overhead, but nothing survives pod deletion so every fresh launch re-downloads the model; `e2e-test.sh --storage-mode` times both modes for direct comparison.
- Added `--no-logging` (`DISABLE_LOGGING=1`) to disable vLLM's request-stats/access logging and cloudflared's connection log on the pod.
- Added `--debug`, tracing script execution to the terminal and a timestamped log file under `~/.runpod-lab/logs`, with known secret values (API keys, tokens, auth headers) redacted before they reach either destination.
- Added `--debug-quiet`, writing the same trace to the log file only via a dedicated file descriptor, keeping the console free of trace noise during interactive `--setup` runs.
- Extended `--rotate` to optionally regenerate the dedicated SSH keypair, registering the new public key with RunPod and removing the old one by fingerprint.

### Changed
- Moved `RUNPOD_API_KEY`, `VLLM_API_KEY`, and `CLOUDFLARE_TUNNEL_TOKEN` out of the plaintext config file and into the OS keyring (`secret-tool`/libsecret), with automatic one-time migration of any existing plaintext config.

### Fixed
- Fixed `runpodctl` calls having no timeout, causing indefinite hangs on a stuck API request; all call sites now route through a 20-second timeout wrapper.
- Fixed `run_step_sequence()` silently aborting the wizard after its first step, caused by a post-increment loop-counter bug interacting badly with `set -e`.
- Fixed `prompt_text()` crashing with an unbound-variable error when a caller's own result variable happened to share the function's internal variable name (`reply`).

### 0.9.0 - vLLM pivot released, non-interactive SSH, an e2e smoke test, and a sixth (FP8) preset

1. First release of the architecture pivot away from the custom llama.cpp + OpenHands pod image (committed earlier but never tagged): pods now run vLLM's own official `vllm/vllm-openai` image, serving an OpenAI-compatible endpoint directly instead of routing through a chosen frontend (OpenHands / llama.cpp's built-in UI / Open WebUI, all removed, along with the shared port-3000 setup they needed). The GitHub App / git-identity / safety-commit machinery is gone entirely - `onstart.sh`, `safety-commit.sh`, and the wizard's GitHub App, git-identity, and `gh`-install steps are all removed, so nothing on the pod edits or commits code anymore and no GitHub credential of any kind reaches the pod or its stored config. `image/presets.conf`'s GGUF/llama-server preset format was replaced by `PRESET_TABLE` in `lib/launch.sh`. `idle-watchdog.sh` now detects activity by polling vLLM's own `/metrics` endpoint (`vllm:request_success_total`, `vllm:num_requests_running`) instead of counting active SSH sessions, since normal use now hits the API directly and often opens no SSH session at all. The Cloudflare Access policy now covers only the SSH hostname; the API hostname is deliberately left out of Access and gated by vLLM's own `--api-key` bearer token instead, since most OpenAI-compatible client tools can send a bearer token but can't add Access's custom headers. `CONTAINER_DISK_GB` raised from 25GB to 40GB for the heavier vLLM base image (full CUDA/PyTorch/vLLM stack); model weights now live under `HF_HOME` on the network volume, so a second launch of the same preset skips re-downloading.
2. Fixed `ssh runpod-lab` needing a passphrase typed in, which silently broke any non-interactive use (a script, an e2e test, an agent session with no way to answer the prompt) even though the readiness check in `wait_for_pod_ready()` (`ssh -o BatchMode=yes ...`) looked non-interactive already - `BatchMode=yes` only suppresses *that one call's own* prompts, not a real interactive `ssh runpod-lab` run elsewhere. `setup_ssh_key()` (`lib/wizard.sh`) now generates and registers a dedicated, passphrase-free ed25519 keypair (`~/.runpod-lab/ssh_key`) instead of requiring and reusing the user's own default identity key - deliberately scoped this way since these pods are ephemeral (idle-watchdog.sh auto-terminates them) and SSH access to them is diagnostics-only, never how the endpoint is actually used, so there's little a passphrase would meaningfully protect here beyond what's already sitting in `$CONFIG_FILE` (chmod 600, same directory).
3. Added `e2e-test.sh`: a non-interactive smoke test that creates a real pod (cheapest GPU meeting a preset's VRAM floor), waits for it, confirms the OpenAI endpoint actually serves a completion and that SSH reaches it with sshd/cloudflared/idle-watchdog/vllm all running, then always tears the pod down - closing the long-standing gap (see `handoff.md`) where every previous end-to-end attempt was manual, ad hoc, and got derailed partway through. `--check-idle-shutdown` additionally waits out the idle window and confirms `idle-watchdog.sh` self-terminates the pod on its own.
4. Added a sixth model preset, `qwen3.5-40b-deckard` (`DavidAU/Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking`), served via vLLM's own on-the-fly `--quantization fp8` against the repo's bf16 weights rather than a separately-hosted quant repo - the model's only pre-quantized variants are GGUF (llama.cpp-oriented, and this repo dropped llama.cpp for vLLM entirely per item 1) or exotic formats (MLX, exl3, NVFP4) vLLM doesn't load. This is also the first preset needing a `--quantization` flag at all, so `PRESET_TABLE` (`lib/launch.sh`) gained a `quantization` column (`auto` for the existing AWQ presets, matching vLLM's own default so the flag is now unconditional) and the value flows through the session file, the pod's `--env`, and into `entrypoint.sh`'s `vllm serve` invocation.
5. Extracted the GPU-availability fetch/filter/sort `jq` query out of `pick_preset_and_gpu()`'s interactive menu step into a standalone `list_available_gpus()` (`lib/launch.sh`), so `e2e-test.sh`'s non-interactive "pick the cheapest GPU" logic (item 3) reuses the exact same query instead of a second hand-rolled copy that could silently drift from it.

### 0.8.0 - Prewarm loop hardening and a diagnostics-only inference skip

1. Fixed `maybe_run_prewarm()`'s wait loop wrongly marking a volume as prewarmed when the CPU pod never actually finished: a pod that fails to schedule or pull its image also vanishes fast, and the loop treated any disappearance as success. Added a minimum elapsed-time floor (`min_wait`) before trusting "pod gone" as a real finish, confirmed live when a prewarm pod 404'd within ~30s and was wrongly marked prewarmed with nothing installed.
2. Fixed the completion check itself matching the wrong field: it grepped raw `pod get` JSON for the substring `"error"`, but RunPod's response nests `{"ssh": {"error": "pod not ready", ...}}` for as long as SSH isn't up yet, unrelated to whether the pod actually succeeded. Confirmed live: a pod stuck at `uptimeSeconds: 0` for 18+ minutes (never actually coming up) tripped this on the nested field alone and would have been misread as finished once past the min-wait floor. Now checks for the pod object's actual absence (no `.desiredStatus` at all) or a non-`RUNNING` status instead of string-matching anywhere in the blob.
3. Fixed `llama-server` failing to start on every normal (non-prewarm) launch: the base image (`ggml-org/llama.cpp:server-cuda`) sets `ENTRYPOINT ["/app/llama-server"]` and invokes it by absolute path without ever adding `/app` to `$PATH`, so `entrypoint.sh`'s own bare `nohup llama-server ...` PATH lookup failed instantly on every boot. This is the first release where that code path has actually been exercised end to end live. Fixed by using the absolute path.
4. Added a `SKIP_INFERENCE=1` escape hatch to `entrypoint.sh` for diagnosing or benchmarking a pod's filesystem/toolchain without loading the model: a 17-20GB model on a CPU pod's default 4GB RAM OOMs the whole container almost immediately, confirmed live when a CPU benchmark pod crash-looped repeatedly right after the `llama-server` absolute-path fix (item 3) made it actually start trying to load the model. Not used by any normal launch path in `lib/launch.sh` - GPU pods always have enough VRAM/RAM and should never set it.
5. Fixed `maybe_run_prewarm()`'s poll loop dying silently instead of reaching its own error handling: once a pod vanished, `runpodctl pod get` exits non-zero, and under this script's `set -e` that failing command-substitution assignment killed the whole script right there - before the `jq` check meant to handle exactly that case ever ran. Confirmed live: a `--prewarm-only` run exited 0 (masked further by the `| tee` pipe used to capture its output) with no warning or success message at all, immediately after a stuck pod was deleted out from under it.
6. Fixed a second false-positive prewarm marker, found immediately after fixing item 5: with the silent death gone, the very next run proved a pod that sat at `uptimeSeconds: 0` its entire life (never booting far enough to run `entrypoint.sh` at all) could still get marked prewarmed once `min_wait` elapsed and it disappeared, because a stuck-then-torn-down pod and a genuinely finished one look identical from `pod get` alone. Now tracks whether `uptimeSeconds > 0` was ever observed during the poll loop and refuses to mark the volume prewarmed if not, regardless of how long it waited.
7. Diagnosed (not a code fix): repeated live attempts to prewarm in `EUR-IS-1` all got stuck at `uptimeSeconds: 0` with `ssh.error: "pod not ready"` for 20+ minutes. Ruled out this repo's own image/entrypoint/cloudflared/model-download as the cause by reproducing the identical failure with a minimal, unrelated public image (`lscr.io/linuxserver/openssh-server`) across two different datacenters (`EUR-IS-1` and `EU-RO-1`) - pointing at RunPod's own SSH-readiness path for this account, not this codebase. Filed with RunPod support; no code change possible on our side.

### 0.7.0 - CPU-pod prewarm, a minimal GPU image, and several live-tested boot fixes

1. Added a "prewarm" workflow to avoid paying GPU rates for install/download time: `image/entrypoint.sh`'s new `ensure_tools()` installs gh, cloudflared, uv, and the uv-managed OpenHands/Open WebUI Python environments onto the network volume (`/workspace/persistent`) at runtime instead of baking them into the image, idempotently (skipped if already present). `lib/launch.sh`'s new `maybe_run_prewarm()` spins up a cheap `--compute-type CPU` pod (about $0.06/hr, vs. GPU rates) with `PREWARM_ONLY=1` to do that installation plus the model download, then the pod stops and deletes itself once done (see item 4 below for why that's not optional) and the volume is marked prewarmed in config so future launches skip straight to the GPU pod. `startup.sh` gained `--prewarm` (force a re-run, then continue to a normal launch) and `--prewarm-only` (force a re-run and stop there - "warm the volume now, launch later"). `image/Dockerfile` correspondingly dropped python3/pip/uv/openhands/open-webui/gh/cloudflared from its build steps entirely - down to just the CUDA/llama.cpp base plus curl/ca-certificates/git, cutting the published image to about 2.5GB.
2. Fixed the pod never actually starting at all: the base image (`ghcr.io/ggml-org/llama.cpp:server-cuda`) sets `ENTRYPOINT ["/app/llama-server"]`, which `image/Dockerfile`'s plain `CMD` never overrode - CMD only supplies default arguments to an inherited ENTRYPOINT, so every pod was actually running `llama-server /opt/runpod-lab/entrypoint.sh`, which `llama-server` rejected as a bad flag on every restart (`error: invalid argument`, looping forever). Fixed by using `ENTRYPOINT` instead of `CMD` for entrypoint.sh.
3. Fixed SSH never coming up on any pod, GPU or CPU: RunPod does not start `sshd` for a custom image on its own (confirmed against its own docs) - nothing in this repo ever did either, so `wait_for_pod_ready()`'s SSH check and `push_github_token()` would have hung or failed on every real launch, independent of anything else in this release. `openssh-server` is now installed at build time and started by `entrypoint.sh` using RunPod's auto-injected `$PUBLIC_KEY`. A first attempt using a raw `/usr/sbin/sshd` call crash-looped the entire container (a PAM issue in the minimal apt install made it exit non-zero in the foreground, which killed entrypoint.sh as PID 1 under `set -e`, and RunPod silently restarted the whole container forever) - fixed by switching to `service ssh start` (RunPod's own documented snippet) and making it non-fatal.
4. Fixed the idle-shutdown safety mechanism being silently broken: `idle-watchdog.sh`'s self stop/delete calls `runpodctl`, but nothing ever installed it inside the pod image - this would have failed on the very first idle timeout, with the pod just running (and billing) forever. `runpodctl` is now installed at build time. Also discovered live: RunPod restarts a pod's container on *any* exit, including a clean `exit 0` - this is also why `maybe_run_prewarm()`'s prewarm pods now self-terminate via `runpodctl pod stop/delete` from inside `entrypoint.sh` (using RunPod's auto-injected `$RUNPOD_POD_ID`) rather than relying on exiting cleanly, and why its completion check watches for the `pod get` call itself starting to error (pod gone) instead of status text that would otherwise say "running" forever.
5. Fixed `maybe_run_prewarm()`'s own CPU pod creation, caught by a live test: it used `--computeType`/`--vcpu`/`--mem`, flags that belong to the deprecated top-level `runpodctl create pod` alias, not the `pod create` subcommand this codebase uses everywhere else. Real flag is `--compute-type`, with no vcpu/mem override available (defaults to 2 vcpu/4GB). Also fixed a `set -e`/trap interaction that made a fully successful prewarm run still exit the whole script with status 1, because the cleanup trap's own stop/delete calls (expected to fail once the pod had already self-terminated) weren't error-suppressed.

### 0.6.1 - Pod image publishing fix and credential-handling hardening

1. Fixed `.github/workflows/build-image.yml` failing to publish the pod image at all: it tagged the image as `ghcr.io/${{ github.repository_owner }}/runpod-helper-image`, but Docker rejects uppercase repository names and `github.repository_owner` resolves to `Kinsman4249`, so every build errored out before pushing anything - the `latest` tag never existed on GHCR, which is why a live pod launch failed with `IMAGE_AUTH_ERROR` (nothing to pull, not a credentials problem). Fixed by lowercasing the owner in a shell step via `$GITHUB_ENV` before the build step (GitHub Actions expressions have no built-in case-conversion function, so this can't be done inline in `env:`). Confirmed fixed: the workflow now completes successfully and `ghcr.io/kinsman4249/runpod-helper-image:latest` is live and anonymously pullable.
2. Fixed `validate_cloudflare_tunnel_token()` (`lib/common.sh`) silently timing out regardless of whether the pasted token was actually valid: `--loglevel`/`--logfile` are `cloudflared tunnel` command options and only take effect when placed before the `run` subcommand, so putting them after `run` dropped them and left the validation logfile permanently empty. Also, `setup_cloudflare_tunnel()` and `rotate_credentials()` now accept pasting Cloudflare's whole install/run command (not just the bare token) via a new `extract_cloudflare_token()` helper, since that's what the Cloudflare dashboard shows and it's easy to paste the full line by habit.
3. Hardened credential file handling: `write_config()` now writes each config value with `printf '%q'` quoting instead of raw shell heredoc interpolation, so a credential containing spaces or shell metacharacters can no longer corrupt `~/.runpod-lab/config` in a way that breaks `source`-ing it later. Added a `secure_file()` helper (`lib/common.sh`) that tightens any sensitive file (SSH key, GitHub App `.pem`, `~/.runpod/config.toml`) to mode 600 and warns if it wasn't already, run on every `startup.sh` invocation - not just at setup - since tools we don't fully control the creation of (`runpodctl`, browser downloads) can leave these world/group-readable. Also fixed `startup.sh` not exporting `RUNPOD_API_KEY` after sourcing the config file, which meant `runpodctl` (a separate process) was silently falling back to whatever key was cached in `~/.runpod/config.toml` instead of the one just loaded.

### 0.6.0 - Credential validation and automated pod/volume creation

1. Added automated credential validation for RunPod API key and Cloudflare tunnel token: new `validate_runpod_api_key()` and `validate_cloudflare_tunnel_token()` functions run at wizard setup and before normal launch, catching rotated/revoked credentials before any billed operations (network volume or pod creation) occur. Cloudflare validation briefly runs the tunnel connector and watches the log for success or rejection signatures rather than simply checking shape, making it robust to future API changes.
2. Automated pod creation and network volume creation: replaced manual copy-paste workflows for pod IDs and volume IDs with automatic JSON response parsing using `jq`, eliminating user input errors and reducing friction. The `create_network_volume()` helper extracts volume ID from the response and prints a formatted summary; pod creation extraction filters out the response's `env` array to prevent credentials from being logged to the terminal.
3. Added `--rotate` flag to `startup.sh` and a new `rotate_credentials()` function to re-authenticate RunPod API key and Cloudflare tunnel token without re-running the entire setup wizard, useful when credentials rotate outside this repo (e.g. via the RunPod or Cloudflare dashboard). Early validation in the normal launch flow ensures rotated credentials are caught immediately instead of failing at pod/volume creation time.

### 0.5.0 - Pod image and multi-frontend support

1. Added the complete pod image (`image/Dockerfile`) replacing the placeholder RunPod base image: builds on `ghcr.io/ggml-org/llama.cpp:server-cuda` (which ships a pre-compiled CUDA-accelerated llama-server), adds OpenHands, llama.cpp's built-in web UI, and Open WebUI as three mutually exclusive frontend options, plus `gh` CLI and `cloudflared` for SSH tunneling and idle detection. Image is built by `../.github/workflows/build-image.yml` and published to `ghcr.io/kinsman4249/runpod-helper-image:latest` on every push to `image/**`.
2. Added frontend selection as a third wizard step in `pick_preset_and_gpu()`: users now choose between three frontends (OpenHands, llama.cpp's built-in UI, or Open WebUI) after picking their model preset and GPU, all served on port 3000 (the sole port forwarded through the Cloudflare tunnel). Frontend choice is saved to the session cache and carried to the pod as a `FRONTEND` environment variable.
3. Added `image/entrypoint.sh` (the container CMD) to download model weights on first boot, start llama-server with appropriate flags per preset, then launch the chosen frontend with LLM connection details baked in, and finally hand off to `onstart.sh` for tunnel and idle-watchdog startup.

### 0.4.0 - Wizard step back-navigation

1. Added back-out capability to all wizard steps: new `prompt_text()` function in `lib/common.sh` provides free-text input prompts with a safeword (`:b`) that returns 1, allowing the caller to re-run the previous prompt or step. Distinct from menu back-navigation (`'b'` in numbered menus) to avoid conflicts with legitimate text input (e.g., naming a volume "b").
2. Added `run_step_sequence()` function in `lib/common.sh` to manage ordered wizard steps (2-9) as a back-able sequence: any step can return 1 to hand control back to the previous step instead of the entire wizard needing to restart from the beginning. Steps navigate between their own internal fields using local `field` variables, only returning 1 to request rollback to the prior step.
3. Refactored all wizard setup functions (`setup_runpod_api_key`, `setup_datacenter`, `setup_network_volume`, `setup_github_app`, `setup_cloudflare_tunnel`, `setup_git_identity`) to use `prompt_text()` and local field-navigation loops, providing consistent back-out behavior across multi-field steps. Users can now edit earlier fields (e.g., go back from volume size to volume name, or from App ID to the prior wizard step) instead of abandoning the entire setup.

### 0.3.0 - Menu UX refinements and storage resilience

1. Refactored menu helper (`select_from_menu()` in `lib/common.sh`) to support back-navigation: typing `'b'` on any numbered menu (preset, GPU, datacenter) returns to the previous step instead of committing the choice. Restructured preset/GPU selection flow in `lib/launch.sh` as a two-step loop, allowing users to change their preset after seeing available GPUs without re-running the entire script.
2. Fixed session cache file corruption issue: GPU IDs and preset names containing spaces are now properly shell-quoted (using `printf '%q'` format) when saved to `~/.runpod-lab/last-session`, preventing `command not found` errors on the next run when the cache is sourced.
3. Added network volume resilience: new `ensure_network_volume()` function in `lib/launch.sh` runs at startup, verifies the configured volume still exists via `runpodctl network-volume get`, and if deleted (e.g. overnight cost-saving), prompts to create a replacement in the same datacenter (required for pod attachment) and persists the new ID to the config file.

### 0.2.0 - Wizard UX and validation enhancements

1. Enhanced PREREQUISITES.md with detailed guidance on datacenter selection tradeoffs (jurisdiction/privacy vs. latency), GPU tier sizing for each model preset (4-bit/8-bit/fp16), and network volume sizing recommendations based on model precision and storage needs. Updated README.md to reference this expanded guidance.
2. Refactored GPU and datacenter selection (`lib/launch.sh`, `lib/wizard.sh`) to use a common menu-driven interface (`select_from_menu()` helper in `lib/common.sh`) with smart filtering: GPU selection now auto-filters by VRAM requirement and datacenter availability, preventing invalid picks instead of warning after the fact.
3. Enhanced wizard step-by-step guidance (particularly GitHub App and Cloudflare Tunnel setup) with significantly more detailed substeps, field-by-field instructions, and links to configuration checks, reducing ambiguity and setup errors on first run.

### 0.1.0 - Initial release

1. Added five core lifecycle scripts for pod setup and runtime: `startup.sh`
   (pod creation and GitHub auth setup), `onstart.sh` (pod boot tasks
   including Cloudflare Tunnel and idle watchdog startup), `idle-watchdog.sh`
   (idle session detection and pod lifecycle management), and
   `safety-commit.sh` (emergency commit to a safety branch before shutdown).
2. Added setup wizard infrastructure (`lib/wizard.sh`, with `lib/common.sh`
   and `lib/launch.sh` helpers) to guide first-time users through RunPod API
   key setup, SSH key registration, model volume creation, and GitHub App
   integration - all steps required before the first pod launch.
3. Fixed deprecated `runpodctl config --apiKey` call in wizard by switching
   to environment variable export (`RUNPOD_API_KEY`), matching the current
   CLI's documented configuration method.

### Initial scaffold (round one)

1. Added the community-health files (README, CONTRIBUTING, CODE_OF_CONDUCT,
   SECURITY, issue templates, pull request template) copied from the
   Kinsman4249/.github-private canonical templates and filled in for this
   project.
2. Added the tag-triggered release workflow copied from the same
   template, configured for the shell-script build path with the OS
   matrix trimmed to ubuntu-latest, since this project ships bash
   scripts with no platform-specific build step.
3. Added PREREQUISITES.md as the itemized list of what needs to exist on
   RunPod, Cloudflare, and GitHub before running startup.sh, and updated
   README.md to point to it instead of embedding the same list, since
   startup.sh's setup wizard (see item below) now handles most of what
   used to require manual setup.
