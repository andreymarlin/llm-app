/* Realtor AI Assistant — front-end logic (vanilla JS, no build step). */

const state = {
  agents: [],
  chats: [],
  activeChatId: null,
  activeAgentId: null,
  contextChatId: "",
  editingAgentId: null,
};

const $ = (sel) => document.querySelector(sel);

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { "Content-Type": "application/json" },
    ...opts,
  });
  if (!res.ok) {
    let detail = res.statusText;
    try {
      const data = await res.json();
      detail = data.detail || detail;
    } catch {
      /* ignore */
    }
    throw new Error(detail);
  }
  return res.json();
}

/* ----------------------------- Loading ----------------------------- */

async function refreshAgents() {
  state.agents = await api("/api/agents");
  renderAgents();
}

async function refreshChats() {
  state.chats = await api("/api/chats");
  renderChats();
}

async function refreshAll() {
  await Promise.all([refreshAgents(), refreshChats(), updateHealth(), refreshModels()]);
}

/* ----------------------------- Rendering ----------------------------- */

function renderAgents() {
  const box = $("#agent-cards");
  box.innerHTML = "";
  for (const agent of state.agents) {
    const card = document.createElement("div");
    card.className = "agent-card";

    const head = document.createElement("div");
    head.className = "agent-head";
    const name = document.createElement("span");
    name.className = "agent-name";
    name.textContent = agent.name;
    const role = document.createElement("span");
    role.className = "agent-role";
    role.textContent = agent.role;
    head.append(name, role);
    card.appendChild(head);

    const model = document.createElement("div");
    model.className = "agent-model";
    model.textContent = agent.model;
    card.appendChild(model);

    const btns = document.createElement("div");
    btns.className = "agent-btns";
    const newBtn = document.createElement("button");
    newBtn.className = "btn small primary";
    newBtn.textContent = "Новая сессия";
    newBtn.addEventListener("click", () => newChat(agent.id));
    const setBtn = document.createElement("button");
    setBtn.className = "btn small";
    setBtn.textContent = "Настройки";
    setBtn.addEventListener("click", () => openSettings(agent.id));
    btns.append(newBtn, setBtn);
    card.appendChild(btns);

    box.appendChild(card);
  }
}

function renderChats() {
  const list = $("#chat-list");
  list.innerHTML = "";
  for (const agent of state.agents) {
    const group = document.createElement("div");
    group.className = "chat-group-label";
    group.textContent = agent.name;
    list.appendChild(group);

    const chats = state.chats.filter((c) => c.agent_id === agent.id);
    if (chats.length === 0) {
      const empty = document.createElement("div");
      empty.className = "chat-item empty";
      empty.textContent = "Нет сессий";
      list.appendChild(empty);
      continue;
    }
    for (const chat of chats) {
      const item = document.createElement("div");
      item.className = "chat-item" + (chat.id === state.activeChatId ? " active" : "");
      item.dataset.chatId = chat.id;

      const title = document.createElement("span");
      title.className = "chat-title";
      title.textContent = chat.title;
      title.title = chat.title;

      const del = document.createElement("button");
      del.className = "icon-btn";
      del.textContent = "✕";
      del.title = "Удалить сессию";
      del.addEventListener("click", (e) => {
        e.stopPropagation();
        deleteChat(chat.id);
      });

      item.append(title, del);
      item.addEventListener("click", () => openChat(chat.id));
      list.appendChild(item);
    }
  }
}

function renderMessages(messages) {
  const box = $("#messages");
  box.innerHTML = "";
  for (const m of messages) {
    appendMessage(m.role, m.content, m.model);
  }
}

function appendMessage(role, content, model, isError = false) {
  const box = $("#messages");
  const placeholder = box.querySelector(".placeholder");
  if (placeholder) placeholder.remove();

  const wrap = document.createElement("div");
  wrap.className = "msg " + (role === "user" ? "user" : "assistant");

  const bubble = document.createElement("div");
  bubble.className = "bubble" + (isError ? " error" : "");
  const text = document.createElement("div");
  text.className = "msg-text";
  text.textContent = content;
  bubble.appendChild(text);

  const meta = document.createElement("div");
  meta.className = "msg-meta";
  meta.textContent = role === "user" ? "Вы" : model || "Ассистент";
  wrap.appendChild(bubble);
  wrap.appendChild(meta);
  box.appendChild(wrap);
  box.scrollTop = box.scrollHeight;
  return wrap;
}

function appendTyping() {
  const box = $("#messages");
  const placeholder = box.querySelector(".placeholder");
  if (placeholder) placeholder.remove();

  const wrap = document.createElement("div");
  wrap.className = "msg assistant";
  const bubble = document.createElement("div");
  bubble.className = "bubble typing";
  bubble.textContent = "Печатает…";
  wrap.appendChild(bubble);
  box.appendChild(wrap);
  box.scrollTop = box.scrollHeight;
  return wrap;
}

/* ----------------------------- Chat actions ----------------------------- */

async function newChat(agentId) {
  try {
    const chat = await api("/api/chats", {
      method: "POST",
      body: JSON.stringify({ agent_id: agentId }),
    });
    state.activeChatId = null;
    await refreshChats();
    await openChat(chat.id);
  } catch (err) {
    showError(err.message);
  }
}

async function openChat(chatId) {
  try {
    const chat = await api(`/api/chats/${chatId}`);
    state.activeChatId = chatId;
    state.activeAgentId = chat.agent_id;
    state.contextChatId = chat.context_chat_id || "";

    $("#chat-title").textContent = chat.title;
    const agent = state.agents.find((a) => a.id === chat.agent_id);
    $("#chat-agent").textContent = agent ? `· ${agent.name}` : "";

    const isAnalyst = agent && agent.id === "analyst";
    $("#context-wrap").style.display = isAnalyst ? "flex" : "none";

    renderMessages(chat.messages);
    renderChats();
    renderContextOptions();
  } catch (err) {
    showError(err.message);
  }
}

async function deleteChat(chatId) {
  if (!confirm("Удалить эту сессию со всей историей?")) return;
  try {
    await api(`/api/chats/${chatId}`, { method: "DELETE" });
    if (state.activeChatId === chatId) {
      state.activeChatId = null;
      $("#chat-title").textContent = "Выберите сессию";
      $("#chat-agent").textContent = "";
      $("#context-wrap").style.display = "none";
      const box = $("#messages");
      box.innerHTML =
        '<div class="placeholder">Создайте или выберите чат-сессию слева, чтобы начать.</div>';
    }
    await refreshChats();
  } catch (err) {
    showError(err.message);
  }
}

async function sendMessage() {
  const input = $("#composer");
  const content = input.value.trim();
  if (!content || !state.activeChatId) return;

  input.value = "";
  input.style.height = "auto";
  appendMessage("user", content);

  const typing = appendTyping();
  try {
    const body = { content };
    const agent = state.agents.find((a) => a.id === state.activeAgentId);
    if (agent && agent.id === "analyst") {
      body.context_chat_id = state.contextChatId || "";
    }
    const data = await api(`/api/chats/${state.activeChatId}/messages`, {
      method: "POST",
      body: JSON.stringify(body),
    });
    typing.remove();
    appendMessage("assistant", data.reply, data.model);
    await refreshChats();
  } catch (err) {
    typing.remove();
    appendMessage("assistant", "Ошибка: " + err.message, null, true);
  }
}

/* ----------------------------- Context select ----------------------------- */

function renderContextOptions() {
  const select = $("#context-select");
  select.innerHTML = '<option value="">— без контекста —</option>';
  const others = state.chats.filter((c) => c.agent_id !== state.activeAgentId);
  for (const chat of others) {
    const opt = document.createElement("option");
    opt.value = chat.id;
    opt.textContent = chat.title;
    select.appendChild(opt);
  }
  select.value = state.contextChatId;
}

/* ----------------------------- Settings modal ----------------------------- */

async function refreshModels() {
  try {
    const data = await api("/api/models");
    const dl = $("#models-list");
    dl.innerHTML = "";
    for (const m of data.models) {
      const opt = document.createElement("option");
      opt.value = m;
      dl.appendChild(opt);
    }
  } catch {
    /* models list is non-critical */
  }
}

function openSettings(agentId) {
  const agent = state.agents.find((a) => a.id === agentId);
  if (!agent) return;
  state.editingAgentId = agentId;
  $("#set-name").value = agent.name;
  $("#set-model").value = agent.model;
  $("#set-prompt").value = agent.system_prompt;
  $("#set-temperature").value = agent.temperature;
  $("#temp-value").textContent = Number(agent.temperature).toFixed(1);
  $("#settings-error").textContent = "";
  $("#settings-modal").classList.remove("hidden");
}

function closeSettings() {
  $("#settings-modal").classList.add("hidden");
  state.editingAgentId = null;
}

async function saveSettings() {
  const agentId = state.editingAgentId;
  if (!agentId) return;
  try {
    const body = {
      name: $("#set-name").value,
      model: $("#set-model").value,
      system_prompt: $("#set-prompt").value,
      temperature: parseFloat($("#set-temperature").value),
    };
    await api(`/api/agents/${agentId}`, {
      method: "PUT",
      body: JSON.stringify(body),
    });
    closeSettings();
    await refreshAgents();
    await refreshChats();
  } catch (err) {
    $("#settings-error").textContent = err.message;
  }
}

/* ----------------------------- Health / export ----------------------------- */

async function updateHealth() {
  const dot = $("#status-dot");
  const text = $("#status-text");
  try {
    const h = await api("/api/health");
    dot.className = "dot " + (h.llm.reachable ? "ok" : "bad");
    text.textContent = h.llm.reachable ? "LLM подключён" : "LLM недоступен";
  } catch {
    dot.className = "dot bad";
    text.textContent = "Сервер недоступен";
  }
}

async function exportData() {
  try {
    const data = await api("/api/export");
    const blob = new Blob([JSON.stringify(data, null, 2)], {
      type: "application/json",
    });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "realtor-ai-export.json";
    a.click();
    URL.revokeObjectURL(a.href);
  } catch (err) {
    showError(err.message);
  }
}

function showError(msg) {
  alert("Ошибка: " + msg);
}

/* ----------------------------- Wiring ----------------------------- */

function bindEvents() {
  $("#send-btn").addEventListener("click", sendMessage);
  $("#composer").addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      sendMessage();
    }
  });
  $("#composer").addEventListener("input", (e) => {
    e.target.style.height = "auto";
    e.target.style.height = Math.min(e.target.scrollHeight, 200) + "px";
  });
  $("#context-select").addEventListener("change", (e) => {
    state.contextChatId = e.target.value;
  });
  $("#refresh-btn").addEventListener("click", () => {
    refreshAll().catch((e) => showError(e.message));
  });
  $("#export-btn").addEventListener("click", exportData);
  $("#settings-cancel").addEventListener("click", closeSettings);
  $("#settings-save").addEventListener("click", saveSettings);
  $("#settings-modal").addEventListener("click", (e) => {
    if (e.target.id === "settings-modal") closeSettings();
  });
  $("#set-temperature").addEventListener("input", (e) => {
    $("#temp-value").textContent = Number(e.target.value).toFixed(1);
  });
}

async function init() {
  bindEvents();
  try {
    await refreshAll();
  } catch (err) {
    showError(err.message);
  }
  setInterval(updateHealth, 15000);
}

init();
