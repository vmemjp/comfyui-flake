# Base image and uv are pinned by SHA256 digest so a compromise of
# docker.io/ubuntu or ghcr.io/astral-sh/uv cannot quietly enter a
# rebuild. Bump these intentionally (and review) when upgrading.
FROM docker.io/ubuntu:24.04@sha256:e21f810fa78c09944446ec02048605eb3ab1e4e2e261c387ecc7456b38400d79

ARG COMFYUI_COMMIT
ARG DEBIAN_FRONTEND=noninteractive

# System dependencies only — no CUDA (PyTorch bundles its own, host driver via CDI)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git ffmpeg aria2 curl \
    cmake ninja-build pkg-config gcc g++ \
    libgl1-mesa-dev libglib2.0-0 libssl-dev libffi-dev zlib1g-dev \
    iptables \
    && rm -rf /var/lib/apt/lists/*

# Install uv — pinned to version tag + SHA256 digest
COPY --from=ghcr.io/astral-sh/uv:0.11.6@sha256:43cb71695fcad1516c2fbe0f56e500184c42d8bce838d9f64593b8aff2c16298 /uv /usr/local/bin/uv

# Let uv manage Python 3.13
RUN uv python install 3.13

WORKDIR /app

# Clone ComfyUI source at the pinned commit
RUN git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git /app/src \
    && cd /app/src \
    && if [ -n "$COMFYUI_COMMIT" ]; then \
         git fetch origin "$COMFYUI_COMMIT" --depth 1 \
         && git checkout "$COMFYUI_COMMIT"; \
       fi

# Create venv and install dependencies directly from upstream requirements.txt.
#
# The PyTorch cu130 index also serves old (2022-era) wheels of common deps
# like urllib3/requests/certifi, so using it as an extra-index with the
# default "first-index" strategy causes those common deps to be resolved
# from cu130 instead of PyPI. --index-strategy unsafe-best-match tells uv
# to search both indexes and pick the newest version, which routes torch*
# to cu130 (2.x+cu130 > 2.x base) while keeping urllib3 et al. on PyPI.
RUN uv venv /app/.venv --python 3.13 \
    && uv pip install --python /app/.venv/bin/python \
         --index-strategy unsafe-best-match \
         --extra-index-url https://download.pytorch.org/whl/cu130 \
         -r /app/src/requirements.txt \
    && uv pip install --python /app/.venv/bin/python \
         comfyui-manager==4.1

# Remove default data dirs (will be mounted from host)
RUN rm -rf /app/src/models /app/src/custom_nodes /app/src/input /app/src/output /app/src/user

# Create mount points
RUN mkdir -p /data/models /data/custom_nodes /data/input /data/output /data/user

# Symlinks from source to mount points
RUN ln -s /data/models       /app/src/models \
    && ln -s /data/custom_nodes /app/src/custom_nodes \
    && ln -s /data/input        /app/src/input \
    && ln -s /data/output       /app/src/output \
    && ln -s /data/user         /app/src/user

WORKDIR /app/src

# Entrypoint wrapper: when COMFYUI_EGRESS=block is set (via podman --env),
# iptables drops all container-initiated outbound traffic while still allowing
# responses to inbound connections (host API/UI access).
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8188

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["--port", "8188"]
