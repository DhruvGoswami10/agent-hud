// Agent HUD bridge: Claude web activity -> HUD agent events.
(() => {
  let generating = false;

  function isGenerating() {
    return !!document.querySelector(
      '[data-is-streaming="true"], button[aria-label*="Stop response"], button[aria-label*="Stop Response"]'
    );
  }

  function chatTitle() {
    const t = document.title.replace(/ [-–] Claude$/, "").trim();
    return t && t !== "Claude" ? t : "New chat";
  }

  function send(kind, msg) {
    try {
      chrome.runtime.sendMessage({
        type: "hud",
        path: "/event",
        body: {
          event: kind,
          host: "web",
          project: "Claude",
          session_id: "claude-" + location.pathname,
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
