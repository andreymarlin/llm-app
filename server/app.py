"""Realtor AI Assistant — FastAPI backend with two editable agents.

Two agents:
  1. "Риелтор" (realtor)      — conducts conversations with a client about
                                buying a flat.
  2. "Аналитик поведения"      — reads realtor chat transcripts and recommends
                                how to bring the client to a deal.

LLM access goes through any OpenAI-compatible HTTP server (LM Studio, llama.cpp
`llama-server`, Ollama, vLLM, ...). No paid API keys are required — everything
runs locally. All state (agents, chats, messages, prompts) is stored in a
single SQLite database so the app is fully reproducible.
"""

from __future__ import annotations

import os
import sqlite3
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator, Optional

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

# --------------------------------------------------------------------------
# Configuration (env vars, optionally loaded from server/.env)
# --------------------------------------------------------------------------


def load_env(path: Optional[Path] = None) -> None:
    """Minimal .env loader so we don't depend on python-dotenv."""
    path = path or Path(__file__).with_name(".env")
    if not path.exists():
        return
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


load_env()

STATE_DIR = Path(
    os.environ.get("STATE_DIR", str(Path.home() / "realtor-ai-app" / "state"))
)
STATE_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = STATE_DIR / "app.db"

LLM_BASE_URL = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8080/v1").rstrip("/")
LLM_API_KEY = os.environ.get("LLM_API_KEY", "")
LLM_TIMEOUT = float(os.environ.get("LLM_TIMEOUT", "600"))

DEFAULT_REALTOR_MODEL = os.environ.get("REALTOR_MODEL", "qwen2.5-7b-instruct")
DEFAULT_ANALYST_MODEL = os.environ.get("ANALYST_MODEL", "qwen2.5-7b-instruct")

DEFAULT_REALTOR_PROMPT = """Ты — профессиональный риелтор в крупном агентстве недвижимости.
Твоя цель — помочь клиенту выбрать и купить квартиру и довести его до сделки, сохраняя доверие и доброжелательность.

Правила ведения диалога:
- Отвечай на русском языке, тепло, вежливо и по-деловому.
- Сначала выясняй потребности клиента: бюджет, район, число комнат, цель покупки, сроки, состав семьи, способ оплаты (наличные/ипотека).
- Задавай уточняющие вопросы по одному, не вываливай сразу длинный список.
- Подбирай подходящие варианты и аргументируй их, исходя из запроса клиента.
- Работай с возражениями (цена, район, сроки, ипотека, сомнения) конструктивно, без давления и манипуляций.
- Веди клиента по этапам: знакомство → выявление потребностей → подбор вариантов → организация просмотра → обсуждение условий → оформление сделки.
- Никогда не выдумывай юридические факты, точные цены и наличие конкретных объектов; если чего-то не знаешь — честно скажи, что уточнишь.
- В конце каждого ответа мягко веди к следующему шагу: записи на просмотр, консультации по ипотеке, уточнению бюджета, звонку менеджера."""

DEFAULT_ANALYST_PROMPT = """Ты — поведенческий аналитик в агентстве недвижимости.
Ты НЕ общаешься с клиентом напрямую. Ты анализируешь стенограммы чатов риелтора с клиентами.

Твоя задача: по переданной стенограмме чата дать риелтору конкретные рекомендации, как довести ЭТОГО клиента до сделки по покупке квартиры.

Формат ответа:
1. Оценка клиента: стадия принятия решения, уровень мотивации, основные барьеры и сомнения.
2. Сильные и слабые стороны ведения диалога риелтором (с примерами из чата).
3. Поведенческие сигналы клиента: что он даёт понять словами, возражения, скрытые потребности.
4. Конкретные следующие шаги и готовые формулировки для риелтора (что именно написать или спросить клиенту).
5. Риски и как их снизить.

Будь конкретен и опирайся ТОЛЬКО на переданную стенограмму, не домысливай факты.
Если стенограмма короткая или отсутствует — прямо скажи об этом и предложи, как её получить."""

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def new_id() -> str:
    return uuid.uuid4().hex


def get_conn() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


@contextmanager
def db() -> Iterator[sqlite3.Connection]:
    conn = get_conn()
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db() -> None:
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS agents (
                id            TEXT PRIMARY KEY,
                name          TEXT NOT NULL,
                role          TEXT NOT NULL,
                model         TEXT NOT NULL,
                system_prompt TEXT NOT NULL,
                temperature   REAL NOT NULL DEFAULT 0.7,
                created_at    TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS chats (
                id              TEXT PRIMARY KEY,
                agent_id        TEXT NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
                title           TEXT NOT NULL,
                context_chat_id TEXT,
                created_at      TEXT NOT NULL,
                updated_at      TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS messages (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_id    TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
                role       TEXT NOT NULL,
                content    TEXT NOT NULL,
                model      TEXT,
                created_at TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_messages_chat ON messages(chat_id, id);
            CREATE INDEX IF NOT EXISTS idx_chats_agent ON chats(agent_id);
            """
        )

        # Migration: add context_chat_id to chats created by older versions.
        chat_cols = [r["name"] for r in conn.execute("PRAGMA table_info(chats)").fetchall()]
        if "context_chat_id" not in chat_cols:
            conn.execute("ALTER TABLE chats ADD COLUMN context_chat_id TEXT")

        # Seed the two agents only if the table is empty (idempotent).
        count = conn.execute("SELECT COUNT(*) AS c FROM agents").fetchone()["c"]
        if count == 0:
            now = now_iso()
            conn.execute(
                "INSERT INTO agents (id, name, role, model, system_prompt, temperature, created_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    "realtor",
                    "Риелтор",
                    "Ведёт диалог с клиентом и доводит его до сделки",
                    DEFAULT_REALTOR_MODEL,
                    DEFAULT_REALTOR_PROMPT,
                    0.7,
                    now,
                ),
            )
            conn.execute(
                "INSERT INTO agents (id, name, role, model, system_prompt, temperature, created_at)"
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    "analyst",
                    "Аналитик поведения",
                    "Анализирует чаты риелтора и даёт рекомендации по сделке",
                    DEFAULT_ANALYST_MODEL,
                    DEFAULT_ANALYST_PROMPT,
                    0.5,
                    now,
                ),
            )


def row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
    return dict(row)


# --------------------------------------------------------------------------
# App + request models
# --------------------------------------------------------------------------

app = FastAPI(title="Realtor AI Assistant")


class AgentUpdate(BaseModel):
    name: Optional[str] = None
    system_prompt: Optional[str] = None
    model: Optional[str] = None
    temperature: Optional[float] = None


class ChatCreate(BaseModel):
    agent_id: str


class ChatRename(BaseModel):
    title: str


class MessageCreate(BaseModel):
    content: str
    context_chat_id: Optional[str] = None


# --------------------------------------------------------------------------
# LLM client (OpenAI-compatible /chat/completions)
# --------------------------------------------------------------------------


def _auth_headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if LLM_API_KEY:
        headers["Authorization"] = f"Bearer {LLM_API_KEY}"
    return headers


def chat_completion(
    model: str, system_prompt: str, temperature: float, messages: list[dict[str, str]]
) -> str:
    payload = {
        "model": model,
        "messages": [{"role": "system", "content": system_prompt}] + messages,
        "temperature": temperature,
        "stream": False,
    }
    url = f"{LLM_BASE_URL}/chat/completions"
    try:
        with httpx.Client(timeout=LLM_TIMEOUT) as client:
            resp = client.post(url, json=payload, headers=_auth_headers())
    except httpx.HTTPError as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Не удалось подключиться к LLM-серверу ({LLM_BASE_URL}): {exc}",
        ) from exc

    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail=f"LLM-сервер вернул ошибку {resp.status_code}: {resp.text[:600]}",
        )

    try:
        content = resp.json()["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=502, detail="Неожиданный формат ответа LLM-сервера"
        ) from exc

    return (content or "").strip()


def list_llm_models() -> tuple[list[str], Optional[str]]:
    """Return (models, error)."""
    try:
        with httpx.Client(timeout=10) as client:
            resp = client.get(f"{LLM_BASE_URL}/models", headers=_auth_headers())
        if resp.status_code >= 400:
            return [], f"status {resp.status_code}"
        data = resp.json()
        models = [m.get("id") for m in data.get("data", []) if m.get("id")]
        return models, None
    except httpx.HTTPError as exc:
        return [], str(exc)


# --------------------------------------------------------------------------
# API routes
# --------------------------------------------------------------------------


@app.get("/api/health")
def health() -> dict[str, Any]:
    models, err = list_llm_models()
    reachable = err is None
    return {
        "status": "ok",
        "llm": {
            "reachable": reachable,
            "detail": None if reachable else err,
            "base_url": LLM_BASE_URL,
        },
        "state_dir": str(STATE_DIR),
    }


@app.get("/api/models")
def models() -> dict[str, Any]:
    models, err = list_llm_models()
    return {"models": models, "error": err}


@app.get("/api/agents")
def get_agents() -> list[dict[str, Any]]:
    with db() as conn:
        rows = conn.execute("SELECT * FROM agents ORDER BY created_at").fetchall()
    return [row_to_dict(r) for r in rows]


@app.put("/api/agents/{agent_id}")
def update_agent(agent_id: str, body: AgentUpdate) -> dict[str, Any]:
    with db() as conn:
        existing = conn.execute(
            "SELECT * FROM agents WHERE id = ?", (agent_id,)
        ).fetchone()
        if existing is None:
            raise HTTPException(status_code=404, detail="Агент не найден")

        fields: dict[str, Any] = {}
        if body.name is not None:
            fields["name"] = body.name.strip() or existing["name"]
        if body.system_prompt is not None:
            fields["system_prompt"] = body.system_prompt
        if body.model is not None:
            fields["model"] = body.model.strip() or existing["model"]
        if body.temperature is not None:
            fields["temperature"] = max(0.0, min(2.0, body.temperature))

        if not fields:
            raise HTTPException(status_code=400, detail="Нечего обновлять")

        set_clause = ", ".join(f"{k} = ?" for k in fields)
        params = list(fields.values()) + [agent_id]
        conn.execute(f"UPDATE agents SET {set_clause} WHERE id = ?", params)
        row = conn.execute("SELECT * FROM agents WHERE id = ?", (agent_id,)).fetchone()
    return row_to_dict(row)


@app.get("/api/chats")
def get_chats() -> list[dict[str, Any]]:
    with db() as conn:
        rows = conn.execute("SELECT * FROM chats ORDER BY updated_at DESC").fetchall()
    return [row_to_dict(r) for r in rows]


@app.post("/api/chats", status_code=201)
def create_chat(body: ChatCreate) -> dict[str, Any]:
    with db() as conn:
        agent = conn.execute("SELECT * FROM agents WHERE id = ?", (body.agent_id,)).fetchone()
        if agent is None:
            raise HTTPException(status_code=404, detail="Агент не найден")
        chat_id = new_id()
        now = now_iso()
        conn.execute(
            "INSERT INTO chats (id, agent_id, title, created_at, updated_at)"
            " VALUES (?, ?, ?, ?, ?)",
            (chat_id, body.agent_id, "Новая сессия", now, now),
        )
    return {"id": chat_id, "agent_id": body.agent_id, "title": "Новая сессия"}


@app.get("/api/chats/{chat_id}")
def get_chat(chat_id: str) -> dict[str, Any]:
    with db() as conn:
        chat = conn.execute("SELECT * FROM chats WHERE id = ?", (chat_id,)).fetchone()
        if chat is None:
            raise HTTPException(status_code=404, detail="Чат не найден")
        agent = conn.execute("SELECT * FROM agents WHERE id = ?", (chat["agent_id"],)).fetchone()
        msgs = conn.execute(
            "SELECT id, role, content, model, created_at FROM messages WHERE chat_id = ? ORDER BY id",
            (chat_id,),
        ).fetchall()
    return {
        **row_to_dict(chat),
        "agent": row_to_dict(agent) if agent else None,
        "messages": [row_to_dict(m) for m in msgs],
    }


@app.patch("/api/chats/{chat_id}")
def rename_chat(chat_id: str, body: ChatRename) -> dict[str, Any]:
    title = body.title.strip()
    if not title:
        raise HTTPException(status_code=400, detail="Название не может быть пустым")
    with db() as conn:
        cur = conn.execute(
            "UPDATE chats SET title = ?, updated_at = ? WHERE id = ?",
            (title, now_iso(), chat_id),
        )
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Чат не найден")
        row = conn.execute("SELECT * FROM chats WHERE id = ?", (chat_id,)).fetchone()
    return row_to_dict(row)


@app.delete("/api/chats/{chat_id}")
def delete_chat(chat_id: str) -> dict[str, str]:
    with db() as conn:
        cur = conn.execute("DELETE FROM chats WHERE id = ?", (chat_id,))
        if cur.rowcount == 0:
            raise HTTPException(status_code=404, detail="Чат не найден")
    return {"status": "deleted"}


@app.post("/api/chats/{chat_id}/messages")
def send_message(chat_id: str, body: MessageCreate) -> dict[str, Any]:
    content = body.content.strip()
    if not content:
        raise HTTPException(status_code=400, detail="Сообщение пустое")

    with db() as conn:
        chat = conn.execute("SELECT * FROM chats WHERE id = ?", (chat_id,)).fetchone()
        if chat is None:
            raise HTTPException(status_code=404, detail="Чат не найден")
        agent = conn.execute("SELECT * FROM agents WHERE id = ?", (chat["agent_id"],)).fetchone()

        history = conn.execute(
            "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY id", (chat_id,)
        ).fetchall()
        is_first = len(history) == 0

        # Optional: inject another chat's transcript (the analyst use-case).
        # When the request carries an explicit context chat id, persist it on this
        # chat so follow-up questions keep analysing the same transcript. An empty
        # string clears the binding.
        context_chat_id: Optional[str] = None
        if body.context_chat_id is not None:
            requested = body.context_chat_id.strip()
            if requested and requested != chat_id:
                exists = conn.execute(
                    "SELECT 1 FROM chats WHERE id = ?", (requested,)
                ).fetchone()
                if exists is not None:
                    context_chat_id = requested
            conn.execute(
                "UPDATE chats SET context_chat_id = ? WHERE id = ?",
                (context_chat_id, chat_id),
            )
        else:
            context_chat_id = chat["context_chat_id"]

        context: Optional[dict[str, Any]] = None
        if context_chat_id and context_chat_id != chat_id:
            ctx_chat = conn.execute(
                "SELECT * FROM chats WHERE id = ?", (context_chat_id,)
            ).fetchone()
            if ctx_chat is not None:
                ctx_msgs = conn.execute(
                    "SELECT role, content FROM messages WHERE chat_id = ? ORDER BY id",
                    (context_chat_id,),
                ).fetchall()
                context = {
                    "title": ctx_chat["title"],
                    "agent_id": ctx_chat["agent_id"],
                    "messages": [dict(m) for m in ctx_msgs],
                }

    # Build the LLM conversation from stored history.
    llm_messages: list[dict[str, str]] = []
    for m in history:
        llm_messages.append(
            {
                "role": "assistant" if m["role"] == "assistant" else "user",
                "content": m["content"],
            }
        )

    if context is not None:
        transcript_lines = []
        for m in context["messages"]:
            who = "Клиент" if m["role"] == "user" else "Риелтор"
            transcript_lines.append(f"{who}: {m['content']}")
        transcript = "\n".join(transcript_lines) or "(стенограмма пустая)"
        llm_messages.append(
            {
                "role": "user",
                "content": (
                    f"[Контекст для анализа — стенограмма чата «{context['title']}»]\n"
                    f"{transcript}\n"
                    f"[Конец стенограммы]\n\n"
                    f"{content}"
                ),
            }
        )
    else:
        llm_messages.append({"role": "user", "content": content})

    reply = chat_completion(agent["model"], agent["system_prompt"], agent["temperature"], llm_messages)

    now = now_iso()
    with db() as conn:
        conn.execute(
            "INSERT INTO messages (chat_id, role, content, model, created_at) VALUES (?, ?, ?, ?, ?)",
            (chat_id, "user", content, None, now),
        )
        conn.execute(
            "INSERT INTO messages (chat_id, role, content, model, created_at) VALUES (?, ?, ?, ?, ?)",
            (chat_id, "assistant", reply, agent["model"], now),
        )
        if is_first:
            title = content[:60] + ("…" if len(content) > 60 else "")
            conn.execute(
                "UPDATE chats SET title = ?, updated_at = ? WHERE id = ?",
                (title, now, chat_id),
            )
        else:
            conn.execute("UPDATE chats SET updated_at = ? WHERE id = ?", (now, chat_id))

    return {"reply": reply, "model": agent["model"]}


@app.get("/api/export")
def export_data() -> dict[str, Any]:
    """Full state dump (NDJSON-friendly) for backup / reproducibility."""
    with db() as conn:
        agents = [row_to_dict(r) for r in conn.execute("SELECT * FROM agents").fetchall()]
        chats = [row_to_dict(r) for r in conn.execute("SELECT * FROM chats").fetchall()]
        messages = [
            row_to_dict(r) for r in conn.execute("SELECT * FROM messages ORDER BY id").fetchall()
        ]
    return {
        "exported_at": now_iso(),
        "state_dir": str(STATE_DIR),
        "agents": agents,
        "chats": chats,
        "messages": messages,
    }


# --------------------------------------------------------------------------
# Startup + static files
# --------------------------------------------------------------------------


@app.on_event("startup")
def on_startup() -> None:
    init_db()


STATIC_DIR = Path(__file__).resolve().parent.parent / "static"
if STATIC_DIR.exists():
    app.mount("/", StaticFiles(directory=STATIC_DIR, html=True), name="static")
