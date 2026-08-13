# Prerequisites

Everything below needs to exist before you run `startup.sh` for the
first time. The setup wizard in `startup.sh` handles almost everything
else - installing local tools, creating the network volume, generating
the vLLM API key, walking you through the Cloudflare steps - so this
list is only what has to happen on each service's own website before
the wizard can take over.

## RunPod

1. Create a RunPod account.
2. Add a payment method (credit card). RunPod requires at least an
   hour's worth of credit before it will deploy a pod, and enabling
   auto-pay / low-balance alerts needs a card on file anyway.
3. Generate an API key (Settings > API Keys). Keep it somewhere you can
   paste from - the wizard asks for it on first run and uses it for
   everything after that.
4. Nothing to prepare here - the wizard generates its own dedicated
   keypair (`~/.runpod-lab/ssh_key`, no passphrase) the first time it
   runs and registers the public half with your RunPod account. It's
   deliberately not your personal/default SSH identity: RunPod pods are
   reached over SSH for diagnostics only (normal use is the OpenAI
   endpoint, not an interactive session), the pods themselves are
   ephemeral (auto-terminate when idle), and a passphrase-free key is
   what lets `ssh runpod-lab` run non-interactively (e2e test scripts,
   an agent session, etc.) instead of hanging on a prompt nothing can
   answer.

## Cloudflare

1. Have, or create, a Cloudflare account. The free plan is sufficient.
2. Have a domain added to that account. The Tunnel needs a hostname to
   publish under (e.g. `pod.yourdomain.com`). This is the one item on
   this list that genuinely can't be deferred to the wizard - without a
   domain in Cloudflare, there's nothing for a named Tunnel to attach
   to.
3. Nothing else ahead of time. The wizard pauses with the exact console
   steps for creating the named Tunnel and adding two Public Hostname
   routes on it: one for SSH -> `localhost:22`, one for the OpenAI-
   compatible API -> `localhost:8000` (fixed - that's vLLM's own
   documented default port, not something you choose per launch the way
   the old frontend port was).

   In brief, what that involves: Networking > Tunnels > Create a tunnel
   (Cloudflared connector, named, not the quick/trycloudflare kind) ->
   copy the tunnel token from the install command shown (or later from
   the tunnel's Overview page) -> add the two Public Hostname routes
   described above under the tunnel's "Public Hostname" tab -> then,
   under Zero Trust > Access > Applications, add an application, stay
   on the "Self-hosted and private" tab of the type-picker modal (the
   Private destinations/Workers/Public DNS/Service auth sub-tabs there
   are just examples, not choices you need to make) and click "Continue
   with Self-hosted and private" -> on the Destinations section, add
   **only the SSH subdomain** as a public hostname -> add a policy that
   allows only your own email -> save.

   The API hostname is deliberately left OUT of that Access
   application. It's gated by vLLM's own `--api-key` bearer-token auth
   instead (the wizard generates this for you), because most OpenAI-
   compatible client tools (the `openai` SDK, Continue, Aider, and
   similar) can send a bearer token but have no way to add Access's
   custom `CF-Access-Client-Id`/`Secret` headers - putting it behind
   Access would make the endpoint unusable from them rather than just
   gating it. This is a real tradeoff, not a default to blindly accept:
   the API hostname is reachable by anyone who finds it **and** has the
   API key, not locked to your own identity the way SSH is. If that's
   not acceptable for your threat model, add a second Access
   application covering the API hostname too, and expect to lose
   compatibility with client tools that can't set custom headers.

   Direct links, once you know your account ID and tunnel ID (both
   appear in the address bar once you're on the relevant page - swap
   them into the placeholders below to jump straight there next time
   instead of digging through the dashboard nav):
     - Tunnel overview (token, routes): `https://dash.cloudflare.com/<account-id>/tunnels/<tunnel-id>/overview`
     - Access policies: `https://dash.cloudflare.com/<account-id>/one/access-controls/policies`

## Local machine

1. `bash`, `ssh`, `curl`, `openssl`. All standard on any Linux or macOS
   install, Bazzite included.
2. `~/.local/bin` on your `PATH`. Default on Fedora-family systems
   including Bazzite; check with `echo $PATH` if unsure. The wizard
   installs its tools there.
3. `runpodctl` and `cloudflared` are installed by the wizard as
   user-level binaries (downloaded release binaries into
   `~/.local/bin`). No `sudo`, no package manager, no reboot.
   `cloudflared` is only needed locally to validate the tunnel token
   during setup - the pod itself runs its own `cloudflared`, not this
   one.

## One thing to decide before you start

The network volume is created in a specific RunPod datacenter and can
only be attached to pods in that same datacenter. That choice
constrains which GPUs are available to you later, since not every
datacenter stocks every card. The wizard will ask which datacenter to
use - if you already know you want a specific GPU tier (e.g. a 48GB card
for the two 70B+ presets), check availability for that card first and
pick the datacenter accordingly, rather than picking one at random and
discovering the GPU you want isn't offered there.

### Datacenter choice: privacy

Jurisdiction matters more than physical distance. US and Canadian
datacenters (`US-*`, `CA-*`) sit under the US CLOUD Act and Five Eyes
intelligence-sharing, regardless of RunPod's own policies. EU datacenters
(`EU-*`) are GDPR-bound and outside Five Eyes. Iceland (`EUR-IS-*`) is
the strongest option in RunPod's list - EEA/GDPR-aligned, non-Five-Eyes,
and has decent GPU stock (RTX 4090/5090, RTX PRO 6000, occasional H100/
H200 SXM). If you're in North America, Iceland is still low enough
latency for interactive use.

### GPU tier and volume size, per model preset

Weight sizes are approximate (AWQ/FP8 param count x ~4-8 bits +
overhead); see `lib/launch.sh`'s `PRESET_TABLE` for the exact HF repos.

| Preset | Approx. weights | Min GPU (VRAM) | Suggested volume |
|---|---|---|---|
| `deepseek-r1-distill-32b` | ~19GB | 24GB (RTX 4090) | 60GB |
| `qwen3-32b` | ~19GB | 24GB (RTX 4090) | 60GB |
| `qwen3-coder-30b-moe` | ~17GB | 24GB (RTX 4090) | 60GB |
| `qwen2.5-72b` | ~41GB | 48GB (A6000/L40S) | 100GB |
| `llama3.3-70b` | ~39GB | 48GB (A6000/L40S) | 100GB |
| `qwen3.5-40b-deckard` | ~40GB (bf16 repo, quantized to FP8 on the fly - no separate quant repo to size for) | 48GB (A6000/L40S) | 100GB |
| Several presets cached side by side | - | - | 150-200GB |
| `custom` (any HF repo) | depends on the model | you decide | the launch wizard prompts to grow the volume if needed (RunPod only allows growing, never shrinking, and it's a billed, permanent change) |

The min-GPU column is a hard floor the wizard filters `runpodctl gpu
list` against - it's not a comfort recommendation. A 24GB card running
a ~19GB-weight preset has only a few GB left for KV cache, which limits
how much context you can actually request; a bigger card in the same
tier buys more context headroom. The context-length prompt during
launch defaults to a conservative value per preset for exactly this
reason - bump it if you picked a bigger card than the floor.

`CONTAINER_DISK_GB` in `lib/launch.sh` (currently 40GB) is separate
from the network volume and only needs to hold the OS and the
`vllm/vllm-openai` image's own CUDA/PyTorch/vLLM stack - model weights
always live on the network volume (`HF_HOME`), not the container disk.
Not yet measured against a real pull; bump it if the image ends up
bigger than 40GB.

Once everything above exists, run `./startup.sh`. It detects there's no
local config yet and walks you through the rest.
