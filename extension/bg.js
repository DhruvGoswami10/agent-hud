// Background service worker: the only place that talks to the HUD.
// Content scripts can't reliably fetch localhost from https pages (CORS /
// Local Network Access), but an extension worker with host_permissions can.
const HUD_ORIGIN = "http://127.0.0.1:48085";
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let clientPromise;
let focusPolling = false;

function focusClient() {
  // Session storage prevents a restarted browser reusing old numeric tab IDs.
  // Safari versions without it fall back to a new identity for this worker.
  return clientPromise ||= new Promise(resolve => {
    const storage = chrome.storage.session;
    if (!storage) { resolve(crypto.randomUUID()); return; }
    storage.get("focusClient", data => {
      if (/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(data.focusClient || "")) {
        resolve(data.focusClient); return;
      }
      const id = crypto.randomUUID();
      storage.set({ focusClient: id }, () => resolve(id));
    });
  });
}

function pairingKey() {
  return new Promise(resolve => chrome.storage.local.get("pairingKey", data => resolve(data.pairingKey || "")));
}

function browserApplication() {
  const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;
  if (/Edg\//.test(ua)) return "com.microsoft.edgemac";
  if (/Firefox\//.test(ua)) return "org.mozilla.firefox";
  if (chrome.runtime.getURL?.("").startsWith("safari-web-extension:")) return "com.apple.Safari";
  return "com.google.Chrome";
}

function chatURL(raw) {
  try {
    const u = new URL(raw);
    return u.protocol === "https:" && !u.username && !u.password && !u.port &&
      ["chatgpt.com", "chat.openai.com", "claude.ai"].includes(u.hostname) ? u : null;
  } catch { return null; }
}

function tabCall(method, ...args) {
  return new Promise(resolve => {
    try { chrome.tabs[method](...args, result => resolve(chrome.runtime.lastError ? null : result)); }
    catch { resolve(null); }
  });
}

async function focusConversation(command) {
  const target = chatURL(command.url);
  if (!target || !/^\d{1,12}$/.test(command.tab || "") ||
      !Number.isFinite(command.expires) || command.expires <= Date.now()) return false;
  // Ask the already-authorized content script to verify its own location.
  // This needs no broad "tabs" or browsing-history permission.
  const matches = async tab => {
    if (!tab || !Number.isInteger(tab.id)) return false;
    const reply = await tabCall("sendMessage", tab.id, { type: "agentHUDFocusCheck" });
    const current = chatURL(reply?.url);
    return current?.origin === target.origin && current?.pathname === target.pathname;
  };
  let tab = await tabCall("get", Number(command.tab));
  if (!(await matches(tab))) {
    tab = null;
    for (const candidate of await tabCall("query", {}) || []) {
      if (await matches(candidate)) { tab = candidate; break; }
    }
  }
  if (command.expires <= Date.now()) return false;
  if (!tab) tab = await tabCall("create", { url: target.href, active: true });
  else tab = await tabCall("update", tab.id, { active: true });
  if (!tab) return false;
  if (tab.windowId === undefined) return false;
  return new Promise(resolve => {
    chrome.windows.update(tab.windowId, { focused: true }, () => resolve(!chrome.runtime.lastError));
  });
}

async function pollFocusCommands() {
  if (focusPolling) return;
  focusPolling = true;
  try {
    const client = await focusClient();
    for (;;) {
      const key = await pairingKey();
      if (!key) return;
      let ok = false;
      try {
        const r = await fetch(HUD_ORIGIN + "/browser/commands?client=" + client + "&wait=1", {
          headers: { "X-Agent-HUD-Token": key, "X-Agent-HUD-Client": "browser" },
          signal: AbortSignal.timeout(25000),
        });
        if (r.status === 401 || r.status === 403) return;
        ok = r.ok;
        if (ok) for (const raw of (await r.json()).commands || []) {
          try {
            const command = JSON.parse(raw);
            const opened = await focusConversation(command);
            if (command.id) await fetch(HUD_ORIGIN + "/browser/focus-result", {
              method: "POST", headers: { "Content-Type": "application/json", "X-Agent-HUD-Token": key,
                "X-Agent-HUD-Client": "browser" }, body: JSON.stringify({ id: command.id, ok: opened }),
              signal: AbortSignal.timeout(3000),
            });
          } catch { /* stale or invalid command */ }
        }
      } catch { /* HUD is restarting or not running */ }
      await sleep(ok ? 250 : 3000); // even an immediate empty reply must not spin
    }
  } finally { focusPolling = false; }
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "hud") {
    if (!/^\/(event|health|music\/state|music\/commands)(\?.*)?$/.test(msg.path || "")) {
      sendResponse({ ok: false, status: 400 }); return;
    }
    (async () => {
      const key = await pairingKey();
      if (!key) { sendResponse({ ok: false, status: 401, pairingRequired: true }); return; }
      const headers = { "Content-Type": "application/json", "X-Agent-HUD-Token": key,
        "X-Agent-HUD-Client": "browser" };
      let body = msg.body;
      if (msg.path === "/event" && body?.host === "web" && Number.isInteger(sender.tab?.id)) {
        body = { ...body, focus: { ...body.focus, browser_client: await focusClient(),
          browser_tab: String(sender.tab.id), application: browserApplication(),
          url: body.focus?.url || chatURL(sender.url)?.href || "" } };
      }
      void pollFocusCommands();
      const opts = body ? { method: "POST", headers, body: JSON.stringify(body) } : { headers };
      fetch(HUD_ORIGIN + msg.path, opts)
        .then((r) => r.json().catch(() => null).then((data) => ({ r, data })))
        .then(({ r, data }) => sendResponse({ ok: r.ok, status: r.status, data }))
        .catch(() => sendResponse({ ok: false }));
    })().catch(() => sendResponse({ ok: false }));
    return true; // keep the message channel open for the async response
  }
  if (msg && msg.type === "tabId") {
    // The asking tab's own id. Content scripts have no way to tell themselves
    // apart: sessionStorage looks per-tab but is *copied* into a duplicated
    // tab, so two live players would end up sharing one HUD lane. A tab id is
    // unique, survives reloads, and is never cloned. Answered synchronously —
    // the channel is already settled, so nothing has to stay open for it.
    sendResponse(sender.tab ? sender.tab.id : null);
    return;
  }
  if (msg && msg.type === "focusTab" && sender.tab) {
    // Raise the tab that asked (a "focus" music command it pulled from the
    // HUD) — content scripts can't do this themselves.
    chrome.tabs.update(sender.tab.id, { active: true });
    if (sender.tab.windowId !== undefined) {
      chrome.windows.update(sender.tab.windowId, { focused: true });
    }
  }
});

chrome.storage.onChanged?.addListener((changes, area) => {
  if (area === "local" && changes.pairingKey) void pollFocusCommands();
});
chrome.runtime.onStartup?.addListener(() => { void pollFocusCommands(); });
void pollFocusCommands();
