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
async function asyncTest(name, fn) {
  run++;
  try { await fn(); console.log("ok   " + name); }
  catch (e) { console.error("FAIL " + name + "\n     " + e.stack); process.exitCode = 1; }
}

async function browserFixture(tabs = []) {
  const calls = [], requests = [], delays = [];
  const client = "a1459d36-9666-44b4-bd6d-b27a5f97b0d9";
  let receive, key = "", nextCommands = [], windowFails = false;
  const runtime = { getURL: () => "chrome-extension://test/", lastError: null,
    onMessage: { addListener: fn => { receive = fn; } }, onStartup: { addListener() {} } };
  const session = {};
  const context = {
    URL, Date, Number, Promise, crypto: { randomUUID: () => client },
    AbortSignal: { timeout() {} },
    setTimeout: (fn, ms) => { delays.push(ms); queueMicrotask(fn); },
    chrome: { runtime,
      storage: { session: { get: (_k, cb) => cb(session), set: (v, cb) => { Object.assign(session, v); cb(); } },
        local: { get: (_k, cb) => cb({ pairingKey: key }) }, onChanged: { addListener() {} } },
      tabs: {
        get: (id, cb) => cb(tabs.find(t => t.id === id)),
        query: (_q, cb) => cb(tabs),
        sendMessage: (id, _msg, cb) => cb({ url: tabs.find(t => t.id === id)?.url }),
        update: (id, opts, cb) => { calls.push(["tab", id, opts]); cb(tabs.find(t => t.id === id)); },
        create: (opts, cb) => { calls.push(["create", opts]); cb({ id: 99, windowId: 8, url: opts.url }); },
      },
      windows: { update: (id, opts, cb) => {
        calls.push(["window", id, opts]); runtime.lastError = windowFails ? { message: "closed" } : null;
        cb(); runtime.lastError = null;
      } },
    },
    fetch: async (url, opts) => {
      requests.push({ url, opts });
      if (url.includes("/browser/commands")) {
        const commands = nextCommands; nextCommands = [];
        return { ok: commands.length > 0, status: commands.length ? 200 : 403, json: async () => ({ commands }) };
      }
      return { ok: true, status: 200, json: async () => ({ ok: true }) };
    },
  };
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(here, "..", "extension", "bg.js"), "utf8"), context);
  await new Promise(resolve => setImmediate(resolve)); // initial unpaired poll finishes
  return { context, calls, requests, delays, client,
    pair: () => { key = "test-only-key"; },
    commands: value => { nextCommands = value.map(JSON.stringify); },
    failWindow: () => { windowFails = true; },
    message: (msg, sender) => new Promise(resolve => receive(msg, sender, resolve)),
  };
}
const focusCommand = (extra = {}) => ({ id: "e13f2348-1b32-4206-bca2-042bdac9f359", tab: "12",
  url: "https://chatgpt.com/c/one", expires: Date.now() + 5000, ...extra });

await asyncTest("browser focuses the original conversation tab and its window", async () => {
  const b = await browserFixture([{ id: 12, windowId: 4, url: "https://chatgpt.com/c/one" }]);
  assert.equal(await b.context.focusConversation(focusCommand()), true);
  assert.deepEqual(b.calls.map(c => c.slice(0, 2)), [["tab", 12], ["window", 4]]);
});
await asyncTest("a navigated tab is skipped in favor of the existing matching conversation", async () => {
  const b = await browserFixture([{ id: 12, windowId: 4, url: "https://chatgpt.com/c/other" },
    { id: 14, windowId: 6, url: "https://chatgpt.com/c/one" }]);
  assert.equal(await b.context.focusConversation(focusCommand()), true);
  assert.deepEqual(b.calls.map(c => c.slice(0, 2)), [["tab", 14], ["window", 6]]);
});
await asyncTest("a closed conversation tab reopens only its recorded link", async () => {
  const b = await browserFixture();
  assert.equal(await b.context.focusConversation(focusCommand()), true);
  assert.equal(b.calls[0][0], "create");
  assert.equal(b.calls[0][1].url, "https://chatgpt.com/c/one");
});
await asyncTest("expired commands and unsupported links cannot navigate", async () => {
  const b = await browserFixture();
  for (const url of ["https://example.com/", "javascript:alert(1)", "https://chatgpt.com:8000/c/one",
    "https://user@chatgpt.com/c/one"]) {
    assert.equal(await b.context.focusConversation(focusCommand({ url })), false);
  }
  assert.equal(await b.context.focusConversation(focusCommand({ expires: Date.now() - 1 })), false);
  assert.equal(await b.context.focusConversation(focusCommand({ tab: "not a tab" })), false);
  assert.equal(b.calls.length, 0);
});
await asyncTest("window activation errors are reported instead of claiming success", async () => {
  const b = await browserFixture([{ id: 12, windowId: 4, url: "https://chatgpt.com/c/one" }]);
  b.failWindow();
  assert.equal(await b.context.focusConversation(focusCommand()), false);
});
await asyncTest("web events capture the sender's real tab and browser identity", async () => {
  const b = await browserFixture(); b.pair();
  const reply = await b.message({ type: "hud", path: "/event", body: { host: "web", event: "running",
    focus: { url: "https://chatgpt.com/c/one", browser_tab: "999", browser_client: "forged" } } },
    { tab: { id: 12 }, url: "https://chatgpt.com/c/one" });
  assert.equal(reply.ok, true);
  const body = JSON.parse(b.requests.find(r => r.url.endsWith("/event")).opts.body);
  assert.equal(body.focus.browser_tab, "12");
  assert.equal(body.focus.browser_client, b.client);
  assert.equal(body.focus.application, "com.google.Chrome");
  assert.equal(body.pairingKey, undefined);
});
await asyncTest("the command loop acknowledges focus and retains a polling floor", async () => {
  const b = await browserFixture([{ id: 12, windowId: 4, url: "https://chatgpt.com/c/one" }]);
  b.pair(); b.commands([focusCommand()]);
  await b.context.pollFocusCommands();
  const ack = b.requests.find(r => r.url.endsWith("/browser/focus-result"));
  assert.equal(JSON.parse(ack.opts.body).ok, true);
  assert.equal(JSON.parse(ack.opts.body).id, focusCommand().id);
  assert.ok(b.delays.includes(250));
});
await asyncTest("content scripts cannot forge a browser focus acknowledgment", async () => {
  const b = await browserFixture(); b.pair();
  const reply = await b.message({ type: "hud", path: "/browser/focus-result", body: { ok: true } }, { tab: { id: 12 } });
  assert.equal(reply.status, 400);
  assert.equal(b.requests.length, 0);
});

console.log(`\n${run} extension tests`);
