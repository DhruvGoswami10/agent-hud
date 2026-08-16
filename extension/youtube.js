// Agent HUD bridge: YouTube / YouTube Music now-playing + remote control.
// Reports player state to the HUD; polls for control commands (the HUD can't
// reach into a browser tab, so the tab pulls its own commands).
(() => {
  let lastPlayingAt = 0;

  // Stable per-tab identity: the HUD keeps one state per tab and addresses
  // commands to the tab that owns the bar, so two open players can't steal
  // each other's button presses.
  const TAB = Math.random().toString(36).slice(2) + Date.now().toString(36);

  const isMusic = location.hostname === "music.youtube.com";

  function videoId() {
    const u = new URL(location.href);
    const v = u.searchParams.get("v");
    if (v) return v;
    if (location.pathname.startsWith("/shorts/")) return location.pathname.split("/")[2] || "";
    return "";
  }

  function channelName() {
    const el = document.querySelector(
      isMusic
        ? "ytmusic-player-bar .byline a, ytmusic-player-bar .byline"
        : "ytd-channel-name a, ytd-video-owner-renderer a"
    );
    return el ? el.textContent.trim() : "";
  }

  function cleanTitle() {
    return document.title
      .replace(/ - YouTube( Music)?$/, "")
      .replace(/^\(\d+\)\s*/, "")
      .trim();
  }

  function hud(path, body) {
    return new Promise((resolve) => {
      try {
        chrome.runtime.sendMessage({ type: "hud", path, body }, (r) => {
          void chrome.runtime.lastError;
          resolve(r);
        });
      } catch (e) {
        resolve(null);
      }
    });
  }

  function run(cmd, video) {
    if (cmd === "focus") {
      // Only the background worker can raise a tab.
      try { chrome.runtime.sendMessage({ type: "focusTab" }, () => { void chrome.runtime.lastError; }); } catch (e) {}
    } else if (cmd === "playpause") {
      video.paused ? video.play() : video.pause();
    } else if (cmd === "next") {
      const b = document.querySelector(isMusic ? "ytmusic-player-bar .next-button" : ".ytp-next-button");
      if (b) b.click();
    } else if (cmd === "previous") {
      const b = document.querySelector(isMusic ? "ytmusic-player-bar .previous-button" : null);
      if (b) b.click();
      else video.currentTime = 0;
    }
  }

  async function tick() {
    const video = document.querySelector("video");
    const title = cleanTitle();
    if (!video || !title) return;
    const playing = !video.paused && !video.ended;
    if (playing) lastPlayingAt = Date.now();
    // Idle background tabs stay silent so they don't clobber the active one.
    if (!playing && Date.now() - lastPlayingAt > 120000) return;

    const id = videoId();
    await hud("/music/state", {
      source: "YouTube",
      title,
      artist: channelName(),
      playing,
      artwork_url: id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : "",
      tab: TAB,
    });

    const r = await hud("/music/commands?tab=" + TAB);
    for (const cmd of (r && r.data && r.data.commands) || []) run(cmd, video);
  }

  setInterval(tick, 2000);
})();
