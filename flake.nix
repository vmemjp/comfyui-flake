{
  description = "ComfyUI dev env (direnv-friendly; uv; project-local state; py3.13 default w/ 3.12 switch)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    comfyui-src.url = "github:comfyanonymous/ComfyUI";
    comfyui-src.flake = false;
  };

  outputs = { self, nixpkgs, flake-utils, comfyui-src }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        python312 = pkgs.python312;
        python313 = pkgs.python313;
        uv = pkgs.uv;

        # 起動や依存ビルドに必要になりがちなツール
        basePkgs = with pkgs; [
          uv
          python312
          python313
          git
          ffmpeg

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

        comfyui-init = pkgs.writeShellApplication {
          name = "comfyui-init";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            # 既定: プロジェクト配下に状態を閉じる
            STATE_DIR="''${COMFYUI_STATE_DIR:-$PWD/.comfyui-state}"

            COMFYUI_PYTHON="''${COMFYUI_PYTHON:-3.13}"
            case "$COMFYUI_PYTHON" in
              3.13) PY_BIN="${python313}/bin/python" ;;
              3.12) PY_BIN="${python312}/bin/python" ;;
              *)
                echo "Unsupported COMFYUI_PYTHON=$COMFYUI_PYTHON (use 3.13 or 3.12)"
                exit 2
                ;;
            esac

            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"
            VENV_DIR="''${COMFYUI_VENV:-$STATE_DIR/venv-py$COMFYUI_PYTHON}"

            mkdir -p "$STATE_DIR"

            # ComfyUI 本体を state dir に展開（store は書けない）
            if [ ! -d "$COMFYUI_HOME" ]; then
              mkdir -p "$(dirname "$COMFYUI_HOME")"
              cp -a "${comfyui-src}" "$COMFYUI_HOME"
              chmod -R u+rwX "$COMFYUI_HOME" || true
            fi

            cd "$COMFYUI_HOME"

            # venv
            if [ ! -d "$VENV_DIR" ]; then
              mkdir -p "$(dirname "$VENV_DIR")"
              uv venv "$VENV_DIR" --python "$PY_BIN"
            fi

            # 依存投入
            uv pip install --python "$VENV_DIR/bin/python" --requirements requirements.txt

            # 任意: Manager
            if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ] && [ -f manager_requirements.txt ]; then
              uv pip install --python "$VENV_DIR/bin/python" --requirements manager_requirements.txt
            fi

            echo "ComfyUI ready."
            echo "  Source: $COMFYUI_HOME"
            echo "  Venv:   $VENV_DIR"
          '';
        };

        comfyui-run = pkgs.writeShellApplication {
          name = "comfyui";
          runtimeInputs = basePkgs;
          text = ''
            set -euo pipefail

            STATE_DIR="''${COMFYUI_STATE_DIR:-$PWD/.comfyui-state}"
            COMFYUI_PYTHON="''${COMFYUI_PYTHON:-3.13}"

            COMFYUI_HOME="''${COMFYUI_HOME:-$STATE_DIR/src}"
            VENV_DIR="''${COMFYUI_VENV:-$STATE_DIR/venv-py$COMFYUI_PYTHON}"

            if [ ! -x "$VENV_DIR/bin/python" ]; then
              echo "venv not found. Run: comfyui-init"
              exit 1
            fi

            cd "$COMFYUI_HOME"

            # Manager を使うなら引数で有効化（comfyui-init が requirements を入れる想定）
            if [ "''${COMFYUI_ENABLE_MANAGER:-1}" = "1" ] && [ -f manager_requirements.txt ]; then
              ENABLE_MANAGER_ARGS="--enable-manager"
            else
              ENABLE_MANAGER_ARGS=""
            fi

            exec "$VENV_DIR/bin/python" main.py $ENABLE_MANAGER_ARGS "$@"
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = basePkgs ++ [ comfyui-init comfyui-run ];
          shellHook = ''
            export LD_LIBRARY_PATH="${pkgs.stdenv.cc.cc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            echo "ComfyUI dev shell"
            echo "  init: comfyui-init"
            echo "  run : comfyui --listen 127.0.0.1 --port 8188"
            echo "Switch Python: COMFYUI_PYTHON=3.12 (default 3.13)"
          '';
        };
      });
}
