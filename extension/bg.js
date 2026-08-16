// Background service worker: the only place that talks to the HUD.
// Content scripts can't reliably fetch localhost from https pages (CORS /
// Local Network Access), but an extension worker with host_permissions can.
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg && msg.type === "hud") {
    const opts = msg.body
      ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(msg.body) }
      : {};
    fetch("http://127.0.0.1:48085" + msg.path, opts)
      .then((r) => r.json())
      .then((data) => sendResponse({ ok: true, data }))
      .catch(() => sendResponse({ ok: false }));
    return true; // keep the message channel open for the async response
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
