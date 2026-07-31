# Changelog

## Change history

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
