// Agent HUD bridge: YouTube / YouTube Music now-playing + remote control.
// Reports player state to the HUD; polls for control commands (the HUD can't
// reach into a browser tab, so the tab pulls its own commands).
(() => {
  let lastPlayingAt = 0;

  // Stable per-tab identity: the HUD keeps one state per tab and addresses
  // commands to the tab that owns the bar, so two open players can't steal
  // each other's button presses. It comes from the extension, because the page
  // has nothing that is honestly per-tab: sessionStorage survives reloads but
  // is *copied* into any context opened from this one (Duplicate Tab,
  // window.open, cmd-click), which would silently sit two live players on one
  // lane. A tab id is unique, reload-stable, and never cloned.
  let TAB = localTab();

  function localTab() {
    try {
      const saved = sessionStorage.getItem("agentHudTab");
      if (saved) return saved;
    } catch (e) { /* storage blocked: fall through to a per-load id */ }
    const id = Math.random().toString(36).slice(2) + Date.now().toString(36);
    try { sessionStorage.setItem("agentHudTab", id); } catch (e) {}
    return id;
  }

  // Ask the worker who we are. Never rejects and never hangs: an orphaned
  // content script throws on send, a dead worker just never answers, and both
  // fall back to the local id rather than stalling the loops behind them.
  function resolveTab() {
    return new Promise((resolve) => {
      let done = false;
      const finish = (id) => { if (!done) { done = true; resolve(id); } };
      setTimeout(() => finish(null), 2000); // no answer: keep the local id
      try {
        chrome.runtime.sendMessage({ type: "tabId" }, (id) => {
          void chrome.runtime.lastError;
          finish(typeof id === "number" ? id : null);
        });
      } catch (e) { finish(null); }
    });
  }

  const isMusic = location.hostname === "music.youtube.com";

  // The actual player's <video> only. Browse pages (home, search,
  // subscriptions) mount real <video> elements for inline hover previews that
  // linger, paused, after the pointer leaves — a bare querySelector("video")
  // would report those as now-playing (bare page title, random channel) and
  // fool the policy's "no player → never poll" rule. Those previews live in
  // their own player (#inline-preview-player), so naming the three real ones
  // still shuts them out: #movie_player (watch), #shorts-player (/shorts/,
  // where #movie_player doesn't exist at all) and ytmusic-player.
  function playerVideo() {
    // /shorts/ keeps a swipe list of reels around and only one of them is the
    // short you can actually hear; ask for that one first, since the id lookup
    // below would just take whichever reel comes first in the document.
    return (
      document.querySelector("ytd-reel-video-renderer[is-active] video") ||
      document.querySelector("#movie_player video, #shorts-player video, ytmusic-player video")
    );
  }

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
      // Only the background worker can raise a tab — and this needs no player.
      try { chrome.runtime.sendMessage({ type: "focusTab" }, () => { void chrome.runtime.lastError; }); } catch (e) {}
      return;
    }
    if (!video) return;
    if (cmd === "playpause") {
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

  async function postState(video) {
    const title = cleanTitle();
    if (!title) return;
    const id = videoId();
    await hud("/music/state", {
      source: "YouTube",
      title,
      artist: channelName(),
      playing: !video.paused && !video.ended,
      artwork_url: id ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : "",
      tab: TAB,
    });
  }

  const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

  // Commands ride a long-poll while this tab is in play: one request stays
  // parked at the HUD and is answered the instant a button is pressed —
  // click-to-audio without the poll gap. Fetches aren't throttled in
  // background tabs, so this reaches paused tabs too (timers wouldn't).
  // Pacing lives in HUDPolicy so it can be tested; see policy.js for why
  // video-less pages never poll — the one exception is carved out below, and
  // it is narrow enough that a tab which never played anything never asks the
  // HUD for anything, ever.
  async function commandLoop() {
    for (;;) {
      if (!chrome.runtime || !chrome.runtime.id) return; // orphaned after a reload
      let video = playerVideo();
      const state = {
        hasVideo: !!video,
        playing: !!video && !video.paused && !video.ended,
        lastPlayingAt: lastPlayingAt,
        now: Date.now(),
      };
      if (!HUDPolicy.shouldPoll(state)) {
        // No player. Policy's answer is "never poll", and a browse tab that
        // has never played anything obeys it to the letter — zero requests,
        // forever. The single exception is the tab that plausibly still owns
        // the music bar: its player can be torn out from under it by an SPA
        // navigation while the HUD goes on addressing it, and "focus" needs no
        // video to run. That lane is slow, never parked, and it closes itself
        // as soon as this tab goes stale.
        if (!(lastPlayingAt && Date.now() - lastPlayingAt <= HUDPolicy.PARK_WINDOW)) {
          await sleep(2000);
          continue;
        }
        const r = await hud("/music/commands?tab=" + TAB);
        const cmds = (r && r.data && r.data.commands) || [];
        for (const cmd of cmds) run(cmd, null);
        await sleep(5000);
        continue;
      }
      const parked = HUDPolicy.shouldPark(state);
      const r = await hud("/music/commands?tab=" + TAB + (parked ? "&wait=1" : ""));
      const cmds = (r && r.data && r.data.commands) || [];
      if (cmds.length) {
        // The player can be swapped out during a 20s park (SPA navigation).
        video = playerVideo() || video;
        for (const cmd of cmds) run(cmd, video);
        lastPlayingAt = Date.now(); // user intent: this tab is relevant again
        await postState(video);     // immediate echo — the bar mustn't wait a beat
      }
      await sleep(HUDPolicy.nextDelay(r, parked));
    }
  }

  // State reporting stays on a slow beat; idle background tabs go quiet so
  // they can't clobber the active one — but they always keep listening.
  async function tick() {
    const video = playerVideo();
    if (!video) return;
    const playing = !video.paused && !video.ended;
    if (playing) lastPlayingAt = Date.now();
    if (playing || Date.now() - lastPlayingAt <= 120000) await postState(video);
  }

  // Settle the identity first: a state post or a command poll sent under the
  // provisional id would open a lane nothing ever drains again.
  (async () => {
    const id = await resolveTab();
    if (id !== null) TAB = "yt-" + id;
    setInterval(tick, 2000);
    commandLoop();
  })();
})();
