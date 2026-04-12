{
  description = "ComfyUI dev env (Podman-isolated; separated user data)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Pinned via flake.lock; the commit hash is read at container build time.
    comfyui-src.url = "github:Comfy-Org/ComfyUI";
    comfyui-src.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, comfyui-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        basePkgs = with pkgs; [
          podman
          git
          aria2
          python3
          ffmpeg
          oxipng
          mozjpeg
        ];

        comfyui-container-build = pkgs.writeShellApplication {
          name = "comfyui-container-build";
          runtimeInputs = [ pkgs.podman pkgs.python3 ];
          text = ''
            set -euo pipefail

            FLAKE_DIR="''${FLAKE_DIR:-$PWD}"

            COMMIT=$(python3 -c "import json; d=json.load(open('$FLAKE_DIR/flake.lock')); print(d['nodes']['comfyui-src']['locked']['rev'])")
            SHORT="''${COMMIT:0:7}"

            echo "Building container for ComfyUI commit: $COMMIT"

            podman build \
              --build-arg "COMFYUI_COMMIT=$COMMIT" \
              -t "comfyui:$SHORT" \
              -t comfyui:latest \
              -f "$FLAKE_DIR/Containerfile" \
              "$FLAKE_DIR"

            echo ""
            echo "Tagged: comfyui:$SHORT and comfyui:latest"
            echo "List:   podman images comfyui"
            echo "Roll back: COMFYUI_TAG=<tag> comfyui-pod"
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
            TAG="''${COMFYUI_TAG:-latest}"
            NETWORK="''${COMFYUI_NETWORK:-default}"

            for d in models custom_nodes input output user; do
              mkdir -p "$STATE_DIR/$d"
            done

            EXTRA_ARGS=("-p" "$LISTEN:$PORT:8188")
            if [ "$NETWORK" = "blocked" ]; then
              EXTRA_ARGS+=("--cap-add=NET_ADMIN" "--env" "COMFYUI_EGRESS=block")
              echo "NOTE: COMFYUI_NETWORK=blocked — outbound connections are blocked."
              echo "      Host API/UI access still works at $LISTEN:$PORT."
            elif [ "$NETWORK" = "none" ]; then
              EXTRA_ARGS=("--network=none")
              echo "NOTE: COMFYUI_NETWORK=none — no network at all."
              echo "      Port mapping disabled; access via 'podman exec' only."
            fi

            echo "Starting ComfyUI container (comfyui:$TAG) on $LISTEN:$PORT..."

            exec podman run --rm -it \
              --name comfyui \
              --device nvidia.com/gpu=all \
              --security-opt=label=disable \
              --shm-size=2g \
              "''${EXTRA_ARGS[@]}" \
              -v "$STATE_DIR/models:/data/models:ro" \
              -v "$STATE_DIR/custom_nodes:/data/custom_nodes:ro" \
              -v "$STATE_DIR/input:/data/input:rw" \
              -v "$STATE_DIR/output:/data/output:rw" \
              -v "$STATE_DIR/user:/data/user:rw" \
              "comfyui:$TAG" \
              "$@"
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
              TAG="''${COMFYUI_TAG:-latest}"
              NETWORK="''${COMFYUI_NETWORK:-default}"

              # Build if the requested tag doesn't exist
              if ! podman image exists "comfyui:$TAG" 2>/dev/null; then
                echo "Image comfyui:$TAG not found; building..."
                COMMIT=$(python3 -c "import json; d=json.load(open('$FLAKE_DIR/flake.lock')); print(d['nodes']['comfyui-src']['locked']['rev'])")
                SHORT="''${COMMIT:0:7}"
                podman build \
                  --build-arg "COMFYUI_COMMIT=$COMMIT" \
                  -t "comfyui:$SHORT" \
                  -t comfyui:latest \
                  -f "$FLAKE_DIR/Containerfile" \
                  "$FLAKE_DIR"
              fi

              for d in models custom_nodes input output user; do
                mkdir -p "$STATE_DIR/$d"
              done

              EXTRA_ARGS=()
              if [ "$NETWORK" = "none" ]; then
                EXTRA_ARGS+=("--network=none")
                echo "NOTE: COMFYUI_NETWORK=none — container has no network."
                echo "      Port mapping is disabled; the ComfyUI UI will NOT be reachable from the host."
              else
                EXTRA_ARGS+=("-p" "$LISTEN:$PORT:8188")
              fi

              echo "Starting ComfyUI container (comfyui:$TAG) on $LISTEN:$PORT..."

              exec podman run --rm -it \
                --name comfyui \
                --device nvidia.com/gpu=all \
                --security-opt=label=disable \
                --shm-size=2g \
                "''${EXTRA_ARGS[@]}" \
                -v "$STATE_DIR/models:/data/models:ro" \
                -v "$STATE_DIR/custom_nodes:/data/custom_nodes:ro" \
                -v "$STATE_DIR/input:/data/input:rw" \
                -v "$STATE_DIR/output:/data/output:rw" \
                -v "$STATE_DIR/user:/data/user:rw" \
                "comfyui:$TAG" \
                "$@"
            '';
          }}/bin/comfyui-app";
        };

        devShells.default = pkgs.mkShell {
          packages = basePkgs ++ [
            comfyui-container-build
            comfyui-container-run
          ];
          shellHook = ''
            export FLAKE_DIR="$PWD"
            echo "ComfyUI dev shell"
            echo ""
            echo "  comfyui-container-build                 — build image (tags :latest and :<commit>)"
            echo "  comfyui-pod                             — start :latest"
            echo "  COMFYUI_TAG=<tag> comfyui-pod           — roll back to an older build"
            echo "  COMFYUI_NETWORK=blocked comfyui-pod     — block outbound, keep UI/API"
            echo "  COMFYUI_NETWORK=none comfyui-pod        — no network at all (podman exec only)"
            echo "  podman images comfyui                   — list available tags"
          '';
        };
      });
}
