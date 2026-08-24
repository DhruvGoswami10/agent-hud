# Agent HUD Bridge (browser extension)

Feeds the Agent HUD notch app from the browser:

- **YouTube / YouTube Music** — now-playing (title, channel, thumbnail) into the
  HUD's music bar, with working play/pause/next/prev (the tab polls
  `GET /music/commands` for button presses).
- **ChatGPT** (chatgpt.com) — "running" while generating, "done" when the
  response finishes, labeled with the chat title.
- **Claude** (claude.ai) — same.

## Install — Chrome / Arc / Edge / Brave

1. Open `chrome://extensions`
2. Enable **Developer mode** (top right)
3. **Load unpacked** → select this `extension/` folder

That's it — no build step. After changing any file here, hit the reload icon on
the extension card.

## Install — Safari

Safari requires wrapping the same files in an Xcode app target:

```sh
xcrun safari-web-extension-converter ~/agent-hud/extension --app-name "Agent HUD Bridge"
```

then build/run the generated project once and enable the extension in
Safari → Settings → Extensions (allow on youtube.com, chatgpt.com, claude.ai).

One more Safari-only step: also allow the extension on **127.0.0.1** (in the
same Extensions pane, or just pick **Always Allow on Every Website**). Safari
gates the background script's `http://127.0.0.1:48085` calls behind their own
per-site permission — and since you never *visit* 127.0.0.1, nothing ever
prompts for it. Skip this and the whole bridge is silently dead.

## Notes

- Everything talks to `http://127.0.0.1:48085` (the HUD's listener). If the HUD
  isn't running the scripts fail silently.
- ChatGPT/Claude detection is DOM-heuristic (stop-button presence); if either
  site redesigns, update the selector in `chatgpt.js` / `claude.js`.
- The HUD's server sends permissive CORS headers for these localhost calls.
