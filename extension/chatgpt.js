// DOM adapter: observations are debounced and navigation is never a success.
(() => {
  const stopSelector = '[data-testid="stop-button"], button[aria-label*="Stop streaming"], button[aria-label*="Stop generating"]';
  let aliases = {};
  try { aliases = JSON.parse(sessionStorage.getItem("agent-hud-conversations") || "{}"); } catch {}
  const tracker = new HUDChatLifecycle({
    provider: 'chatgpt',
    canonical: (path) => /^\/(g\/[^/]+\/)?c\/[^/]+/.test(path) ? path : "",
    aliases,
    remember: (value) => { try { sessionStorage.setItem("agent-hud-conversations", JSON.stringify(value)); } catch {} },
    send: (body) => {
      try { chrome.runtime.sendMessage({ type: "hud", path: "/event", body },
        () => { void chrome.runtime.lastError; }); } catch {}
    },
  });
  document.addEventListener("click", (event) => {
    if (event.target?.closest?.(stopSelector)) tracker.interrupted = true;
  }, true);
  addEventListener("pagehide", () => tracker.stop("unknown", "Tab closed · completion unconfirmed"));
  setInterval(() => {
    const title = document.title.replace(/ \| ChatGPT$/, "").trim();
    tracker.tick({ path: location.pathname, url: location.href,
      title: title && title !== 'ChatGPT' ? title : "New chat",
      generating: !!document.querySelector(stopSelector),
      // Site markup is not a stable completion contract. Until a site exposes
      // a reliable terminal marker, stopping is explicitly unconfirmed.
      completed: false,
      error: !!document.querySelector('[data-testid="conversation-error"], [data-testid="error-message"]'),
    });
  }, 1000);
})();
