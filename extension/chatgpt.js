// Agent HUD bridge: ChatGPT web activity -> HUD agent events.
(() => {
  let generating = false;

  // One id per run, latched when the run starts: chatgpt.com rewrites / to
  // /c/<id> after the first message, so re-reading the pathname on every send
  // would split running and done across two session cards (the first one
  // stuck "working" until the HUD times it out). / can't be latched verbatim
  // either — it isn't a conversation, it's the door they all come through, and
  // every new chat would pile onto one shared card. A real path latches as
  // itself; a placeholder latches as a one-off id nothing else can collide
  // with, which is all the run needs to keep its own heartbeats and 'done'
  // together.
  let sessionId = "";
  // The run's page and name, tracked while it streams. The title has to stay
  // live — chatgpt.com names a new chat mid-run — but reading it at send time
  // is what renames the wrong card: switching conversations ends the run on
  // that very tick, and by then document.title belongs to the chat you left
  // for.
  let sessionPath = "";
  let sessionName = "";

  function runId() {
    const p = location.pathname;
    // /c/<id>, plus the /g/<gpt>/c/<id> a custom GPT's conversation lands on.
    return /^\/(g\/[^/]+\/)?c\/[^/]+/.test(p)
      ? "chatgpt-" + p
      : "chatgpt-new-" + Math.random().toString(36).slice(2);
  }

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
          session_id: sessionId || runId(),
          session_name: sessionName || chatTitle(),
          message: msg,
          hook: "browser",
        },
      }, () => { void chrome.runtime.lastError; });
    } catch (e) { /* extension reloading */ }
  }

  // Heartbeat while streaming (~30s): a closed tab stops sending, and the
  // HUD demotes silent web cards instead of showing "working" forever.
  let lastBeat = 0;
  setInterval(() => {
    const g = isGenerating();
    if (g && !generating) sessionId = runId(); // new run: latch its id
    // Follow the run's own page: it may rewrite / to /c/<id> under us, and
    // while we're still on it the title is worth re-reading. Once we're
    // somewhere else the last one we saw is the only honest answer.
    if (g || location.pathname === sessionPath) {
      sessionPath = location.pathname;
      sessionName = chatTitle();
    }
    if (g && (!generating || Date.now() - lastBeat > 30000)) {
      send("running", "generating…");
      lastBeat = Date.now();
    }
    if (!g && generating) send("done", "response finished");
    generating = g;
  }, 1000);
})();
