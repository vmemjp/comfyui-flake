#!/usr/bin/env bash
# sync-requirements.sh — Sync upstream requirements.txt into pyproject.toml
#
# Usage:
#   ./sync-requirements.sh                     # uses .comfyui-state/src/requirements.txt
#   ./sync-requirements.sh /path/to/req.txt    # explicit path
#   ./sync-requirements.sh --manager /path/to/manager_req.txt  # sync manager group
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${COMFYUI_STATE_DIR:-$SCRIPT_DIR/.comfyui-state}"

# --- Parse args ---
MANAGER_MODE=false
REQ_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager) MANAGER_MODE=true; shift ;;
    *) REQ_FILE="$1"; shift ;;
  esac
done

if $MANAGER_MODE; then
  REQ_FILE="${REQ_FILE:-$STATE_DIR/src/manager_requirements.txt}"
else
  REQ_FILE="${REQ_FILE:-$STATE_DIR/src/requirements.txt}"
fi

if [[ ! -f "$REQ_FILE" ]]; then
  echo "error: $REQ_FILE not found" >&2
  exit 1
fi

# --- Parse requirements.txt into normalized package names ---
parse_requirements() {
  grep -v '^\s*#' "$1" | grep -v '^\s*$' | sed 's/\s*#.*//' | while read -r line; do
    echo "$line"
  done
}

# Normalize: lowercase, underscores → hyphens, strip version spec
normalize_name() {
  echo "$1" | sed -E 's/[><=~!].*//' | tr '[:upper:]' '[:lower:]' | tr '_' '-'
}

# --- Read current state ---
PYPROJECT="$SCRIPT_DIR/pyproject.toml"
if [[ ! -f "$PYPROJECT" ]]; then
  echo "error: $PYPROJECT not found" >&2
  exit 1
fi

# Get current deps from pyproject.toml (normalized names)
if $MANAGER_MODE; then
  current_section="manager"
else
  current_section="main"
fi

get_current_deps() {
  if [[ "$current_section" == "main" ]]; then
    # Extract dependencies array
    python3 -c "
import tomllib, sys
with open('$PYPROJECT', 'rb') as f:
    data = tomllib.load(f)
for dep in data.get('project', {}).get('dependencies', []):
    print(dep)
"
  else
    python3 -c "
import tomllib, sys
with open('$PYPROJECT', 'rb') as f:
    data = tomllib.load(f)
for dep in data.get('project', {}).get('optional-dependencies', {}).get('$current_section', []):
    print(dep)
"
  fi
}

# Build sets of normalized names
declare -A upstream_pkgs   # name -> full spec from requirements.txt
declare -A current_pkgs    # name -> full spec from pyproject.toml

while read -r spec; do
  [[ -z "$spec" ]] && continue
  name="$(normalize_name "$spec")"
  upstream_pkgs["$name"]="$spec"
done < <(parse_requirements "$REQ_FILE")

while read -r spec; do
  [[ -z "$spec" ]] && continue
  name="$(normalize_name "$spec")"
  current_pkgs["$name"]="$spec"
done < <(get_current_deps)

# --- Diff ---
to_add=()
to_remove=()
to_update=()

for name in "${!upstream_pkgs[@]}"; do
  if [[ -z "${current_pkgs[$name]+x}" ]]; then
    to_add+=("${upstream_pkgs[$name]}")
  elif [[ "${upstream_pkgs[$name]}" != "${current_pkgs[$name]}" ]]; then
    to_update+=("${upstream_pkgs[$name]}")
  fi
done

for name in "${!current_pkgs[@]}"; do
  if [[ -z "${upstream_pkgs[$name]+x}" ]]; then
    to_remove+=("$name")
  fi
done

# --- Report ---
if [[ ${#to_add[@]} -eq 0 && ${#to_remove[@]} -eq 0 && ${#to_update[@]} -eq 0 ]]; then
  echo "Already in sync."
  exit 0
fi

if [[ ${#to_add[@]} -gt 0 ]]; then
  echo "Add:    ${to_add[*]}"
fi
if [[ ${#to_remove[@]} -gt 0 ]]; then
  echo "Remove: ${to_remove[*]}"
fi
if [[ ${#to_update[@]} -gt 0 ]]; then
  echo "Update: ${to_update[*]}"
fi

# --- Apply (metadata only — no install on host) ---
GROUP_FLAG=""
if $MANAGER_MODE; then
  GROUP_FLAG="--optional manager"
fi

if [[ ${#to_remove[@]} -gt 0 ]]; then
  uv remove --no-sync $GROUP_FLAG "${to_remove[@]}"
fi

if [[ ${#to_add[@]} -gt 0 ]]; then
  uv add --no-sync $GROUP_FLAG "${to_add[@]}"
fi

if [[ ${#to_update[@]} -gt 0 ]]; then
  uv add --no-sync $GROUP_FLAG "${to_update[@]}"
fi

echo "Done. Rebuild container: comfyui-container-build"
