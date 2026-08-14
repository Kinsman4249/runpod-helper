# image/Dockerfile - the pod image referenced by IMAGE_NAME in
# ../lib/launch.sh. Built and pushed by ../.github/workflows/build-image.yml,
# not built locally as part of a normal `startup.sh` run.
#
# Starts from vLLM's own official OpenAI-compatible server image instead of
# building a vLLM environment from scratch - it's the same image RunPod's
# own community "vLLM" pod templates all wrap (confirmed via
# `runpodctl template search vllm`, 2026-08-12: every result uses
# vllm/vllm-openai:latest), so it should already be layer-cached on most
# RunPod nodes. This image only adds the thin layer needed to reach it
# directly over its own 22/tcp and to self-manage idle shutdown: sshd
# (diagnostics) and runpodctl (idle-watchdog.sh's and the prewarm path's
# self stop/delete both call it - see entrypoint.sh). No Cloudflare
# anything - RunPod exposes both SSH (22/tcp) and the vLLM HTTP port on
# its own, no tunnel needed (see CHANGELOG.md).
FROM vllm/vllm-openai:latest

ENV DEBIAN_FRONTEND=noninteractive
# openssh-server: RunPod does NOT start sshd for you on a custom image -
# confirmed against docs.runpod.io/pods/configuration/use-ssh (checked
# 2026-08-01 for the prior image, still applies here), which explicitly
# says a custom template must install and start it itself. Kept for
# diagnostics (checking vLLM's logs, nvidia-smi) even though the normal
# workflow no longer needs an interactive session - see idle-watchdog.sh,
# which now tracks vLLM API activity instead of SSH sessions.
# iptables/iproute2: entrypoint.sh's lock_ssh_to_first_client() firewalls
# port 22 down to whichever IP connects first, using `ss` (iproute2) to
# spot that connection and `iptables` to lock it in.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates openssh-server iptables iproute2 \
    && rm -rf /var/lib/apt/lists/*

# runpodctl: confirmed install command against docs.runpod.io/runpodctl/
# install-runpodctl (checked 2026-08-01 for the prior image, still applies).
RUN curl -fsSL https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-amd64 \
      -o /usr/local/bin/runpodctl \
    && chmod +x /usr/local/bin/runpodctl

RUN mkdir -p /opt/runpod-lab /run/runpod-lab
COPY entrypoint.sh /opt/runpod-lab/entrypoint.sh
RUN chmod +x /opt/runpod-lab/entrypoint.sh

# The base image's own ENTRYPOINT runs `vllm serve` directly (confirmed via
# docs.vllm.ai/en/latest/deployment/frameworks/runpod/, 2026-08-12) and never
# gets a chance to start sshd/idle-watchdog first - so this image overrides
# ENTRYPOINT with our own script, which itself execs into `vllm serve` once
# those are up (see entrypoint.sh's last line).
ENTRYPOINT ["/opt/runpod-lab/entrypoint.sh"]
