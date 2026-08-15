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
  persistent model-weights volume, waits for the pod's own SSH to come
  up, then polls the OpenAI-compatible endpoint itself (RunPod's
  `https://<pod-id>-8000.proxy.runpod.net`) until vLLM has finished
  loading the model and is actually serving.
- Model serving: [vLLM](https://docs.vllm.ai)'s own official
  `vllm/vllm-openai` image, run directly with no custom Dockerfile or
  entrypoint at all (dropped 2026-08-14 - see CHANGELOG.md) - it's the
  same image RunPod's own community "vLLM" pod templates all wrap, so
  it's typically already cache-warm on RunPod's nodes. Everything
  model/runtime-specific arrives as CLI flags appended to the image's own
  fixed `vllm serve` entrypoint (see `create_pod()` in `lib/launch.sh`).
  There's no sshd on the pod at all as a result - diagnostics go through
  RunPod's own SSH-over-proxy instead (`resolve_pod_ssh_proxy_host()` in
  `lib/common.sh`), which execs into the container on RunPod's own side
  without needing one.
- Seven built-in model presets in the 27-90B range (quantized so they
  fit a single GPU - AWQ for five, vLLM's own on-the-fly FP8 for the
  sixth, and an AWQ hybrid Gated-DeltaNet model for the seventh):
  DeepSeek-R1-Distill-Qwen-32B, Qwen3-32B, Qwen3-Coder-30B-A3B (MoE),
  Qwen2.5-72B-Instruct, Llama-3.3-70B-Instruct,
  Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking, and
  Qwen3.6-27B-AWQ-MTP - plus a `custom` option to paste any Hugging Face
  repo id, with a prompt to grow the network volume if it needs more
  room than the presets assume. See `lib/launch.sh`'s `PRESET_TABLE` for
  the exact repos, quantization methods, extra `vllm serve` flags (some
  hybrid-attention models need `--gpu-memory-utilization`/
  `--kv-cache-dtype` tuning beyond vLLM's defaults - see that file's
  comment), and VRAM floors.
- `vllm serve` is gated with a one-off bearer-token API key (vLLM's own
  `--api-key` flag) generated fresh per launch, since RunPod's proxy URL
  for the endpoint is otherwise open to anyone who guesses it.
  `--ports "8000/http"` on `pod create` is what actually makes that URL
  route at all - RunPod's proxy does not auto-detect a listening port
  (confirmed live 2026-08-14 after this being silently missing caused
  every previous launch to look like a failure; see CHANGELOG.md).
- `idle-watchdog.sh` (runs on YOUR machine, not the pod - moved there
  2026-08-14 along with the custom image, since the bare vLLM image has
  no room to host a second background process): after a configurable
  idle period with zero vLLM request activity (polled via vLLM's own
  `/metrics` endpoint through RunPod's proxy), stops and deletes the pod
  via `runpodctl` - the actual cost-control mechanism for the whole
  design (the `--terminate-after` flag `create_pod()` sets is a second,
  independent backstop in case this process itself hangs, crashes, or
  your machine goes to sleep). `--idle-minutes 0` disables it.
- `--storage-mode container-disk` (default: `network-volume`) skips the
  network volume entirely and uses a bigger, local, per-pod disk
  instead - faster reads, but the model re-downloads every launch and
  nothing survives the pod being stopped/deleted. See
  `lib/launch.sh`'s `CONTAINER_DISK_GB_STANDALONE` comment; run
  `e2e-test.sh --storage-mode <mode>` with each value to compare actual
  wall-clock time for your own model/GPU choice.
- `--no-logging` disables vLLM's stats/access logging for the pod, on
  top of vLLM's own default of not logging prompt/response content.
- RUNPOD_API_KEY lives in the OS keyring (`secret-tool`/libsecret), not
  `~/.runpod-lab/config` - see `load_secrets()` in `lib/common.sh`. An
  existing plaintext config from before this change migrates
  automatically on the next run. The vLLM API key and the pod's SSH
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
needs, taking your RunPod API key, and creating the model-weights
volume. That's it; nothing to configure outside RunPod's own dashboard.

Every run after that: GPU tier and model are picked once and silently
reused from then on (`--new` to change them), and everything else - the
pod, its one-off SSH key and API key, shutdown - just happens.

See [PREREQUISITES.md](./PREREQUISITES.md) for the itemized list of what
needs to exist on RunPod before that first run, including datacenter
privacy tradeoffs and GPU/volume sizing guidance for each model preset.

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

## Testing

`./e2e-test.sh` runs the full loop non-interactively against a real
(billed) pod: picks the cheapest GPU meeting a preset's VRAM floor,
creates the pod, waits for it to come up, checks the OpenAI endpoint
actually serves a completion, and confirms the local idle-watchdog
process is running - then always tears the pod down, pass or fail. See
`./e2e-test.sh --help` for `--preset`, `--check-idle-shutdown` (also
proves the idle-watchdog actually self-terminates the pod once it goes
idle), and `--keep`.

The ephemeral SSH keypair `create_pod()` generates every launch
(`setup_ephemeral_ssh_key()` in `lib/common.sh`) is for the
diagnostics-only SSH-over-proxy path (`resolve_pod_ssh_proxy_host()`) -
it's not needed for anything in the normal launch or test flow to
succeed, since the bare vLLM image has no sshd at all. Registered with
your RunPod account and revoked again once the pod is torn down (see
`cleanup_ephemeral_ssh_key()` and `e2e-test.sh`'s own `cleanup()` trap).

## License

GPLv3 - see [LICENSE](LICENSE).
