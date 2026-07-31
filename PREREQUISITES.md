# Prerequisites

Everything below needs to exist before you run `startup.sh` for the
first time. `startup.sh`'s setup wizard handles almost everything else -
installing local tools, creating the network volume, walking you through
the GitHub App and Cloudflare steps - so this list is only the handful of
things that have to happen on each service's own website before the
wizard can take over.

## RunPod

1. Create a RunPod account.
2. Add a payment method (credit card). RunPod requires at least an
   hour's worth of credit before it will deploy a pod, and turning on
   auto-pay / low-balance alerts during the wizard needs a card on file
   anyway.
3. Generate an API key (Settings > API Keys). Keep it somewhere you can
   paste from - the wizard asks for it on first run and uses it for
   everything from there (installing itself, creating the volume,
   launching pods).

## Cloudflare

1. Have, or create, a Cloudflare account.
2. Have a domain added to that account. The Tunnel needs a hostname to
   publish under (e.g. `pod.yourdomain.com`) - if you don't have a domain
   in Cloudflare yet, this is the one item on this whole list that can't
   be skipped or deferred to the wizard.
3. That's it for pre-work. The wizard pauses at the right moment with
   the exact console steps to create the named Tunnel and the Access
   policy, and just asks you to paste back the tunnel token when you're
   done.

## GitHub

1. Have a GitHub account with access to whichever repos you want this
   box pushing to.
2. Nothing else ahead of time. The wizard pauses and walks you through
   creating the GitHub App (permissions, which repos to install it on,
   generating the private key), then just asks you to confirm the App ID
   and where you saved the key file.

## Local machine

1. Bash, `ssh`, and `curl`. Already present on essentially any Linux or
   macOS install, Bazzite included.
2. That's genuinely it. `runpodctl`, `gh`, and the `gh-token` extension
   all get installed by the wizard itself, as plain user-level binaries
   (no `sudo`, no package manager, no reboot - see the README for why
   that matters on an immutable-OS setup).

Once everything above exists, run `./startup.sh`. The first run detects
there's no local config yet and walks you through the rest.
