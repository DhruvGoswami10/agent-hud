// Background service worker: the only place that talks to the HUD.
// Content scripts can't reliably fetch localhost from https pages (CORS /
// Local Network Access), but an extension worker with host_permissions can.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "hud") {
    if (!/^\/(event|health|music\/state|music\/commands)(\?.*)?$/.test(msg.path || "")) {
      sendResponse({ ok: false, status: 400 }); return;
    }
    chrome.storage.local.get("pairingKey", ({ pairingKey }) => {
      if (!pairingKey) { sendResponse({ ok: false, status: 401, pairingRequired: true }); return; }
      const headers = { "Content-Type": "application/json", "X-Agent-HUD-Token": pairingKey,
        "X-Agent-HUD-Client": "browser" };
      const opts = msg.body ? { method: "POST", headers, body: JSON.stringify(msg.body) } : { headers };
      fetch("http://127.0.0.1:48085" + msg.path, opts)
        .then((r) => r.json().catch(() => null).then((data) => ({ r, data })))
        .then(({ r, data }) => sendResponse({ ok: r.ok, status: r.status, data }))
        .catch(() => sendResponse({ ok: false }));
    });
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
