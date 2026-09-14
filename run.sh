#!/usr/bin/env bash
# ============================================================
# Realtor AI Assistant — UNIFIED LAUNCHER (run every day)
#
#   1. Creates/activates a Python virtualenv (first time only).
#   2. Installs backend dependencies (idempotent).
#   3. Loads server/.env.
#   4. If the LLM server is unreachable and a local GGUF model is
#      configured, starts `llama-server` automatically.
#   5. Starts the web app with uvicorn.
# ============================================================
set -euo pipefail

cd "$(dirname "$0")"

# ---- Python interpreter ----
if command -v python3 >/dev/null 2>&1; then
  PY=python3
else
  PY=python
fi

# ---- virtualenv ----
VENV_DIR="${VENV_DIR:-.venv}"
if [ ! -d "$VENV_DIR" ]; then
  echo "==> Создаю виртуальное окружение ($VENV_DIR)…"
  "$PY" -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# ---- dependencies (idempotent) ----
echo "==> Проверяю/устанавливаю зависимости…"
pip install --quiet --upgrade pip
pip install --quiet -r server/requirements.txt

# ---- load server/.env ----
if [ -f server/.env ]; then
  echo "==> Загружаю server/.env"
  set -a
  # shellcheck disable=SC1091
  source server/.env
  set +a
fi

BASE_URL="${LLM_BASE_URL:-http://127.0.0.1:8080/v1}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
STATE_DIR="${STATE_DIR:-$HOME/realtor-ai-app/state}"
mkdir -p "$STATE_DIR"

# ---- derive LLM port for auto-starting llama-server ----
LLM_PORT=$(printf '%s' "$BASE_URL" | sed -nE 's#^https?://[^:/]+:([0-9]+).*#\1#p')
[ -z "$LLM_PORT" ] && LLM_PORT=8080

# ---- path to the llama-server binary (set by setup.sh in server/.env) ----
LLAMA_SERVER="${LLAMA_SERVER_PATH:-llama-server}"

# ---- ensure the LLM server is reachable ----
llm_reachable() {
  curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null 2>&1
}

if ! llm_reachable; then
  if [ -n "${LOCAL_GGUF_PATH:-}" ] && [ -f "$LOCAL_GGUF_PATH" ] \
     && command -v "$LLAMA_SERVER" >/dev/null 2>&1; then
    echo "==> LLM-сервер недоступен. Автозапуск llama-server:"
    echo "    бинарник: $LLAMA_SERVER"
    echo "    модель: $LOCAL_GGUF_PATH"
    nohup "$LLAMA_SERVER" \
      --model "$LOCAL_GGUF_PATH" \
      --alias "${REALTOR_MODEL:-qwen2.5-7b-instruct}" \
      --host 127.0.0.1 \
      --port "$LLM_PORT" \
      --ctx-size "${LLM_CTX_SIZE:-8192}" \
      --threads "$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)" \
      > "$STATE_DIR/llama-server.log" 2>&1 &

    echo "==> Ожидаю запуска LLM-сервера…"
    for _ in $(seq 1 40); do
      if llm_reachable; then break; fi
      sleep 2
    done
  fi
fi

if llm_reachable; then
  echo "==> LLM-сервер доступен: $BASE_URL"
else
  echo ""
  echo "ВНИМАНИЕ: LLM-сервер недоступен по адресу $BASE_URL"
  echo "Приложение запустится, но агенты не смогут отвечать."
  echo "Способы запустить LLM-сервер описаны в README.md."
  echo ""
fi

echo ""
echo "================================================="
echo "  Realtor AI Assistant"
echo "  Веб-интерфейс : http://$HOST:$PORT"
echo "  LLM endpoint   : $BASE_URL"
echo "  Хранилище      : $STATE_DIR"
echo "================================================="
echo ""

exec uvicorn app:app --app-dir server --host "$HOST" --port "$PORT"
