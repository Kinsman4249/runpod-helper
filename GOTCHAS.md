# Gotchas

Non-obvious facts about RunPod's platform and this repo's dependencies,
confirmed live, that would otherwise cost someone a repeat debugging session.
Architecture and feature history live in CHANGELOG.md; this file is just the
"it looks broken but it's actually this" list.

## SSH-over-proxy uses the pod-host-id as the username, not a subdomain

The correct form is:

```
ssh <pod-host-id>@ssh.runpod.io -i <key>
```

where `<pod-host-id>` is `resolve_pod_ssh_proxy_host()`'s `SSH_PROXY_HOST`
(`lib/common.sh`) - a single shared hostname (`ssh.runpod.io`), with the
per-pod identifier as the *username*, not `root@<pod-host-id>.ssh.runpod.io`.
The latter does not resolve at all (confirmed live 2026-08-15) - it looks
like a DNS/network problem from a given dev machine, but it isn't; the
address format itself was wrong. Also requires a real PTY: a piped command
argument is rejected outright, or silently ignored and drops into an
interactive shell (`-tt`) - not scriptable as a single command, but a
heredoc piping multiple commands into an allocated PTY works.

## A RunPod pod does not stop when its own process exits

Confirmed live 2026-08-14 (probe pod, `alpine:3.19`, `sh -c 'sleep 25'`):
`uptimeSeconds` stayed pinned at 0 for 90+ seconds after the process exited -
the pod crash-loops instead of going to `EXITED`. Don't rely on process exit
as a "job finished" signal from the local machine; poll an HTTP endpoint the
container serves instead (see `lib/prewarm.sh`'s design-constraint comment).

## RunPod CPU pods are always 2 vCPU / 4GB RAM

`runpodctl pod create --compute-type CPU` gives no way to size a CPU pod -
`--gpu-id` is rejected outright alongside `--compute-type cpu`, and there's
no other sizing flag in `runpodctl pod create --help`. Confirmed live
2026-08-14: every CPU pod comes back as 2 vCPU/4GB regardless of what's
requested.

## EU-RO-1 has no High-Performance network volume tier

Standard tier is the ceiling for network volumes created in that datacenter -
confirmed when replacing a dead volume there. If a preset needs faster
network-volume throughput than standard tier gives, it needs a different
datacenter.

## vLLM 0.27.1 rejects `--quantization auto` against a repo with its own quantization_method

If a model repo's `config.json` already declares `quantization_method`
explicitly, passing `--quantization auto` anyway produces a pydantic
`ValidationError` and the pod boot-loops. Confirmed live against
`qwen3.6-27b-awq-mtp` and `qwen3-coder-30b-moe` - both preset entries in
`lib/launch.sh`'s `PRESET_TABLE` pin their real method instead of `auto`.

## `printf '%q'` output can't be parsed by the pod's actual shell

Bash's `printf '%q'` emits `$'...'` ANSI-C quoting. The official vLLM/
llama.cpp images' `/bin/sh` is dash, which can't parse that quoting form.
Reproduce any new `--docker-args` or entrypoint string locally with
`podman run` against the same base image before it ever touches a billed
pod - this and the next entry were both caught that way for free.

## `huggingface-cli` is deprecated in favor of `hf`

The pinned `huggingface_hub` version used by the prewarm images warns and
eventually will not resolve `huggingface-cli` as a command - use `hf
download <repo>` instead.

## `load_secrets()` sets `RUNPOD_API_KEY` but does not export it

Confirmed live 2026-08-15, self-inflicted: sourcing `lib/common.sh` and
calling `load_secrets()` in an ad-hoc shell (outside `startup.sh`) populates
`RUNPOD_API_KEY` but leaves it unexported, so a subprocess `runpodctl` call
falls back to whatever's cached in `~/.runpod/config.toml` and 401s if that's
stale - not a bug, `startup.sh` already does `export RUNPOD_API_KEY` right
after its own `load_secrets` call for exactly this reason (see its comment).
Any one-off diagnostic shell reusing these lib functions needs the same
explicit `export` before calling `runpodctl` directly.

## Diagnostics only work with a live pod, not after teardown

If a launch or e2e-test run times out or fails ambiguously, SSH into the pod
(see above) or check the RunPod console's pod logs *before* the script tears
it down, rather than guessing at the cause from an HTTP status code alone -
timeouts have turned out to be "still mid-download", not "stuck" or "OOMing",
more than once.
