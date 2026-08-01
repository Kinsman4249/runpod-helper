# image/Dockerfile - the paired OpenHands + llama.cpp pod image referenced
# by IMAGE_NAME in ../lib/launch.sh. Built and pushed by
# ../.github/workflows/build-image.yml, not built locally as part of a
# normal `startup.sh` run.
#
# Starts from llama.cpp's own official CUDA server image instead of
# compiling llama.cpp from source - it already ships a working `llama-server`
# binary with CUDA offload, confirmed against ggml-org/llama.cpp's own
# docs/docker.md (2026-07-30). Assumes that image is Debian/Ubuntu-based
# (apt-get available) - if a future llama.cpp release changes that, the
# `docker build` sanity check (see this repo's plan/handoff notes) will fail
# loudly right away, not silently.
FROM ghcr.io/ggml-org/llama.cpp:server-cuda

# Deliberately minimal: gh, cloudflared, uv, and the uv-managed Python +
# OpenHands/Open WebUI tool environments all used to be installed here at
# build time, making every image pull slow and re-downloading the same
# multi-GB toolchain on every rebuild. They're now installed at container
# *runtime* by entrypoint.sh's ensure_tools(), straight onto the network
# volume (/workspace/persistent) instead of this image's disposable
# container-disk layer - so they're downloaded once per volume, not once
# per image pull, and a cheap CPU pod can do that work up front (see
# maybe_run_prewarm() in ../lib/launch.sh) instead of paying GPU rates for
# it. curl/ca-certificates are all this image needs to bootstrap that at
# runtime; git is needed directly in-image for safety-commit.sh.
ENV DEBIAN_FRONTEND=noninteractive
# openssh-server: RunPod does NOT start sshd for you on a custom image -
# confirmed against docs.runpod.io/pods/configuration/use-ssh (2026-08-01),
# which explicitly says a custom template must install and start it itself.
# Installed at build time (small, stable, no reason to defer to the
# volume-cached runtime installs below); entrypoint.sh starts it.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates git openssh-server \
    && rm -rf /var/lib/apt/lists/*

# runpodctl itself - idle-watchdog.sh's self stop/delete and entrypoint.sh's
# PREWARM_ONLY self-termination both call it, but nothing was ever actually
# installing it inside the pod (confirmed missing live, 2026-08-01 - this
# would have silently broken the idle-shutdown safety mechanism on its very
# first real trigger). Install command confirmed against
# docs.runpod.io/runpodctl/install-runpodctl (2026-08-01, curl in place of
# their documented wget - same binary, this image already has curl).
RUN curl -fsSL https://github.com/runpod/runpodctl/releases/latest/download/runpodctl-linux-amd64 \
      -o /usr/local/bin/runpodctl \
    && chmod +x /usr/local/bin/runpodctl

# --- this repo's scripts -----------------------------------------------------
RUN mkdir -p /opt/runpod-lab /run/runpod-lab

# onstart.sh is fetched fresh from this repo's main branch AT BUILD TIME,
# then frozen into the image layer - that's what "baked into the image, not
# fetched" means in onstart.sh's own header comment. idle-watchdog.sh and
# safety-commit.sh stay runtime-fetched by onstart.sh itself on every boot,
# unchanged by this.
ADD https://raw.githubusercontent.com/Kinsman4249/runpod-helper/main/onstart.sh \
    /opt/runpod-lab/onstart.sh

COPY entrypoint.sh /opt/runpod-lab/entrypoint.sh
COPY presets.conf /opt/runpod-lab/presets.conf
RUN chmod +x /opt/runpod-lab/onstart.sh /opt/runpod-lab/entrypoint.sh

# The base image sets ENTRYPOINT ["/app/llama-server"] (confirmed against
# ggml-org/llama.cpp's .devops/cuda.Dockerfile server target, 2026-07-31) and
# never gets overridden by a plain CMD - CMD is just appended as arguments to
# the inherited ENTRYPOINT, so without this the container actually ran
# `llama-server /opt/runpod-lab/entrypoint.sh`, which llama-server rejected
# as an unrecognized flag on every start (`error: invalid argument`).
ENTRYPOINT ["/opt/runpod-lab/entrypoint.sh"]
