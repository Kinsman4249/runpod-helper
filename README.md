# runpod-helper

One-time-setup, mostly-hands-off tooling to run a self-hosted,
OpenAI-compatible LLM inference endpoint on a rented RunPod Secure Cloud
GPU pod, reached directly through RunPod's own per-pod HTTP proxy and
SSH - no third-party tunnel, nothing long-lived stored on RunPod's side
beyond the model-weights cache and a one-off SSH key per pod.

## What this does

- `startup.sh` (runs on your own machine): pick a GPU tier and model
  once, then silently reuse that choice on every future run (`--new` to
  change it). Creates the RunPod Secure Cloud pod, attaches the
  persistent model-weights volume, then polls the OpenAI-compatible
  endpoint itself (RunPod's `https://<pod-id>-8000.proxy.runpod.net`)
  until the engine has finished loading the model and is actually
  serving. If RunPod rejects the create because the chosen card's host
  has no free capacity (it can, even when `gpu list` shows that GPU in
  stock), it offers the other available cards meeting the model's VRAM
  floor to retry with instead of failing outright.
- Model serving: two engines, each its own official upstream image run
  directly with no custom Dockerfile or entrypoint (dropped 2026-08-14 -
  see CHANGELOG.md). [vLLM](https://docs.vllm.ai)'s `vllm/vllm-openai`
  for the AWQ/FP8 presets (the same image RunPod's community "vLLM"
  templates wrap, so it's typically cache-warm on their nodes), and
  [llama.cpp](https://github.com/ggml-org/llama.cpp)'s
  `ghcr.io/ggml-org/llama.cpp:server-cuda` for the GGUF presets, which
  downloads a GGUF straight from Hugging Face via `--hf-repo`. Everything
  model/runtime-specific arrives as CLI flags appended to each image's
  own fixed entrypoint (`vllm serve` / `llama-server`) - see
  `create_pod()` in `lib/launch.sh`. There's no sshd on either image, so
  diagnostics go through RunPod's own SSH-over-proxy instead
  (`resolve_pod_ssh_proxy_host()` in `lib/common.sh`), which execs into
  the container on RunPod's own side without needing one.
- Nine built-in model presets in the 27-72B range, quantized so they fit
  a single GPU - seven served with vLLM (five AWQ, one on-the-fly FP8,
  one AWQ hybrid Gated-DeltaNet), two GGUF served with llama.cpp:
  DeepSeek-R1-Distill-Qwen-32B, Qwen3-32B, Qwen3-Coder-30B-A3B (MoE),
  Qwen2.5-72B-Instruct, Llama-3.3-70B-Instruct,
  Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking (and a
  GGUF build of it in two context sizes), and Qwen3.6-27B-AWQ-MTP - plus
  a `custom` option to paste any Hugging Face repo id (served with vLLM),
  and a `custom-gguf` option to paste any Hugging Face GGUF repo and pick
  a quant from what it publishes (sizes pulled live, served with
  llama.cpp), each with a prompt to grow the network volume if needed.
  See `lib/launch.sh`'s `PRESET_TABLE` for the exact repos, engines,
  quantization methods, extra serve flags (some hybrid-attention models
  need `--gpu-memory-utilization`/`--kv-cache-dtype` tuning beyond the
  defaults - see that file's comment), and VRAM floors.
- The endpoint is gated with a one-off bearer-token API key (the engine's
  own `--api-key` flag) generated fresh per launch, since RunPod's proxy
  URL for the endpoint is otherwise open to anyone who guesses it.
  `--ports "8000/http"` on `pod create` is what actually makes that URL
  route at all - RunPod's proxy does not auto-detect a listening port
  (confirmed live 2026-08-14 after this being silently missing caused
  every previous launch to look like a failure; see CHANGELOG.md).
- `idle-watchdog.sh` (runs on YOUR machine, not the pod - moved there
  2026-08-14 along with the custom image, since the bare images have
  no room to host a second background process): after a configurable
  idle period with zero request activity (polled via the engine's own
  `/metrics` endpoint through RunPod's proxy - engine-aware, vLLM's
  counters or llama.cpp's), stops and deletes the pod via `runpodctl` -
  the actual cost-control mechanism for the whole design (the
  `--terminate-after` flag `create_pod()` sets is a second, independent
  backstop in case this process itself hangs, crashes, or your machine
  goes to sleep). `--idle-minutes 0` disables it.
- `--storage-mode container-disk` (default: `network-volume`) skips the
  network volume entirely and uses a bigger, local, per-pod disk
  instead - faster reads, but the model re-downloads every launch and
  nothing survives the pod being stopped/deleted. See
  `lib/launch.sh`'s `CONTAINER_DISK_GB_STANDALONE` comment; run
  `e2e-test.sh --storage-mode <mode>` with each value to compare actual
  wall-clock time for your own model/GPU choice.
- `--no-logging` disables the engine's stats/access logging for the pod
  (vLLM or llama.cpp, whichever the preset uses), on top of each engine's
  own default of not logging prompt/response content.
- RUNPOD_API_KEY lives in the OS keyring (`secret-tool`/libsecret), not
  `~/.runpod-lab/config` - see `load_secrets()` in `lib/common.sh`. An
  existing plaintext config from before this change migrates
  automatically on the next run. The endpoint API key and the pod's SSH
  keypair aren't stored anywhere at all - both are generated fresh per
  launch (see `create_pod()` in `lib/launch.sh`) and printed once in the
  launch summary.

## Why

- RunPod Secure Cloud was picked for predictable, zero-egress billing
  (RunPod's own datacenters, not third-party community hosts).
- Model weights live on the network volume (`HF_HOME`), not the
  container disk - a pod recreated after being idled out doesn't
  re-download anything, it just reattaches the same volume.
- No custom-built inference image to maintain at all: `vllm/vllm-openai`
  is vLLM's own official image, run directly, tracking their releases
  with zero rebuild step on this repo's side.

## Status

This is a from-scratch pivot (2026-08-12) away from an earlier
llama.cpp + OpenHands design - see `handoff.md` for that history. A
second pivot (2026-08-14) dropped Cloudflare entirely in favor of
RunPod's own HTTP proxy (`https://<pod-id>-8000.proxy.runpod.net`), and
a third pivot the same day dropped the custom Dockerfile/entrypoint.sh
in favor of running `vllm/vllm-openai` directly with no wrapper at all -
see CHANGELOG.md for what changed and why (including a real bug found
live: `--ports 8000/http` was missing from every pod-create call, which
made the proxy 404 forever regardless of whether the model itself
loaded fine - very likely the actual cause of every prior "launch
failed" report, unrelated to model/GPU choice). The `--ports` fix and
the bare-image `--docker-args` rewrite are confirmed live end-to-end
against `qwen3.6-27b-awq-mtp` on a 24GB GPU; the other presets haven't
been re-run against this rewrite yet - see CHANGELOG.md.

## Setup

First run: `./startup.sh` detects there's no local config yet and walks
you through a one-time setup wizard - installing the local tools it
needs, taking your RunPod API key, picking a datacenter, and creating the
model-weights volume. That's it; nothing to configure outside RunPod's
own dashboard. The datacenter menu groups locations by the Five/Nine/
Fourteen Eyes intelligence-sharing alliances, listing those outside all
three first (privacy-preferred) while leaving every one selectable.

Every run after that: GPU tier and model are picked once and silently
reused from then on (`--new` to change them), and everything else - the
pod, its one-off SSH key and API key, shutdown - just happens.

See [PREREQUISITES.md](./PREREQUISITES.md) for the itemized list of what
needs to exist on RunPod before that first run, including datacenter
privacy tradeoffs and GPU/volume sizing guidance for each model preset.

## Command-line flags

All flags are optional - a bare `./startup.sh` reuses your last session
and launches. `./startup.sh --help` prints this same list.

### Session and setup

- `--setup` - Force the one-time setup wizard even when a config already
  exists (installs local tools, takes your RunPod API key + optional
  Hugging Face token, picks a datacenter, creates the network volume).
  Runs automatically on the very first launch.
- `--norotate` - Modifies `--setup`: keep the existing RunPod API key and HF
  token from the OS keyring instead of re-pasting them, and keep the
  existing network volume instead of creating a new (billed) one, as long
  as the datacenter you pick is the same one already on file. Picking a
  different datacenter still creates a new volume, since a volume is
  locked to the datacenter it was created in. No effect without `--setup`.
- `--rotate` - Re-paste just the RunPod API key (validated before it's
  saved) without redoing the rest of setup. The endpoint API key and the
  pod's SSH keypair are generated fresh every launch, so there is nothing
  to rotate for either of them.
- `--new` - Re-pick the model/preset and GPU interactively instead of
  silently reusing the last session. Use this whenever you want a
  different model, a different card, or to switch to a custom repo.

### Choosing what runs (interactive, shown on first launch or `--new`)

1. **Model** - pick one of the nine built-in presets (each label shows
   its VRAM floor and whether that floor is tested-live or a conservative
   estimate), `custom` to paste any Hugging Face repo id (served with
   vLLM), or `custom-gguf` to paste any Hugging Face GGUF repo and pick a
   quant from what it publishes - the quant list and sizes are pulled live
   and served with llama.cpp, and the volume is auto-sized to the quant. A
   plain `custom` repo has no known weight size, so its GPU list isn't
   VRAM-filtered and you set the volume size yourself.
2. **GPU** - live list of cards currently stocked in your datacenter that
   meet the model's VRAM floor, cheapest first. If `pod create` later
   fails because that specific host is full, you're re-offered the other
   available cards to retry with.
3. **Context length** - tokens (`max-model-len` / `--ctx-size`); a
   per-model default is suggested.
4. **Volume size** (custom repos only, network-volume mode) - offered so
   you can grow the volume if the model needs more room than it currently
   has. Typing `b` on any menu (or `:b` at a text prompt) steps back to
   the previous choice.

### Runtime and lifetime

- `--idle-minutes N` - Minutes of zero request activity before the pod
  auto-shuts-down (default 20). `0` disables idle shutdown, leaving only
  the wall-clock cap below.
- `--max-runtime-hours N` - Hard wall-clock lifetime cap regardless of
  activity (default 4), enforced by RunPod's own `--terminate-after` as a
  backstop even if the local idle-watchdog dies.
- `--storage-mode MODE` - `network-volume` (default) keeps weights on a
  billed volume across pod recreations; `container-disk` uses a bigger
  local per-pod disk that re-downloads every launch and survives nothing.
- `--prewarm` - Before creating the real GPU pod, download the chosen
  preset's weights onto the network volume via a cheap CPU pod, so you
  don't pay the GPU's hourly rate just to sit through the download.
  Network-volume mode only. `startup.sh` also offers this automatically
  the first time a preset touches a volume it hasn't cached on before.
- `--extra-args "ARGS"` - Append arbitrary flags verbatim to the engine's
  serve command (`vllm serve` or `llama-server`), for a model/quant that
  needs a knob this script doesn't expose - e.g.
  `--extra-args "--rope-scaling yarn --rope-scaling-factor 4"` for vLLM,
  or `--extra-args "--split-mode row"` for llama.cpp. Applied after the
  preset's own flags (so yours win on last-one-wins flags);
  space-separated, so a single flag's value can't contain spaces. You own
  their correctness - a bad flag makes the engine fail to boot, so watch
  the pod logs.
- `--no-logging` - Disable the engine's stats/access logging for the pod,
  on top of each engine's own default of not logging prompt/response
  content.

### Diagnostics

- `--debug` - Trace every command (`set -x`) to both the terminal and a
  timestamped log under `~/.runpod-lab/logs`, tagged with the build
  number. Known secrets are best-effort redacted (not guaranteed - skim
  before sharing).
- `--debug-quiet` - Same trace, written to the log file only; the console
  stays clean. Use when `--debug`'s live trace makes an interactive run
  unreadable.

### `e2e-test.sh` (billed end-to-end test)

Shares `--storage-mode`, `--no-logging`, `--extra-args`, `--debug`, and
`--debug-quiet` with `startup.sh`, plus: `--preset NAME` (which built-in
to test; defaults to the cheapest), `--prewarm-only` (cache a preset's
weights and exit, no GPU pod), `--gpu-id ID` (pin to one card instead of
auto-picking cheapest), `--keep` (leave the pod running), and
`--check-idle-shutdown` (also prove the idle-watchdog self-terminates the
pod). Without `--gpu-id` it auto-advances cheapest-first through every
card meeting the floor if one has no capacity. See `./e2e-test.sh --help`.

## Using the endpoint

Once a pod is up, `startup.sh` prints the endpoint URL, the model name
to request, and the API key (shown once, not stored anywhere). Point
any OpenAI-compatible client at it:

```
base_url: https://<pod-id>-8000.proxy.runpod.net/v1
api_key:  <printed in the launch summary - one-off, generated fresh for this pod>
model:    <served-model-name from the launch summary, e.g. "qwen3-32b">
```

`<pod-id>` changes every time you launch a new pod (`--new`, or the
pod getting recreated after idling out) - there's no stable custom
hostname the way the old Cloudflare setup had. Reread the launch
summary (or `runpodctl pod get <pod-id>`) after any pod recreation to
get the current URL.

Quick check with curl:

```sh
curl https://<pod-id>-8000.proxy.runpod.net/v1/chat/completions \
  -H "Authorization: Bearer <VLLM_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "<served-model-name>", "messages": [{"role": "user", "content": "hello"}]}'
```

Or with the `openai` Python SDK (or any tool that lets you set a custom
`base_url`, e.g. Continue, Aider):

```python
from openai import OpenAI
client = OpenAI(base_url="https://<pod-id>-8000.proxy.runpod.net/v1", api_key="<VLLM_API_KEY>")
client.chat.completions.create(model="<served-model-name>", messages=[{"role": "user", "content": "hello"}])
```

### Pointing OpenCode at it

[OpenCode](https://opencode.ai) talks to any OpenAI-compatible endpoint
through a custom provider entry. Add one to `~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "runpod-helper": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "runpod-helper",
      "options": {
        "baseURL": "{env:RUNPOD_HELPER_BASE_URL}",
        "apiKey": "{env:RUNPOD_HELPER_API_KEY}"
      },
      "models": {
        "<served-model-name>": {
          "name": "<served-model-name>"
        }
      }
    }
  }
}
```

`baseURL`/`apiKey` read from environment variables instead of being
pasted into the file, since both change on every pod launch (new
`<pod-id>`, fresh one-off API key - see "Using the endpoint" above).
Export them from the launch summary before starting OpenCode:

```sh
export RUNPOD_HELPER_BASE_URL="https://<pod-id>-8000.proxy.runpod.net/v1"
export RUNPOD_HELPER_API_KEY="<VLLM_API_KEY>"
```

Replace `<served-model-name>` in the config with whatever preset you
launched (e.g. `qwen3-coder-30b-moe`) - it must match `SERVED_MODEL_NAME`
from the launch summary exactly. Then select the `runpod-helper` provider
from OpenCode's model picker (`/models`).

### Syncing into vscodium-box (Kilo Code / opencode)

If you talk to the pod from Kilo Code or opencode inside
[vscodium-box](https://github.com/Kinsman4249/vscodium-for-immutable),
`startup.sh` asks after every launch whether to push the fresh
`baseURL`/`apiKey`/model straight into both tools' configs, instead of you
copy-pasting the OpenCode JSON above by hand:

```
Sync this endpoint into Kilo Code's and opencode's configs inside vscodium-box now? [y/N]
```

Say yes and it's done - no running container or `podman exec` needed, since
`~/.config/kilo/` and `~/.config/opencode/` inside vscodium-box are a
straight bind mount of a directory on the host, so writing the host copy
writes the container's copy directly. Fields it doesn't know about (extra
models, Kilo's `permission` block) are left alone. Say no and nothing is
touched - paste the OpenCode config above by hand instead, or run
`./sync-runpod-endpoint.sh` again later against a saved log.

That prompt is `sync-runpod-endpoint.sh` under the hood, which also works
standalone:

```bash
./sync-runpod-endpoint.sh --base-url URL --api-key KEY --model NAME
                                                   # sync explicit values directly
./startup.sh | ./sync-runpod-endpoint.sh          # pipe a live launch straight in
./sync-runpod-endpoint.sh --log launch.log        # or from a saved log file
./sync-runpod-endpoint.sh --container-home DIR    # target a different container's
                                                   # private home instead of vscodium-box's
```

vscodium-box is the default target, but nothing about the script is specific
to it - it just needs a private home directory laid out the way
vscodium-for-immutable's `install-vscodium.sh` lays one out (`.config/kilo/`,
`.config/opencode/` under a directory bind-mounted to a container's `~`).
`--container-home` points it at any other one, e.g. a second container built
the same way.

Only Kilo Code and opencode are wired up - they were the only two of
Kilo/Cline/Roo/opencode found installed in vscodium-box. Cline and Roo use
the same `provider.<name>.options.{baseURL,apiKey}` shape in their own
settings files, so if you install one and hit the same staleness problem,
add its config path to the `CONFIGS` array in the script.

## Testing

`./e2e-test.sh` runs the full loop non-interactively against a real
(billed) pod: picks the cheapest GPU meeting a preset's VRAM floor
(auto-advancing to the next card if one has no capacity), creates the
pod, waits for it to come up, checks the OpenAI endpoint actually serves
a completion, and confirms the local idle-watchdog process is running -
then always tears the pod down, pass or fail. Its flags are summarized
under "Command-line flags" above; `./e2e-test.sh --help` prints them in
full.

The ephemeral SSH keypair `create_pod()` generates every launch
(`setup_ephemeral_ssh_key()` in `lib/common.sh`) is for the
diagnostics-only SSH-over-proxy path (`resolve_pod_ssh_proxy_host()`) -
it's not needed for anything in the normal launch or test flow to
succeed, since the bare vLLM image has no sshd at all. Registered with
your RunPod account and revoked again once the pod is torn down (see
`cleanup_ephemeral_ssh_key()` and `e2e-test.sh`'s own `cleanup()` trap).

See `GOTCHAS.md` for non-obvious RunPod/dependency behavior confirmed live
while building this (SSH-over-proxy's real address format, CPU pod sizing,
quantization pitfalls, and more).

## License

GPLv3 - see [LICENSE](LICENSE).
