FROM docker.io/ubuntu:24.04

ARG COMFYUI_COMMIT
ARG DEBIAN_FRONTEND=noninteractive

# System dependencies only — no CUDA (PyTorch bundles its own, host driver via CDI)
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git ffmpeg aria2 curl \
    cmake ninja-build pkg-config gcc g++ \
    libgl1-mesa-dev libglib2.0-0 libssl-dev libffi-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

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
# --extra-index-url picks up torch/torchvision/torchaudio wheels (with bundled CUDA)
# from PyTorch's cu130 index; everything else comes from default PyPI.
RUN uv venv /app/.venv --python 3.13 \
    && uv pip install --python /app/.venv/bin/python \
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

EXPOSE 8188

ENTRYPOINT ["/app/.venv/bin/python", "main.py", "--listen", "0.0.0.0"]
CMD ["--port", "8188"]
