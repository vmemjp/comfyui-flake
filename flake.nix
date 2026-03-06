{
  description = "ComfyUI dev env (uv project; separated user data; py3.13 default w/ 3.12 switch)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    comfyui-src.url = "github:Comfy-Org/ComfyUI";
    comfyui-src.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, comfyui-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        python312 = pkgs.python312;
        python313 = pkgs.python313;
        uv = pkgs.uv;

        basePkgs = with pkgs; [
          uv
          python312
          python313
          git
          ffmpeg
          aria2
          oxipng
          mozjpeg

          cmake
          ninja
          pkg-config
          stdenv.cc
          stdenv.cc.cc.lib
          zlib
          openssl
          libffi
          glib
          libGL
        ];

        # Helper: resolve FLAKE_DIR at runtime (set by wrapper / devShell)
        # All scripts expect FLAKE_DIR to point at the flake repo root.

        setupSourceScript = ''
          # migrate_data: move real dirs from src/ to STATE_DIR/ (existing install)
          migrate_data() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"
            local DATA_DIRS=(custom_nodes input output user models)

            for d in "''${DATA_DIRS[@]}"; do
              # Only migrate if it's a real directory (not already a symlink)
              if [ -d "$COMFYUI_HOME/$d" ] && [ ! -L "$COMFYUI_HOME/$d" ]; then
                if [ -d "$STATE_DIR/$d" ] && [ -n "$(ls -A "$STATE_DIR/$d" 2>/dev/null)" ]; then
                  # State dir already has data — merge (src files won't overwrite)
                  cp -a --no-clobber "$COMFYUI_HOME/$d/." "$STATE_DIR/$d/" 2>/dev/null || true
                else
                  mkdir -p "$STATE_DIR"
                  mv "$COMFYUI_HOME/$d" "$STATE_DIR/$d"
                fi
              fi
            done
          }

          # setup_links: create symlinks + extra_model_paths.yaml inside src/
          setup_links() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"

            # Ensure state-side dirs exist
            local DATA_DIRS=(custom_nodes input output user models)
            for d in "''${DATA_DIRS[@]}"; do
              mkdir -p "$STATE_DIR/$d"
            done

            # Symlink all data dirs (custom_nodes, input, output, user, models)
            for d in custom_nodes input output user models; do
              rm -rf "''${COMFYUI_HOME:?}/$d"
              ln -sfn "../$d" "$COMFYUI_HOME/$d"
            done
          }

          # setup_source: fresh install — copy source, seed data, set up links
          setup_source() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"

            # Copy ComfyUI source
            mkdir -p "$(dirname "$COMFYUI_HOME")"
            cp -a "${comfyui-src}" "$COMFYUI_HOME"
            chmod -R u+rwX "$COMFYUI_HOME" || true

            # Seed user-data dirs from source defaults (only if state dir is empty)
            local SEED_DIRS=(custom_nodes input output user models)
            for d in "''${SEED_DIRS[@]}"; do
              mkdir -p "$STATE_DIR/$d"
              if [ -d "$COMFYUI_HOME/$d" ] && [ -z "$(ls -A "$STATE_DIR/$d" 2>/dev/null)" ]; then
                cp -a "$COMFYUI_HOME/$d/." "$STATE_DIR/$d/" 2>/dev/null || true
              fi
            done

            setup_links "$STATE_DIR" "$COMFYUI_HOME"
          }
        '';

        comfyui-init = pkgs.writeShellApplication {
          name = "comfyui-init";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"

            COMFYUI_PYTHON="''${COMFYUI_PYTHON:-3.13}"
            case "$COMFYUI_PYTHON" in
              3.13) PY_BIN="${python313}/bin/python" ;;
              3.12) PY_BIN="${python312}/bin/python" ;;
              *)
                echo "Unsupported COMFYUI_PYTHON=$COMFYUI_PYTHON (use 3.13 or 3.12)"
                exit 2
                ;;
            esac

            mkdir -p "$STATE_DIR"

            ${setupSourceScript}

            if [ ! -d "$COMFYUI_HOME" ]; then
              # Fresh install
              setup_source "$STATE_DIR" "$COMFYUI_HOME"
            elif [ -d "$COMFYUI_HOME/models" ] && [ ! -L "$COMFYUI_HOME/models" ]; then
              # Existing install without symlinks — migrate data out, then set up links
              echo "Migrating user data from source tree..."
              migrate_data "$STATE_DIR" "$COMFYUI_HOME"
              setup_links "$STATE_DIR" "$COMFYUI_HOME"
              echo "Migration complete."
            fi

            # Remove old per-version venvs (superseded by uv-managed .venv)
            for old_venv in "$STATE_DIR"/venv-py*; do
              if [ -d "$old_venv" ]; then
                echo "Removing old venv: $old_venv"
                rm -rf "$old_venv"
              fi
            done

            # Install dependencies via uv sync (project-managed venv)
            uv sync --project "$FLAKE_DIR" --python "$PY_BIN"

            # Manager optional deps
            if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ]; then
              uv sync --project "$FLAKE_DIR" --python "$PY_BIN" --extra manager
            fi

            echo "ComfyUI ready."
            echo "  Source: $COMFYUI_HOME"
            echo "  Venv:   $FLAKE_DIR/.venv"
          '';
        };

        comfyui-update = pkgs.writeShellApplication {
          name = "comfyui-update";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"

            COMFYUI_PYTHON="''${COMFYUI_PYTHON:-3.13}"
            case "$COMFYUI_PYTHON" in
              3.13) PY_BIN="${python313}/bin/python" ;;
              3.12) PY_BIN="${python312}/bin/python" ;;
              *)
                echo "Unsupported COMFYUI_PYTHON=$COMFYUI_PYTHON (use 3.13 or 3.12)"
                exit 2
                ;;
            esac

            if [ ! -d "$COMFYUI_HOME" ]; then
              echo "ComfyUI not found. Run: comfyui-init"
              exit 1
            fi

            ${setupSourceScript}

            echo "Updating ComfyUI source..."

            # Migrate data out if this is an old-style install
            if [ -d "$COMFYUI_HOME/models" ] && [ ! -L "$COMFYUI_HOME/models" ]; then
              echo "Migrating user data from source tree first..."
              migrate_data "$STATE_DIR" "$COMFYUI_HOME"
            fi

            # User data is outside src, so we can safely replace it
            rm -rf "$COMFYUI_HOME"
            setup_source "$STATE_DIR" "$COMFYUI_HOME"

            # Re-sync dependencies
            uv sync --project "$FLAKE_DIR" --python "$PY_BIN"

            if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ]; then
              uv sync --project "$FLAKE_DIR" --python "$PY_BIN" --extra manager
            fi

            echo "ComfyUI updated."
            echo "  Source: $COMFYUI_HOME"
            echo "  Venv:   $FLAKE_DIR/.venv"
          '';
        };

        comfyui-run = pkgs.writeShellApplication {
          name = "comfyui";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"
            VENV_DIR="$FLAKE_DIR/.venv"

            if [ ! -x "$VENV_DIR/bin/python" ]; then
              echo "venv not found. Run: comfyui-init"
              exit 1
            fi

            cd "$COMFYUI_HOME"

            if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ] && [ -f manager_requirements.txt ]; then
              ENABLE_MANAGER_ARGS="--enable-manager"
            else
              ENABLE_MANAGER_ARGS=""
            fi

            LISTEN="''${COMFYUI_LISTEN:-127.0.0.1}"
            PORT="''${COMFYUI_PORT:-8188}"

            exec "$VENV_DIR/bin/python" main.py \
              --listen "$LISTEN" --port "$PORT" \
              $ENABLE_MANAGER_ARGS "$@"
          '';
        };
      in
      {
        apps.default = {
          type = "app";
          program = "${pkgs.writeShellApplication {
            name = "comfyui-app";
            runtimeInputs = basePkgs;
            text = ''
              set -euo pipefail

              export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

              # Detect flake directory from script location
              FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
              export UV_CACHE_DIR="''${UV_CACHE_DIR:-$FLAKE_DIR/.cache/uv}"
              STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
              COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"
              VENV_DIR="$FLAKE_DIR/.venv"

              COMFYUI_PYTHON="''${COMFYUI_PYTHON:-3.13}"
              case "$COMFYUI_PYTHON" in
                3.13) PY_BIN="${python313}/bin/python" ;;
                3.12) PY_BIN="${python312}/bin/python" ;;
                *)
                  echo "Unsupported COMFYUI_PYTHON=$COMFYUI_PYTHON (use 3.13 or 3.12)"
                  exit 2
                  ;;
              esac

              ${setupSourceScript}

              # Init if needed
              if [ ! -x "$VENV_DIR/bin/python" ]; then
                echo "First run: initializing ComfyUI..."
                mkdir -p "$STATE_DIR"

                if [ ! -d "$COMFYUI_HOME" ]; then
                  setup_source "$STATE_DIR" "$COMFYUI_HOME"
                elif [ -d "$COMFYUI_HOME/models" ] && [ ! -L "$COMFYUI_HOME/models" ]; then
                  echo "Migrating user data from source tree..."
                  migrate_data "$STATE_DIR" "$COMFYUI_HOME"
                  setup_links "$STATE_DIR" "$COMFYUI_HOME"
                fi

                uv sync --project "$FLAKE_DIR" --python "$PY_BIN"

                if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ]; then
                  uv sync --project "$FLAKE_DIR" --python "$PY_BIN" --extra manager
                fi
              fi

              cd "$COMFYUI_HOME"

              if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ] && [ -f manager_requirements.txt ]; then
                ENABLE_MANAGER_ARGS="--enable-manager"
              else
                ENABLE_MANAGER_ARGS=""
              fi

              LISTEN="''${COMFYUI_LISTEN:-127.0.0.1}"
              PORT="''${COMFYUI_PORT:-8188}"

              exec "$VENV_DIR/bin/python" main.py \
                --listen "$LISTEN" --port "$PORT" \
                $ENABLE_MANAGER_ARGS "$@"
            '';
          }}/bin/comfyui-app";
        };

        devShells.default = pkgs.mkShell {
          packages = basePkgs ++ [ comfyui-init comfyui-update comfyui-run ];
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export FLAKE_DIR="$PWD"
            export UV_CACHE_DIR="''${UV_CACHE_DIR:-$FLAKE_DIR/.cache/uv}"
            echo "ComfyUI dev shell"
            echo "  init  : comfyui-init"
            echo "  update: comfyui-update"
            echo "  run   : comfyui"
            echo "Switch Python: COMFYUI_PYTHON=3.12  (default 3.13)"
          '';
        };
      });
}
