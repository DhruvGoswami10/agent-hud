// Tests for the browser extension's command-channel pacing (extension/policy.js).
// These encode three bugs an adversarial review caught before release; each
// assertion below fails against the pre-fix code.
//
//     node tests/test_extension.mjs        (or: make test)
import assert from "node:assert";
import fs from "node:fs";
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

console.log(`\n${run} extension tests`);
