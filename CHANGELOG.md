# Changelog

## 0.3.0 — 2026-09-18

- Hover works again after dismissing a notification: a deliberate move back
  onto the notch re-arms it inside the old popup bounds. A stationary pointer
  and small pointer jitter keep the dismissed popup closed.
- Preserve exact session locations across sparse events and reporter refreshes;
  retain bounded private hook metadata across app restarts.
- Open recorded cmux workspaces/panes, Warp session links, and local Terminal
  or iTerm2 tabs/panes. Cursor opens its workspace. Other supported sources
  open their recorded app; missing locations are explained instead of guessing
  whichever terminal happens to be running.
- The paired browser bridge returns to the matching ChatGPT/Claude tab and
  window. Closed tabs reopen their conversation URL. Failed commands expose
  a link fallback; expiring commands cannot unexpectedly steal focus later.
  No additional extension permissions are required.
- Reload the 0.3.0 extension and existing chat tabs. Existing pairing keys stay
  valid. New terminal locations are captured on the next hooked agent turn.
- Mac, browser, Safari, and reporter versions advance to 0.3.0. Event protocol
  stays at version 2; the unchanged Watch companion remains 0.2.0.

## 0.2.2 — 2026-09-18

- Stop recursive Codex notifier chains, including wrappers that retain Agent
  HUD as their previous notifier. The original notifier still runs once.
- Ignore repeated delivery IDs before changing session state or showing a
  popup. Codex completion retries no longer reopen a dismissed notification
  or mark a newer run as finished.
- Reproduced the live failure with a repeated completion stream: both × and
  clicking the popup now keep it dismissed while retries continue.
- Restoring Keep Awake no longer requests Accessibility at launch. Ordinary
  display/system holds work without it; optional idle-lock prevention asks
  only when enabled explicitly in Settings.
- Nine new regressions cover the notifier cycle, delivery IDs, dismissal,
  session state, source isolation, legacy events and permission requests. Mac app and bundled
  Codex adapter updated; browser, reporter, Safari and Watch versions remain 0.2.0.

## 0.2.1 — 2026-09-18

- Slide-outs accept the first click while another app is active; clicking no
  longer merely focuses the HUD. A visible dismiss button and Escape also close them.
- Dismissal suppresses hover reopening until the pointer leaves the HUD.
- Mute All Alerts retracts the current slide-out and suppresses subsequent
  agent, clipboard and music slide-outs while preserving session activity.
- Turning off system banners immediately clears the permission warning.
- Five interaction regressions reproduce the previous failures and pass with
  the fixes. Browser, reporter, Safari and Watch components remain at 0.2.0.

## 0.2.0 — 2026-09-18

Reliability release following the September audit. Includes the privacy and
server hardening that had not reached the original 0.1.0 download.

- Stable provider/thread identities, explicit Codex lifecycle, source-owned
  registry cleanup, and separate successful/interrupted/error/unknown outcomes.
- Bounded panel scrolling with all retained sessions accessible; original
  clipboard identity and fidelity, with explicit preview-only limits.
- Safe, idempotent configuration edits and notifier chaining/restoration;
  Codex stdin hooks and complete provider uninstall support.
- Browser conversation identity and navigation handling; paired extension
  access replaces blanket extension-origin trust. **Re-pair updated bridges.**
- Honest context capacity, expiring account readings, unverified Codex account
  attribution, successful-tool editing estimates, and timed-hold persistence.
- Source navigation, music arbitration and artwork invalidation, compositor
  pulsing, bounded reporter caches, and visible connection health.
- Reporter scripts included in the app; checksum-based remote updates and a
  tunnel keeper that manages only its own SSH children.
- Opt-in authenticated TLS Watch relay, certificate pairing, stable Watch IDs,
  foreground lifecycle, and correctly scoped activity labels.

Mac/Safari builds are ad-hoc signed. Physical Watch deployment requires the
user’s Apple development signing; no notarized or App Store build is claimed.
