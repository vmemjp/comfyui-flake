# comfyui-flake

A Nix Flake for running [ComfyUI](https://github.com/Comfy-Org/ComfyUI) on Linux with direnv support.

ComfyUI Desktop does not ship Linux builds. This flake provides a reproducible, project-local setup that runs ComfyUI inside a Podman container, keeping PyPI packages — and any compromised custom nodes — away from your host filesystem.

## Features

- **Container-isolated execution** -- ComfyUI and its PyPI dependencies run inside a Podman container with no access to your SSH keys, cloud credentials, or other host secrets
- **Reproducible by commit** -- the ComfyUI revision is pinned in `flake.lock`; every container build is tagged by that commit so upgrades can be rolled back instantly
- **Separated user data** -- models, custom_nodes, input, output, user live on the host under `.comfyui-state/` and are mounted into the container (models read-only)
- **direnv-friendly** -- drop an `.envrc` with `use flake` and everything is ready
- **ComfyUI Manager** enabled by default

## Tested On

- NixOS 26.05.20260318.b40629e (Yarara)
- NVIDIA RTX 4070

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- NVIDIA GPU + drivers (for CUDA builds)

## Quick Start

The fastest way -- one command to build and launch:

```bash
git clone https://github.com/vmemjp/comfyui-flake
cd comfyui-flake
nix run .
```

On the first run, this automatically builds the Podman container image (installing all dependencies inside the container) and starts ComfyUI.

### Using a dev shell (alternative)

If you prefer separate build/run steps, or use direnv:

```bash
nix develop  # or: echo 'use flake' > .envrc && direnv allow

comfyui-container-build  # first-time build (and after each upgrade)
comfyui-pod              # start ComfyUI in the container
```

ComfyUI starts at `http://127.0.0.1:8188` by default.

## Commands

| Command | Description |
|---|---|
| `nix run .` | One-command bootstrap: build image if missing, then start the container |
| `comfyui-container-build` | Build the Podman container image; tags `:latest` and `:<commit-short>` (dev shell) |
| `comfyui-pod` | Start ComfyUI in an isolated Podman container (dev shell) |

## Container Mode (Podman)

Run ComfyUI in an isolated container for supply-chain attack mitigation. The container has no access to your SSH keys, cloud credentials, or other host secrets.

```bash
# Prerequisites: hardware.nvidia-container-toolkit.enable = true; in NixOS config

comfyui-container-build   # build image (once, or after update)
comfyui-pod               # start in container
```

Models are mounted read-only, input/output/user are read-write. API and UI are available at `http://127.0.0.1:8188`.

Every build is tagged with both `:latest` and `:<commit-short>`, enabling rollback to any previous build. See [Updating ComfyUI](#updating-comfyui) for the rollback flow.

## Updating ComfyUI

Each container build is tagged with both `:latest` and `:<commit-short>` (the first 7 characters of the ComfyUI commit), so you can always roll back to a previous working version without rebuilding.

```bash
# 1. Update the flake input to the latest ComfyUI commit
nix flake update comfyui-src

# 2. Rebuild the container (tags both :latest and :<new-commit>)
#    The build clones ComfyUI at the new commit inside the container
#    and installs its requirements.txt directly — no host-side sync needed.
comfyui-container-build

# 3. Start the new version
comfyui-pod
```

User data (`models/`, `custom_nodes/`, `input/`, `output/`, `user/`) lives outside the container and is untouched by updates.

### Rolling back after a failed upgrade

If the new build breaks a workflow, start an older build by tag:

```bash
# List available builds
podman images comfyui
# REPOSITORY   TAG       CREATED
# comfyui      latest    2 minutes ago
# comfyui      a1b2c3d   2 minutes ago    ← new build (broken)
# comfyui      bbfbe3f   2 days ago       ← previous working build

# Roll back to a previous build
COMFYUI_TAG=bbfbe3f comfyui-pod
```

`:latest` always points to the most recent build. Older `:<commit-short>` tags persist until you delete them:

```bash
podman rmi comfyui:bbfbe3f   # remove once you're sure you don't need it
```

### Recommended upgrade flow

1. **Note the current tag** before upgrading: `podman images comfyui`
2. **Upgrade and rebuild**: run the steps above
3. **Smoke-test** your critical workflows against the new build
4. **If something breaks**: `COMFYUI_TAG=<old-tag> comfyui-pod` to roll back, then investigate at your leisure
5. **After a stable period**: `podman rmi comfyui:<old-tag>` to reclaim disk space

## Configuration

All configuration is done via environment variables. Set them before running `comfyui-container-build` or `comfyui-pod`.

### Network

```bash
COMFYUI_LISTEN=0.0.0.0 comfyui-pod   # Listen on all interfaces
COMFYUI_PORT=9000 comfyui-pod        # Use a different port
```

### All Variables

| Variable | Default | Description |
|---|---|---|
| `COMFYUI_STATE_DIR` | `$PWD/.comfyui-state` | Root directory for all state |
| `COMFYUI_LISTEN` | `127.0.0.1` | Listen address |
| `COMFYUI_PORT` | `8188` | Listen port |
| `COMFYUI_TAG` | `latest` | Container image tag to run (for rollback to a previous build) |
| `COMFYUI_NETWORK` | `default` | `blocked` = outbound traffic dropped via iptables, host API/UI still works (recommended for untrusted custom nodes); `none` = `--network=none`, no connectivity at all (podman exec only) |

## Downloading Models

`aria2c` is included in the dev shell for fast parallel downloads:

```bash
aria2c -x 16 -s 16 -d .comfyui-state/models/checkpoints/ <URL>
```

## Project Structure

```
.
├── flake.nix               # Dev shell + comfyui-pod / comfyui-container-build
├── flake.lock              # Pins the ComfyUI revision (source of truth for rebuilds)
├── Containerfile           # Clones ComfyUI and installs its requirements.txt inside the image
└── .comfyui-state/         # User data, mounted into the container (gitignored)
    ├── models/             # Model files (mounted read-only)
    ├── custom_nodes/       # Custom node extensions (mounted read-only)
    ├── input/              # Input images (read-write)
    ├── output/             # Generated outputs (read-write)
    └── user/               # User settings (read-write)
```

No ComfyUI source lives on the host — it is cloned at the pinned commit inside the container during `comfyui-container-build`.

## License

MIT
