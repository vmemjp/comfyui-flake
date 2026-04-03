{
  description = "ComfyUI dev env (Podman-isolated; uv project; separated user data)";

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

        python = pkgs.python313;
        uv = pkgs.uv;

        basePkgs = with pkgs; [
          uv
          python
          podman
          git
          ffmpeg
          nodejs_22
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

        # --- Container (primary, isolated) ---

        comfyui-container-build = pkgs.writeShellApplication {
          name = "comfyui-container-build";
          runtimeInputs = [ pkgs.podman pkgs.python3 ];
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"

            COMMIT=$(python3 -c "import json; d=json.load(open('$FLAKE_DIR/flake.lock')); print(d['nodes']['comfyui-src']['locked']['rev'])")

            echo "Building container for ComfyUI commit: $COMMIT"

            podman build \
              --build-arg "COMFYUI_COMMIT=$COMMIT" \
              -t comfyui:latest \
              -f "$FLAKE_DIR/Containerfile" \
              "$FLAKE_DIR"
          '';
        };

        comfyui-container-run = pkgs.writeShellApplication {
          name = "comfyui-pod";
          runtimeInputs = [ pkgs.podman ];
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            PORT="''${COMFYUI_PORT:-8188}"
            LISTEN="''${COMFYUI_LISTEN:-127.0.0.1}"

            for d in models custom_nodes input output user; do
              mkdir -p "$STATE_DIR/$d"
            done

            echo "Starting ComfyUI container on $LISTEN:$PORT..."

            exec podman run --rm -it \
              --name comfyui \
              --device nvidia.com/gpu=all \
              --security-opt=label=disable \
              -p "$LISTEN:$PORT:8188" \
              -v "$STATE_DIR/models:/data/models:ro" \
              -v "$STATE_DIR/custom_nodes:/data/custom_nodes:ro" \
              -v "$STATE_DIR/input:/data/input:rw" \
              -v "$STATE_DIR/output:/data/output:rw" \
              -v "$STATE_DIR/user:/data/user:rw" \
              comfyui:latest \
              "$@"
          '';
        };

        # --- Native (convenience, not isolated) ---

        setupSourceScript = ''
          migrate_data() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"
            local DATA_DIRS=(custom_nodes input output user models)

            for d in "''${DATA_DIRS[@]}"; do
              if [ -d "$COMFYUI_HOME/$d" ] && [ ! -L "$COMFYUI_HOME/$d" ]; then
                if [ -d "$STATE_DIR/$d" ] && [ -n "$(ls -A "$STATE_DIR/$d" 2>/dev/null)" ]; then
                  cp -a --no-clobber "$COMFYUI_HOME/$d/." "$STATE_DIR/$d/" 2>/dev/null || true
                else
                  mkdir -p "$STATE_DIR"
                  mv "$COMFYUI_HOME/$d" "$STATE_DIR/$d"
                fi
              fi
            done
          }

          setup_links() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"

            local DATA_DIRS=(custom_nodes input output user models)
            for d in "''${DATA_DIRS[@]}"; do
              mkdir -p "$STATE_DIR/$d"
            done

            for d in custom_nodes input output user models; do
              rm -rf "''${COMFYUI_HOME:?}/$d"
              ln -sfn "../$d" "$COMFYUI_HOME/$d"
            done
          }

          setup_source() {
            local STATE_DIR="$1"
            local COMFYUI_HOME="$2"

            mkdir -p "$(dirname "$COMFYUI_HOME")"
            cp -a "${comfyui-src}" "$COMFYUI_HOME"
            chmod -R u+rwX "$COMFYUI_HOME" || true

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

        uvSync = ''
          uv sync --project "$FLAKE_DIR" --python "${python}/bin/python"
          if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ]; then
            uv sync --project "$FLAKE_DIR" --python "${python}/bin/python" --extra manager
          fi
        '';

        comfyui-native-init = pkgs.writeShellApplication {
          name = "comfyui-native-init";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            echo "WARNING: Native mode — PyPI packages run directly on host (not isolated)"

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"

            mkdir -p "$STATE_DIR"

            ${setupSourceScript}

            if [ ! -d "$COMFYUI_HOME" ]; then
              setup_source "$STATE_DIR" "$COMFYUI_HOME"
            elif [ -d "$COMFYUI_HOME/models" ] && [ ! -L "$COMFYUI_HOME/models" ]; then
              echo "Migrating user data from source tree..."
              migrate_data "$STATE_DIR" "$COMFYUI_HOME"
              setup_links "$STATE_DIR" "$COMFYUI_HOME"
              echo "Migration complete."
            fi

            ${uvSync}

            echo "ComfyUI ready (native)."
            echo "  Source: $COMFYUI_HOME"
            echo "  Venv:   $FLAKE_DIR/.venv"
          '';
        };

        comfyui-native-run = pkgs.writeShellApplication {
          name = "comfyui-native";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
            STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"
            VENV_DIR="$FLAKE_DIR/.venv"

            if [ ! -x "$VENV_DIR/bin/python" ]; then
              echo "venv not found. Run: comfyui-native-init"
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
            runtimeInputs = [ pkgs.podman pkgs.python3 ];
            text = ''
              set -euo pipefail

              FLAKE_DIR="''${FLAKE_DIR:-$PWD}"
              STATE_DIR="''${COMFYUI_STATE_DIR:-$FLAKE_DIR/.comfyui-state}"
              PORT="''${COMFYUI_PORT:-8188}"
              LISTEN="''${COMFYUI_LISTEN:-127.0.0.1}"

              # Build if image doesn't exist
              if ! podman image exists comfyui:latest 2>/dev/null; then
                echo "First run: building container image..."
                COMMIT=$(python3 -c "import json; d=json.load(open('$FLAKE_DIR/flake.lock')); print(d['nodes']['comfyui-src']['locked']['rev'])")
                podman build \
                  --build-arg "COMFYUI_COMMIT=$COMMIT" \
                  -t comfyui:latest \
                  -f "$FLAKE_DIR/Containerfile" \
                  "$FLAKE_DIR"
              fi

              for d in models custom_nodes input output user; do
                mkdir -p "$STATE_DIR/$d"
              done

              echo "Starting ComfyUI container on $LISTEN:$PORT..."

              exec podman run --rm -it \
                --name comfyui \
                --device nvidia.com/gpu=all \
                --security-opt=label=disable \
                -p "$LISTEN:$PORT:8188" \
                -v "$STATE_DIR/models:/data/models:ro" \
                -v "$STATE_DIR/custom_nodes:/data/custom_nodes:ro" \
                -v "$STATE_DIR/input:/data/input:rw" \
                -v "$STATE_DIR/output:/data/output:rw" \
                -v "$STATE_DIR/user:/data/user:rw" \
                comfyui:latest \
                "$@"
            '';
          }}/bin/comfyui-app";
        };

        devShells.default = pkgs.mkShell {
          packages = basePkgs ++ [
            comfyui-container-build comfyui-container-run
            comfyui-native-init comfyui-native-run
          ];
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export FLAKE_DIR="$PWD"
            export UV_CACHE_DIR="''${UV_CACHE_DIR:-$FLAKE_DIR/.cache/uv}"
            echo "ComfyUI dev shell"
            echo ""
            echo "  Container (isolated):"
            echo "    comfyui-container-build — build image"
            echo "    comfyui-pod             — start"
            echo ""
            echo "  Native (not isolated):"
            echo "    comfyui-native-init     — setup"
            echo "    comfyui-native          — start"
          '';
        };
      });
}
