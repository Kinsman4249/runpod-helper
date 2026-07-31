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

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# --- uv + Python-based frontends --------------------------------------------
# uv's official installer (astral.sh) - same tool OpenHands' own docs assume
# (docs.openhands.dev/openhands/usage/run-openhands/local-setup, confirmed
# 2026-07-30: "uv tool install openhands --python 3.12").
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

RUN uv tool install openhands --python 3.12 \
    && uv tool install open-webui --python 3.12

# --- gh CLI and cloudflared --------------------------------------------------
# Same install steps as ../onstart.sh's own gh/cloudflared blocks, kept
# side by side deliberately so the two don't drift apart - the difference
# here is WHEN they run (image build time, once) vs there (every boot, as a
# no-op once already present).
RUN gh_url="$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest \
      | grep -o '"browser_download_url": *"[^"]*linux_amd64\.tar\.gz"' \
      | sed -E 's/.*"(https[^"]+)"/\1/' | head -n1)" \
    && tmp_dir="$(mktemp -d)" \
    && curl -fsSL "$gh_url" -o "$tmp_dir/gh.tar.gz" \
    && tar -xzf "$tmp_dir/gh.tar.gz" -C "$tmp_dir" \
    && install -m 755 "$(find "$tmp_dir" -type f -name gh -perm -u+x | head -n1)" /usr/local/bin/gh \
    && rm -rf "$tmp_dir"

RUN curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" \
      -o /usr/local/bin/cloudflared \
    && chmod +x /usr/local/bin/cloudflared

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

CMD ["/opt/runpod-lab/entrypoint.sh"]
