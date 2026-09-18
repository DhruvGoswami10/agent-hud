// Tests for the browser extension's command-channel pacing (extension/policy.js).
// These encode three bugs an adversarial review caught before release; each
// assertion below fails against the pre-fix code.
//
//     node tests/test_extension.mjs        (or: make test)
import assert from "node:assert";
import fs from "node:fs";
import vm from "node:vm";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
new Function(fs.readFileSync(path.join(here, "..", "extension", "policy.js"), "utf8"))();
const P = globalThis.HUDPolicy;

const NOW = 1_000_000;
const state = (o) => ({ hasVideo: true, playing: false, lastPlayingAt: 0, now: NOW, ...o });

let run = 0;
function test(name, fn) {
  run++;
  try {
    fn();
    console.log("ok   " + name);
  } catch (e) {
    console.error("FAIL " + name + "\n     " + e.message);
    process.exitCode = 1;
  }
}

// --- a page with no player must never poll ---------------------------------
// Fetched commands are POPPED off the HUD, so a video-less tab (youtube.com
// home, search, subscriptions) that polls silently eats the playing tab's
// button press — and holds a socket while doing it.
test("a page without a player does not poll at all", () => {
  assert.equal(P.shouldPoll(state({ hasVideo: false })), false);
  assert.equal(P.shouldPark(state({ hasVideo: false, playing: true })), false);
});

test("a page with a player polls", () => {
  assert.equal(P.shouldPoll(state()), true);
});

// --- only tabs in play may hold a parked connection ------------------------
// Chrome allows 6 sockets per origin; idle tabs parking them starve music
// state and agent events behind a 20s wait.
test("a playing tab parks", () => {
  assert.equal(P.shouldPark(state({ playing: true })), true);
});

test("a recently-playing tab still parks", () => {
  assert.equal(P.shouldPark(state({ lastPlayingAt: NOW - 30_000 })), true);
});

test("a long-idle tab stops parking but keeps polling", () => {
  const s = state({ lastPlayingAt: NOW - (P.PARK_WINDOW + 1000) });
  assert.equal(P.shouldPark(s), false, "must release its socket");
  assert.equal(P.shouldPoll(s), true, "but must stay reachable — a deaf tab's play button does nothing");
});

// --- the floor -------------------------------------------------------------
// An instant answer (an older HUD build ignoring wait=1, a 404, or the server
// evicting the oldest parked poll) must never become a zero-delay spin:
// measured at 774 req/s, ~1 pegged core, thousands of sockets in TIME_WAIT.
test("every successful iteration has a non-zero floor", () => {
  assert.ok(P.nextDelay({ ok: true }, true) >= P.MIN_DELAY);
  assert.ok(P.nextDelay({ ok: true }, false) >= P.MIN_DELAY);
  assert.ok(P.MIN_DELAY > 0);
});

test("errors back off hard", () => {
  assert.equal(P.nextDelay({ ok: false, status: 404 }, true), 3000);
  assert.equal(P.nextDelay(null, true), 3000);
});

test("a parked answer re-parks promptly, an unparked one waits longer", () => {
  assert.ok(P.nextDelay({ ok: true }, true) < P.nextDelay({ ok: true }, false));
});



new Function(fs.readFileSync(path.join(here, "..", "extension", "chat-lifecycle.js"), "utf8"))();
function chatFixture() {
  const events = [];
  const tracker = new globalThis.HUDChatLifecycle({ provider: "chatgpt", canonical: p => p.startsWith("/c/") ? p : "",
    send: e => events.push(e) });
  const tick = (p, generating, now, extra = {}) => tracker.tick({ path: p, generating, now, title: p, url: "https://chatgpt.com" + p, ...extra });
  return { events, tracker, tick };
}
test("new conversation keeps its identity on the next turn", () => {
  const { events, tick } = chatFixture();
  tick("/", true, 1000); tick("/c/123", true, 2000);
  tick("/c/123", false, 3000); tick("/c/123", false, 5000);
  tick("/c/123", true, 6000);
  assert.equal(new Set(events.map(e => e.session_id)).size, 1);
});
test("navigation ends the old conversation without reporting success or renaming it", () => {
  const { events, tick } = chatFixture();
  tick("/c/123", true, 1000); tick("/c/456", false, 2000);
  assert.equal(events.at(-1).outcome, "unknown");
  assert.equal(events.at(-1).session_name, "/c/123");
});
test("stop-button flicker is debounced and a user stop is interrupted", () => {
  const { events, tracker, tick } = chatFixture();
  tick("/c/123", true, 1000); tick("/c/123", false, 2000); tick("/c/123", true, 3000);
  assert.equal(events.length, 1);
  tracker.interrupted = true;
  tick("/c/123", false, 4000); tick("/c/123", false, 6000);
  assert.equal(events.at(-1).outcome, "interrupted");
});
test("missing DOM evidence never produces a successful finish", () => {
  const { events, tick } = chatFixture();
  tick("/c/123", true, 1000); tick("/c/123", false, 2000); tick("/c/123", false, 4000);
  assert.equal(events.at(-1).outcome, "unknown");
});



for (const [provider, initial, canonical] of [["chatgpt", "/", "/c/test"], ["claude", "/new", "/chat/test"]]) {
  test(provider + " actual DOM adapter preserves conversation and reports navigation honestly", () => {
    const events = []; let tick; let streaming = true; let now = 1000;
    const context = { HUDChatLifecycle: globalThis.HUDChatLifecycle,
      location: { pathname: initial, href: "https://example.test" + initial },
      document: { title: "Example chat", querySelector: selector => selector.includes("conversation-error") ? null : streaming ? {} : null,
        addEventListener() {} }, sessionStorage: { getItem() { return null; }, setItem() {} },
      chrome: { runtime: { sendMessage: msg => events.push(msg.body) } },
      addEventListener() {}, setInterval: fn => { tick = fn; },
    };
    vm.runInNewContext(fs.readFileSync(path.join(here, "..", "extension", provider + ".js"), "utf8"), context);
    tick();
    context.location.pathname = canonical; tick();
    const identity = events[0].session_id;
    context.location.pathname = "/different"; streaming = false; context.document.title = "Other chat"; tick();
    assert.equal(events.at(-1).session_id, identity);
    assert.equal(events.at(-1).session_name, "Example chat");
    assert.equal(events.at(-1).outcome, "unknown");
  });
}
console.log(`\n${run} extension tests`);
