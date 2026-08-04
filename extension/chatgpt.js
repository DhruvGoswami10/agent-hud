// Agent HUD bridge: ChatGPT web activity -> HUD agent events.
(() => {
  let generating = false;

  function isGenerating() {
    return !!document.querySelector(
      '[data-testid="stop-button"], button[aria-label*="Stop streaming"], button[aria-label*="Stop generating"]'
    );
  }

  function chatTitle() {
    const t = document.title.replace(/ \| ChatGPT$/, "").trim();
    return t && t !== "ChatGPT" ? t : "New chat";
  }

  function send(kind, msg) {
    try {
      chrome.runtime.sendMessage({
        type: "hud",
        path: "/event",
        body: {
          event: kind,
          host: "web",
          project: "ChatGPT",
          session_id: "chatgpt-" + location.pathname,
          session_name: chatTitle(),
          message: msg,
          hook: "browser",
        },
      }, () => { void chrome.runtime.lastError; });
    } catch (e) { /* extension reloading */ }
  }

  setInterval(() => {
    const g = isGenerating();
    if (g && !generating) send("running", "generating…");
    if (!g && generating) send("done", "response finished");
    generating = g;
  }, 1000);
})();
