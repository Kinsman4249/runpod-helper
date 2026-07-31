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
   steps for creating the named Tunnel and the Access policy, then asks
   you to paste back the tunnel token.

## GitHub

1. Have a GitHub account with access to whichever repos this box should
   be able to push to.
2. Nothing else ahead of time. The wizard pauses and walks you through
   creating the GitHub App (which permissions, which repos to install it
   on, generating and saving the private key), then asks you to confirm
   the App ID and the key file path.

## Local machine

1. `bash`, `ssh`, `curl`, `tar`, and `git`. All standard on any Linux or
   macOS install, Bazzite included.
2. `~/.local/bin` on your `PATH`. Default on Fedora-family systems
   including Bazzite; check with `echo $PATH` if unsure. The wizard
   installs its tools there.
3. Everything else - `runpodctl`, `gh`, the `gh-token` gh extension, and
   `cloudflared` - is installed by the wizard as user-level binaries. No
   `sudo`, no package manager, no reboot. (`cloudflared` is needed
   locally, not just on the pod: it's what your SSH client proxies
   through to reach the pod without any open inbound ports.)

## One thing to decide before you start

The network volume is created in a specific RunPod datacenter and can
only be attached to pods in that same datacenter. That choice
constrains which GPUs are available to you later, since not every
datacenter stocks every card. The wizard will ask which datacenter to
use - if you already know you want a specific GPU tier (e.g. a 48GB card
for the larger model preset), check availability for that card first and
pick the datacenter accordingly, rather than picking one at random and
discovering the GPU you want isn't offered there.

Once everything above exists, run `./startup.sh`. It detects there's no
local config yet and walks you through the rest.
