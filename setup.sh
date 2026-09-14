#!/usr/bin/env bash
# ============================================================
# Realtor AI Assistant — FIRST-TIME SETUP (macOS, Intel or Apple Silicon)
#
# Does everything needed once:
#   1. Ensures python3 is present (installs Command Line Tools if not).
#   2. Downloads a prebuilt llama.cpp binary (`llama-server`) from GitHub.
#      (No Homebrew needed — Homebrew no longer supports Intel Macs.)
#   3. Downloads a free Qwen model (Qwen2.5-7B-Instruct, Q4_K_M, ~4.7 GB).
#   4. Creates server/.env with sane defaults.
#
# After this, start the app any time with:  ./run.sh
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"

echo "================================================="
echo "  Realtor AI Assistant — первичная настройка"
echo "================================================="

# ----------------------------------------------------------
# 1. Python 3
# ----------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  echo ""
  echo "==> python3 не найден. Устанавливаю Command Line Tools…"
  echo "    (появится системный диалог — нажмите «Установить»)"
  xcode-select --install || true
  echo ""
  echo "После завершения установки Command Line Tools"
  echo "запустите этот скрипт ещё раз:  ./setup.sh"
  exit 1
fi
echo "==> python3: $(python3 --version)"

# ----------------------------------------------------------
# 2. llama.cpp — prebuilt `llama-server` binary (no Homebrew)
#    Homebrew dropped Intel-Mac support, but llama.cpp publishes
#    ready-made macOS binaries on GitHub Releases (x64 and arm64).
#    The prebuilt binary requires macOS 13.3 (Ventura) or newer.
# ----------------------------------------------------------
LLAMA_DIR="${LLAMA_DIR:-$HOME/realtor-ai-app/bin}"
mkdir -p "$LLAMA_DIR"

if [ -x "$LLAMA_DIR/llama-server" ]; then
  echo "==> llama-server уже установлен: $LLAMA_DIR/llama-server"
else
  echo ""
  echo "==> Скачиваю готовый бинарник llama.cpp (llama-server)…"

  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) ASSET_ARCH="x64" ;;
    arm64)  ASSET_ARCH="arm64" ;;
    *) echo "ОШИБКА: неизвестная архитектура: $ARCH" >&2; exit 1 ;;
  esac

  # The "latest" GitHub release carries no binaries; nightly bXXXXX tags do.
  # Pick the newest release that ships a macOS binary for this machine.
  TAG="$(curl -fsSL "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=30" \
    | python3 -c 'import sys,json
arch=sys.argv[1]
for r in json.load(sys.stdin):
    for a in r.get("assets", []):
        if ("bin-macos-"+arch) in a.get("name", ""):
            print(r["tag_name"]); raise SystemExit
sys.exit("не найден бинарник llama.cpp для macos-"+arch)' "$ASSET_ARCH")"

  ASSET="llama-${TAG}-bin-macos-${ASSET_ARCH}.tar.gz"
  URL="https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/${ASSET}"
  echo "    $URL"

  curl -L --fail --retry 3 -o "$LLAMA_DIR/llama.tar.gz" "$URL"
  tar -xzf "$LLAMA_DIR/llama.tar.gz" -C "$LLAMA_DIR"

  # Move the extracted folder's contents up into $LLAMA_DIR (flat), keeping
  # `llama-server` next to its .dylib libraries (RPATH = @loader_path).
  INNER="$(tar -tzf "$LLAMA_DIR/llama.tar.gz" | head -n 1 | cut -d/ -f1)"
  mv "$LLAMA_DIR/$INNER"/* "$LLAMA_DIR/"
  rmdir "$LLAMA_DIR/$INNER" 2>/dev/null || true
  rm -f "$LLAMA_DIR/llama.tar.gz"
fi

if ! "$LLAMA_DIR/llama-server" --version >/dev/null 2>&1; then
  echo ""
  echo "ОШИБКА: llama-server не запускается."
  echo "  Вероятно, macOS старее 13.3 (Ventura) — готовый бинарник требует"
  echo "  Ventura или новее. Обновите macOS либо соберите llama.cpp из исходников:"
  echo "  https://github.com/ggml-org/llama.cpp"
  exit 1
fi
echo "==> llama-server: $LLAMA_DIR/llama-server ($("$LLAMA_DIR/llama-server" --version | head -n 1))"

# ----------------------------------------------------------
# 3. Free Qwen model (single-file GGUF, Q4_K_M)
# ----------------------------------------------------------
MODELS_DIR="${MODELS_DIR:-$HOME/realtor-ai-app/models}"
mkdir -p "$MODELS_DIR"

MODEL_FILE="Qwen2.5-7B-Instruct-Q4_K_M.gguf"
MODEL_URL="https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF/resolve/main/${MODEL_FILE}"
MODEL_PATH="$MODELS_DIR/$MODEL_FILE"

if [ -f "$MODEL_PATH" ]; then
  echo "==> Модель уже скачана: $MODEL_PATH"
else
  echo ""
  echo "==> Скачиваю Qwen2.5-7B-Instruct (Q4_K_M, ~4.7 ГБ)…"
  echo "    Это займёт время в зависимости от скорости сети."
  curl -L --fail --retry 3 --continue-at - -o "$MODEL_PATH" "$MODEL_URL"
  echo "==> Модель сохранена: $MODEL_PATH"
fi

# ----------------------------------------------------------
# 4. server/.env
# ----------------------------------------------------------
ENV_FILE="server/.env"
if [ -f "$ENV_FILE" ]; then
  echo "==> $ENV_FILE уже существует — не перезаписываю."
else
  cat > "$ENV_FILE" <<EOF
# Сгенерировано setup.sh
LLM_BASE_URL=http://127.0.0.1:8080/v1
LLM_API_KEY=
LLM_TIMEOUT=600
REALTOR_MODEL=qwen2.5-7b-instruct
ANALYST_MODEL=qwen2.5-7b-instruct
STATE_DIR=$HOME/realtor-ai-app/state
LOCAL_GGUF_PATH=$MODEL_PATH
LLAMA_SERVER_PATH=$LLAMA_DIR/llama-server
HOST=127.0.0.1
PORT=8000
EOF
  echo "==> Создан $ENV_FILE"
fi

echo ""
echo "================================================="
echo " Готово!"
echo ""
echo " Запуск приложения (всегда):"
echo "   ./run.sh"
echo ""
echo " Затем откройте в браузере: http://127.0.0.1:8000"
echo "================================================="
