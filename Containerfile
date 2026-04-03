FROM docker.io/nvidia/cuda:13.0.0-runtime-ubuntu24.04

ARG COMFYUI_COMMIT
ARG DEBIAN_FRONTEND=noninteractive

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3.13 python3.13-venv python3.13-dev \
    git ffmpeg aria2 \
    cmake ninja-build pkg-config gcc g++ \
    libgl1-mesa-glx libglib2.0-0 libssl-dev libffi-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# Install uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Project files for dependency installation
WORKDIR /app
COPY pyproject.toml uv.lock ./

# Install Python dependencies (locked)
RUN uv sync --frozen --python python3.13 --extra manager

# Clone ComfyUI source at pinned commit
RUN git clone --depth 1 https://github.com/Comfy-Org/ComfyUI.git /app/src \
    && cd /app/src \
    && if [ -n "$COMFYUI_COMMIT" ]; then \
         git fetch origin "$COMFYUI_COMMIT" --depth 1 \
         && git checkout "$COMFYUI_COMMIT"; \
       fi

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
