# Agent HUD Bridge

YouTube / YouTube Music now-playing and tab-addressed controls, plus ChatGPT and
Claude activity. Requires Agent HUD 0.2.0 or newer and one-time browser pairing.

## Chrome, Arc, Edge, Brave

1. Extract the release extension ZIP, or use this `extension/` directory.
2. Open the browser’s Extensions page, enable Developer mode, and Load unpacked.
3. In Mac Agent HUD Settings → Connections, click **Copy pairing key**.
4. Open the extension’s toolbar popup, paste the key, and pair.
5. Reload existing chat and music tabs.

After an update, reload the extension and its tabs. The key remains in extension
local storage. It is never exposed to the website’s content scripts.

## Safari

Open the release’s Safari Bridge app and enable its extension in Safari Settings.
Allow the supported chat/music sites and `127.0.0.1`, then pair using the toolbar
popup as above. Unsigned development extensions may require Safari’s **Allow
Unsigned Extensions** developer setting; the release wrapper is ad-hoc signed,
not notarized. Full Xcode can build the checked-in `safari/` project from source.

## Behavior and trust

Only the extension background worker contacts `127.0.0.1:48085`. Website origins
are refused; extension requests require the pairing key. The native/SSH API
continues to trust local clients. Keys can be removed from browser storage by
uninstalling the extension.

Chat detection uses page markup, which can change. A missing stop button is
not proof of success. Navigation and unconfirmed stopping become unavailable
outcomes; clicking Stop becomes interrupted. Conversation identity survives the
initial new-chat URL rewrite and subsequent turns in the tab.

YouTube commands are addressed to the reporting tab. Polling is bounded and
backs off when the Mac is unavailable or the extension needs pairing.
