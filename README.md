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
  `vllm/vllm-openai` image, run directly rather than a custom-built
  image - it's the same image RunPod's own community "vLLM" pod
  templates all wrap, so it's typically already cache-warm on RunPod's
  nodes. `image/Dockerfile` only adds the thin layer needed to
  self-manage idle shutdown: `runpodctl` and `sshd` (diagnostics only,
  reached over the pod's own `22/tcp`).
- Six built-in model presets in the 30-90B range (quantized so they fit
  a single GPU - AWQ for five of them, vLLM's own on-the-fly FP8 for
  the sixth): DeepSeek-R1-Distill-Qwen-32B, Qwen3-32B, Qwen3-Coder-30B-
  A3B (MoE), Qwen2.5-72B-Instruct, Llama-3.3-70B-Instruct, and
  Qwen3.5-40B-Claude-4.6-Opus-Deckard-Heretic-Uncensored-Thinking - plus
  a `custom` option to paste any Hugging Face repo id, with a prompt to
  grow the network volume if it needs more room than the presets
  assume. See `lib/launch.sh`'s `PRESET_TABLE` for the exact repos,
  quantization methods, and VRAM floors.
- `image/entrypoint.sh` (the pod image's `ENTRYPOINT`, runs every boot):
  starts `sshd`, fetches and starts `idle-watchdog.sh` fresh from this
  repo's `main` branch (so a fix there applies without an image
  rebuild), then execs into `vllm serve` - gated with a one-off
  bearer-token API key (vLLM's own `--api-key` flag) generated fresh
  per launch, since RunPod's proxy URL for the endpoint is otherwise
  open to anyone who guesses it. SSH gets its own firewall-level lock:
  `lock_ssh_to_first_client()` waits for the first connection on port
  22 and then `iptables`-DROPs every other source IP for the rest of
  the pod's life - see the comment above it in `entrypoint.sh` for the
  caveats (best-effort, not yet confirmed whether RunPod's proxy
  preserves the real client IP).
- `idle-watchdog.sh` (runs on the pod): after a configurable idle
  period with zero vLLM request activity (polled via vLLM's own
  `/metrics` endpoint), stops and deletes the pod via the RunPod API -
  the actual cost-control mechanism for the whole design (the
  `--terminate-after` flag `startup.sh` sets at pod-create time is a
  second, independent backstop in case this process itself hangs or
  crashes).
- A cheap CPU pod can pre-download a model's weights onto the network
  volume (`--prewarm` / `--prewarm-only`) before the expensive GPU pod
  ever boots, since the download is pure network/CPU-bound work.
- `--storage-mode container-disk` (default: `network-volume`) skips the
  network volume entirely and uses a bigger, local, per-pod disk
  instead - faster reads, but the model re-downloads every session and
  nothing survives `idle-watchdog.sh` deleting the pod. See
  `lib/launch.sh`'s `CONTAINER_DISK_GB_STANDALONE` comment; run
  `e2e-test.sh --storage-mode <mode>` with each value to compare actual
  wall-clock time for your own model/GPU choice.
- `--no-logging` disables vLLM's stats/access logging for the pod, on
  top of vLLM's own default of not logging prompt/response content -
  see `image/entrypoint.sh`.
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
- No custom-built inference image to maintain: `vllm/vllm-openai` is
  vLLM's own official image, tracking their releases directly.

## Status

This is a from-scratch pivot (2026-08-12) away from an earlier
llama.cpp + OpenHands design - see `handoff.md` for that history. A
second pivot (2026-08-14) then dropped Cloudflare entirely in favor of
RunPod's own per-pod SSH (`22/tcp`) and HTTP proxy
(`https://<pod-id>-8000.proxy.runpod.net`) - see CHANGELOG.md. All
scripts pass `bash -n`; the exact `vllm serve` flags and the `/metrics`
field names `idle-watchdog.sh` relies on are believed-correct from
vLLM/RunPod docs. Treat the next `./startup.sh` run as the real test of
this pivot.

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

## Testing

`./e2e-test.sh` runs the full loop non-interactively against a real
(billed) pod: picks the cheapest GPU meeting a preset's VRAM floor,
creates the pod, waits for it to come up, then checks the OpenAI
endpoint actually serves a completion and (unless `--skip-ssh-check`)
that SSH reaches it with sshd/idle-watchdog/vllm all running - then
always tears the pod down, pass or fail. See `./e2e-test.sh --help` for
`--preset`, `--check-idle-shutdown` (also proves idle-watchdog.sh
self-terminates the pod), and `--keep`.

This works non-interactively because `setup_ephemeral_ssh_key()` (in
`lib/common.sh`, called from `create_pod()`) generates a fresh,
passphrase-free keypair for every pod - a passphrase-protected key
would otherwise stop SSH dead in any script or agent session with no
way to type one in. It's registered with your RunPod account and
revoked again once the pod is torn down (see `cleanup_ephemeral_ssh_key()`
and `e2e-test.sh`'s own `cleanup()` trap).

## License

GPLv3 - see [LICENSE](LICENSE).
