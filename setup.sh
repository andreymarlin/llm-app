#!/usr/bin/env bash
# ============================================================
# Realtor AI Assistant — FIRST-TIME SETUP (macOS, Intel or Apple Silicon)
#
# Does everything needed once:
#   1. Ensures python3 is present (installs Command Line Tools if not).
#   2. Installs Homebrew (if missing).
#   3. Installs llama.cpp  ->  provides `llama-server`.
#   4. Downloads a free Qwen model (Qwen2.5-7B-Instruct, Q4_K_M, ~4.7 GB).
#   5. Creates server/.env with sane defaults.
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
# 2. Homebrew
# ----------------------------------------------------------
if ! command -v brew >/dev/null 2>&1; then
  echo ""
  echo "==> Устанавливаю Homebrew…"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
echo "==> brew: $(brew --version | head -n 1)"

# ----------------------------------------------------------
# 3. llama.cpp (llama-server) — works on Intel Macs (CPU)
# ----------------------------------------------------------
if ! command -v llama-server >/dev/null 2>&1; then
  echo "==> Устанавливаю llama.cpp…"
  brew install llama.cpp
fi
echo "==> llama-server: $(command -v llama-server)"

# ----------------------------------------------------------
# 4. Free Qwen model (single-file GGUF, Q4_K_M)
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
# 5. server/.env
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
