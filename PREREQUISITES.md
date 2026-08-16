# Prerequisites

Everything below needs to exist before you run `startup.sh` for the
first time. The setup wizard in `startup.sh` handles everything else -
installing local tools, creating the network volume - so this list is
only what has to happen on RunPod's own website before the wizard can
take over. There's no third-party tunnel service in the picture at all
(see CHANGELOG.md for why Cloudflare was dropped): RunPod exposes the
vLLM HTTP endpoint directly, per pod, through its own proxy. There's no
sshd on the pod - it runs vLLM's bare official image with no wrapper -
so diagnostics use RunPod's SSH-over-proxy instead, which doesn't need
one (see `resolve_pod_ssh_proxy_host()` in `lib/common.sh`).

## RunPod

1. Create a RunPod account.
2. Add a payment method (credit card). RunPod requires at least an
   hour's worth of credit before it will deploy a pod, and enabling
   auto-pay / low-balance alerts needs a card on file anyway.
3. Generate an API key (Settings > API Keys). Keep it somewhere you can
   paste from - the wizard asks for it on first run and uses it for
   everything after that. This is the only credential you need to
   provide; everything else (the SSH keypair, the vLLM API key) is
   generated automatically per pod launch.

## Local machine

1. `bash`, `ssh`, `curl`, `openssl`. All standard on any Linux or macOS
   install, Bazzite included.
2. `~/.local/bin` on your `PATH`. Default on Fedora-family systems
   including Bazzite; check with `echo $PATH` if unsure. The wizard
   installs its tools there.
3. `runpodctl` is installed by the wizard as a user-level binary
   (downloaded release binary into `~/.local/bin`). No `sudo`, no
   package manager, no reboot.
4. `secret-tool` (package `libsecret-tools` on Debian/Ubuntu,
   `libsecret` on Fedora/Arch) NOT auto-installed by the wizard (it's a
   system package, not a standalone release binary) - the wizard dies
   with the exact package name if it's missing. RUNPOD_API_KEY is
   stored in the OS keyring via this tool instead of a plaintext file,
   which needs a running, unlocked Secret Service (GNOME Keyring or
   KWallet) in your session - true by default on a normal desktop
   login, not available in a headless shell or a container with no
   D-Bus session bus. If you're running these scripts from inside a
   container (e.g. a Distrobox/Toolbox dev environment), run them from
   the host session or a shell that has your desktop's D-Bus/keyring
   reachable instead.

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
| `qwen3-coder-30b-moe` | ~17GB | 24GB (RTX 4090) | 60GB |
| `qwen3.6-27b-awq-mtp` | ~18GB | 24GB (RTX 4090/L4) | 60GB |
| `qwen3.5-40b-deckard-gguf` | ~27GB (Q5_K_S GGUF) | 48GB (A6000/L40S) | 100GB |
| `qwen3.5-40b-deckard-gguf-40gb` | ~27GB (Q5_K_S GGUF) | 40GB (A40/L4) | 100GB |
| `qwen3.6-40b-deckard-eleanor-gguf` | ~27GB (Q5_K_S GGUF) | 48GB (A6000/L40S) | 100GB |
| `qwen3.6-40b-deckard-eleanor-gguf-40gb` | ~27GB (Q5_K_S GGUF) | 40GB (A40/L4) | 100GB |
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
