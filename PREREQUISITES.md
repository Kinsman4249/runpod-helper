# Prerequisites

Everything below needs to exist before you run `startup.sh` for the
first time. The setup wizard in `startup.sh` handles almost everything
else - installing local tools, creating the network volume, walking you
through the GitHub App and Cloudflare steps - so this list is only what
has to happen on each service's own website before the wizard can take
over.

## RunPod

1. Create a RunPod account.
2. Add a payment method (credit card). RunPod requires at least an
   hour's worth of credit before it will deploy a pod, and enabling
   auto-pay / low-balance alerts needs a card on file anyway.
3. Generate an API key (Settings > API Keys). Keep it somewhere you can
   paste from - the wizard asks for it on first run and uses it for
   everything after that.
4. Have an SSH keypair on your machine (`ls ~/.ssh/id_ed25519.pub`, or
   `ssh-keygen -t ed25519` if you don't have one). RunPod pods are
   reached over SSH and the public key has to be registered on your
   RunPod account. The wizard can register it for you, but the keypair
   itself has to exist first.

## Cloudflare

1. Have, or create, a Cloudflare account. The free plan is sufficient.
2. Have a domain added to that account. The Tunnel needs a hostname to
   publish under (e.g. `pod.yourdomain.com`). This is the one item on
   this list that genuinely can't be deferred to the wizard - without a
   domain in Cloudflare, there's nothing for a named Tunnel to attach
   to.
3. Nothing else ahead of time. The wizard pauses with the exact console
   steps for creating the named Tunnel, adding two Public Hostname routes
   on it (one for SSH -> `localhost:22`, one for the frontend (OpenHands,
   llama.cpp's built-in UI, or Open WebUI, whichever you pick at launch)
   -> `localhost:3000`), and setting up an Access policy covering both,
   then asks you to paste back the SSH hostname and the tunnel token.

   In brief, what that involves: Networking > Tunnels > Create a tunnel
   (Cloudflared connector, named, not the quick/trycloudflare kind) ->
   copy the tunnel token from the install command shown (or later from the
   tunnel's Overview page) -> add the two Public Hostname routes described
   above under the tunnel's "Public Hostname" tab -> then, under Zero Trust
   > Access > Applications, add an application, stay on the "Self-hosted
   and private" tab of the type-picker modal (the Private
   destinations/Workers/Public DNS/Service auth sub-tabs there are just
   examples, not choices you need to make) and click "Continue with
   Self-hosted and private" -> on the Destinations section, add the SSH
   subdomain as a public hostname, then click "+ Add public hostname" to
   add the frontend subdomain too (one app supports up to 5 destinations,
   so a single Access application can cover both; ignore the unrelated
   "Workers" section) -> add a policy that allows only your own email ->
   save. Skipping the Access step leaves localhost:22 and the frontend
   reachable by anyone who finds the hostname. Sanity check on the
   tunnel's "Routes" tab afterward: both hostnames should show a
   "Published application" badge, confirming the Access policy actually
   attached to them - if either is missing the badge, go back and fix
   that hostname's Access application before continuing.

   Port 3000 is fixed regardless of which frontend you pick at launch
   (`openhands` / `llama-webui` / `open-webui`, see `lib/launch.sh`'s
   `pick_preset_and_gpu()`) - `image/entrypoint.sh` always binds whichever
   one is chosen to that port, so the second Public Hostname route above
   never needs to change when you switch frontends between launches.

## GitHub

1. Have a GitHub account with access to whichever repos this box should
   be able to push to.
2. Nothing else ahead of time. The wizard pauses and walks you through
   creating the GitHub App (Contents: Read and write, Pull requests: Read
   and write, installed only on the specific repos this box should touch),
   generating and downloading its private key, then asks you to confirm the
   App ID and the key file path. It looks up the installation ID for you
   automatically (via the `gh-token` extension's `installations` command,
   using the key you just gave it) rather than asking you to hunt for that
   number yourself - you just confirm which installation it found.

   The app is only ever used to mint installation tokens for git push/PR
   operations - it never receives inbound events. So on the "New GitHub
   App" form: leave Callback URL blank, and uncheck Webhook > Active
   (leaving Webhook URL/Secret empty is fine once it's inactive).

   When the wizard looks up the installation, check the
   `repository_selection` field in its output: it should say `selected`,
   not `all`. If it says `all`, the App got installed on every repo
   instead of just the ones this box should touch - fix it at
   `https://github.com/settings/installations/<id>` (Repository access ->
   Only select repositories) before continuing.

## Local machine

1. `bash`, `ssh`, `curl`, `tar`, and `git`. All standard on any Linux or
   macOS install, Bazzite included.
2. `~/.local/bin` on your `PATH`. Default on Fedora-family systems
   including Bazzite; check with `echo $PATH` if unsure. The wizard
   installs its tools there.
3. Everything else - `runpodctl`, `gh`, the `gh-token` gh extension, and
   `cloudflared` - is installed by the wizard as user-level binaries
   (downloaded release binaries into `~/.local/bin`). No `sudo`, no
   package manager, no reboot. (`cloudflared` is needed locally, not just
   on the pod: it's what your SSH client proxies through to reach the pod
   without any open inbound ports, via `cloudflared access ssh`.)

## One thing to decide before you start

The network volume is created in a specific RunPod datacenter and can
only be attached to pods in that same datacenter. That choice
constrains which GPUs are available to you later, since not every
datacenter stocks every card. The wizard will ask which datacenter to
use - if you already know you want a specific GPU tier (e.g. a 48GB card
for the larger model preset), check availability for that card first and
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
latency for interactive SSH/coding-agent use.

### GPU tier and volume size, for this repo's two presets

Sizing based on the dense Qwen3.6-27B and Qwen3-Coder-Next (MoE, ~30B
total/~3B active) presets this repo ships:

| Precision | Weights (approx, either preset) | GPU tier that fits | Volume size |
|---|---|---|---|
| 4-bit (GGUF Q4, default) | ~17-20GB | 24GB card (RTX 4090) | 60GB |
| 8-bit | ~31-33GB | 32-48GB card | 100GB |
| fp16 | ~61-65GB | 80GB+ card (RTX PRO 6000, H100/H200) | 100GB |
| Both presets kept side by side, or fp16 + a quantized copy | - | - | 150-200GB |

`CONTAINER_DISK_GB` in `lib/launch.sh` (currently 25GB) is separate from
the volume and only needs to hold the OS, `llama.cpp`, and all three
frontends (OpenHands, llama.cpp's built-in UI, Open WebUI - only one runs
per pod, but the image ships all three so you can switch on the next
launch without a rebuild) - model weights always live on the network
volume, not the container disk. Not yet measured against a real build;
bump this if the image ends up bigger than 25GB.
A first-time model download can briefly need close to 2x the weight size
(source cache + destination copy) unless you download directly to the
volume path without an intermediate cache, so don't size the volume down
to the bare minimum.

Once everything above exists, run `./startup.sh`. It detects there's no
local config yet and walks you through the rest.
