---
name: comfyui-update
description: Check for ComfyUI updates, show changelog, and apply if approved
disable-model-invocation: true
allowed-tools: Bash, Read, Edit, Write
argument-hint: [--apply]
---

# ComfyUI Update

Check for upstream ComfyUI updates, analyze relevance, and apply.

If `$ARGUMENTS` contains `--apply`, skip the approval step and apply immediately.

## Current state

!`cd /srv/ssd1tb/work/comfyui && git log --oneline -1`
!`cd /srv/ssd1tb/work/comfyui && python3 -c "import json; d=json.load(open('flake.lock')); src=d['nodes']['comfyui-src']['locked']; print(f'comfyui-src: {src[\"rev\"][:12]} ({src[\"lastModified\"]})')"`

## Steps

### 1. Check for updates

Run `nix flake update comfyui-src` in `/srv/ssd1tb/work/comfyui`.

- If output contains "Updated input 'comfyui-src'": extract old and new full commit hashes from the URL-encoded lines. Continue.
- If no "Updated" line: say "Already up to date." and **stop**.

### 2. Get changelog and assess

Run:
```
gh api repos/Comfy-Org/ComfyUI/compare/OLD_HASH...NEW_HASH --jq '.commits[] | "- " + (.commit.message | split("\n")[0])'
```

Also check if this is a tagged release:
```
gh api repos/Comfy-Org/ComfyUI/tags --jq '.[0].name'
```

Present as a compact table with relevance to this setup:
- NVIDIA RTX 4070 (12GB VRAM)
- Uses Flux models, DynamicVram
- Linux / NixOS

Give one-line recommendation (update or skip).

### 3. Approval

If `--apply` was passed, proceed immediately.
Otherwise, ask **once**: "適用する?" and wait. Do NOT ask multiple questions.

### 4. Apply

Run in `/srv/ssd1tb/work/comfyui`:

```bash
comfyui-container-build
```

The container build reads the new commit from `flake.lock`, clones that
exact ComfyUI revision inside the container, and installs upstream
`requirements.txt` directly — no host-side sync step needed.

The build tags both `:latest` and `:<new-commit-short>`, and the previous
build remains available under its own `:<old-commit-short>` tag for
rollback via `COMFYUI_TAG=<old-tag> comfyui-pod`.

### 5. Commit

```bash
git add flake.lock
```

Commit message format — use the latest tag if available (e.g., `v0.17.1`), otherwise use the date:
```
Update ComfyUI to vX.Y.Z

- key change 1
- key change 2

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
```

Report the commit hash when done.
