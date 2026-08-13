# runpod-helper

One-time-setup, mostly-hands-off tooling to run a self-hosted,
OpenAI-compatible LLM inference endpoint on a rented RunPod Secure Cloud
GPU pod, reachable at a stable Cloudflare hostname regardless of which
pod instance is currently backing it, with nothing long-lived stored on
RunPod's side beyond the model-weights cache.

## What this does

- `startup.sh` (runs on your own machine): pick a GPU tier and model
  once, then silently reuse that choice on every future run (`--new` to
  change it). Creates the RunPod Secure Cloud pod, attaches the
  persistent model-weights volume, waits for the Cloudflare Tunnel/SSH
  path to come up, then polls the OpenAI-compatible endpoint itself
  until vLLM has finished loading the model and is actually serving.
- Model serving: [vLLM](https://docs.vllm.ai)'s own official
  `vllm/vllm-openai` image, run directly rather than a custom-built
  image - it's the same image RunPod's own community "vLLM" pod
  templates all wrap, so it's typically already cache-warm on RunPod's
  nodes. `image/Dockerfile` only adds the thin layer needed to reach it
  through a stable hostname: `cloudflared`, `runpodctl`, and `sshd`
  (diagnostics only).
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
  starts `sshd` and the Cloudflare Tunnel, fetches and starts
  `idle-watchdog.sh` fresh from this repo's `main` branch (so a fix
  there applies without an image rebuild), then execs into
  `vllm serve` - gated with a bearer-token API key (vLLM's own
  `--api-key` flag), since the endpoint's Public Hostname is
  deliberately not put behind Cloudflare Access (most OpenAI-compatible
  client tools can send a bearer token but can't add Access's custom
  headers).
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
llama.cpp + OpenHands design - see `handoff.md` for that history. All
scripts pass `bash -n`, but none of this pivot has been run against a
real pod yet: the exact `vllm serve` flags, the `/metrics` field names
`idle-watchdog.sh` relies on, the pod image's actual pull size vs.
`CONTAINER_DISK_GB`, and the Cloudflare Public Hostname setup are all
believed-correct from vLLM/RunPod/Cloudflare docs, not yet confirmed
live. Treat the first `./startup.sh` run as the real test.

## Setup

First run: `./startup.sh` detects there's no local config yet and walks
you through a one-time setup wizard - installing the local tools it
needs, taking your RunPod API key, creating the model-weights volume,
generating the vLLM endpoint's API key, and pausing at the right moment
for the Cloudflare Tunnel step that has to happen on their site
directly.

Every run after that: GPU tier and model are picked once and silently
reused from then on (`--new` to change them), and everything else - the
pod, the tunnel, shutdown - just happens.

See [PREREQUISITES.md](./PREREQUISITES.md) for the itemized list of what
needs to exist on RunPod and Cloudflare before that first run, including
datacenter privacy tradeoffs and GPU/volume sizing guidance for each
model preset.

## Using the endpoint

Once a pod is up, `startup.sh` prints the endpoint URL, the model name
to request, and where to find the API key. Point any OpenAI-compatible
client at it:

```
base_url: https://<your-api-hostname>/v1
api_key:  <VLLM_API_KEY from ~/.runpod-lab/config>
model:    <served-model-name from the launch summary, e.g. "qwen3-32b">
```

`<your-api-hostname>` is the API subdomain you chose under **your own
Cloudflare domain** during setup (e.g. `pod-api.yourdomain.com`) - not
a `runpod.net`/`runpod.io` address. It's stable across pod recreations:
same hostname every launch, because it's the Cloudflare Tunnel's Public
Hostname route, not tied to any particular pod's IP. Only the model
actually running behind it changes when you `--new` to a different
preset.

Quick check with curl:

```sh
curl https://<your-api-hostname>/v1/chat/completions \
  -H "Authorization: Bearer <VLLM_API_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"model": "<served-model-name>", "messages": [{"role": "user", "content": "hello"}]}'
```

Or with the `openai` Python SDK (or any tool that lets you set a custom
`base_url`, e.g. Continue, Aider):

```python
from openai import OpenAI
client = OpenAI(base_url="https://<your-api-hostname>/v1", api_key="<VLLM_API_KEY>")
client.chat.completions.create(model="<served-model-name>", messages=[{"role": "user", "content": "hello"}])
```

## Testing

`./e2e-test.sh` runs the full loop non-interactively against a real
(billed) pod: picks the cheapest GPU meeting a preset's VRAM floor,
creates the pod, waits for it to come up, then checks the OpenAI
endpoint actually serves a completion and (unless `--skip-ssh-check`)
that SSH reaches it with sshd/cloudflared/idle-watchdog/vllm all
running - then always tears the pod down, pass or fail. See
`./e2e-test.sh --help` for `--preset`, `--check-idle-shutdown` (also
proves idle-watchdog.sh self-terminates the pod), and `--keep`.

This only works non-interactively because `setup_ssh_key()` (in
`lib/wizard.sh`) generates a dedicated, passphrase-free keypair for
reaching these pods - a passphrase-protected key would otherwise stop
`ssh runpod-lab` dead in any script or agent session with no way to
type one in. See PREREQUISITES.md for why that tradeoff is fine here
(the pods are ephemeral, and SSH access to them is diagnostics-only).

## License

Not yet decided - add one before the first tagged release if this repo
becomes public-facing beyond personal use.
