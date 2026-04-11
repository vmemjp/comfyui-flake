# comfyui-flake

A Nix Flake for running [ComfyUI](https://github.com/Comfy-Org/ComfyUI) on Linux with direnv support.

ComfyUI Desktop does not ship Linux builds. This flake provides a reproducible, project-local setup using Nix + uv so you can run ComfyUI without polluting your system.

## Features

- **Reproducible dependencies** -- `pyproject.toml` + `uv.lock` ensure exact, lockfile-pinned installs via `uv sync`
- **Separated user data** -- models, custom_nodes, input, output, user live outside the source tree under `.comfyui-state/`, so updates are a simple source replacement
- **direnv-friendly** -- drop an `.envrc` with `use flake` and everything is ready
- **ComfyUI Manager** enabled by default

## Tested On

- NixOS 26.05.20260318.b40629e (Yarara)
- NVIDIA RTX 4070

## Prerequisites

- [Nix](https://nixos.org/) with flakes enabled
- NVIDIA GPU + drivers (for CUDA builds)

## Quick Start

The fastest way -- one command to initialize and launch:

```bash
git clone https://github.com/vmemjp/comfyui-flake
cd comfyui-flake
nix run .
```

On the first run, this automatically sets up the venv via `uv sync`, installs dependencies, and starts ComfyUI.

### Using a dev shell (alternative)

If you prefer separate init/run steps, or use direnv:

```bash
nix develop  # or: echo 'use flake' > .envrc && direnv allow

comfyui-init  # first-time setup
comfyui       # start ComfyUI
```

ComfyUI starts at `http://127.0.0.1:8188` by default.

## Commands

| Command | Description |
|---|---|
| `nix run .` | One-command bootstrap: init if needed, then start |
| `comfyui-init` | First-time setup: copy source, create symlinks, `uv sync` dependencies (dev shell) |
| `comfyui-update` | Update ComfyUI source and re-sync dependencies (user data is untouched) (dev shell) |
| `comfyui` | Start ComfyUI (dev shell) |
| `comfyui-container-build` | Build the Podman container image (dev shell) |
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

# 2. Sync dependency changes from upstream requirements.txt
./sync-requirements.sh

# 3. Rebuild the container (tags both :latest and :<new-commit>)
comfyui-container-build

# 4. Start the new version
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
2. **Upgrade and rebuild**: run the 4-step flow above
3. **Smoke-test** your critical workflows against the new build
4. **If something breaks**: `COMFYUI_TAG=<old-tag> comfyui-pod` to roll back, then investigate at your leisure
5. **After a stable period**: `podman rmi comfyui:<old-tag>` to reclaim disk space

## Configuration

All configuration is done via environment variables. Set them before running `comfyui-init` or `comfyui`.

### Network

```bash
COMFYUI_LISTEN=0.0.0.0 comfyui    # Listen on all interfaces
COMFYUI_PORT=9000 comfyui          # Use a different port
```

### All Variables

| Variable | Default | Description |
|---|---|---|
| `COMFYUI_STATE_DIR` | `$PWD/.comfyui-state` | Root directory for all state |
| `COMFYUI_LISTEN` | `127.0.0.1` | Listen address |
| `COMFYUI_PORT` | `8188` | Listen port |
| `COMFYUI_TAG` | `latest` | Container image tag to run (for rollback to a previous build) |
| `COMFYUI_HOME` | `$STATE_DIR/src` | ComfyUI source directory (native mode only) |
| `COMFYUI_ENABLE_MANAGER` | `1` | Enable ComfyUI Manager (`0` to disable) |

## Downloading Models

`aria2c` is included in the dev shell for fast parallel downloads:

```bash
aria2c -x 16 -s 16 -d .comfyui-state/models/checkpoints/ <URL>
```

## Project Structure

```
.
├── pyproject.toml          # Dependency management
├── uv.lock                 # Lockfile (committed)
├── flake.nix
├── flake.lock
└── .comfyui-state/         # Created by comfyui-init (gitignored)
    ├── src/                # ComfyUI source (replaced on update)
    │   ├── custom_nodes/ → ../custom_nodes  (symlink)
    │   ├── input/ → ../input                (symlink)
    │   ├── output/ → ../output              (symlink)
    │   ├── user/ → ../user                  (symlink)
    │   └── models/ → ../models              (symlink)
    ├── models/             # Model files
    ├── custom_nodes/       # Custom node extensions
    ├── input/              # Input images
    ├── output/             # Generated outputs
    └── user/               # User settings
```

All user data directories are symlinked from the source tree into `.comfyui-state/`.

## License

MIT
