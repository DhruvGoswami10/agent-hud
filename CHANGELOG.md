# Changelog

## 0.2.1 — 2026-09-18

- Slide-outs accept the first click while another app is active; clicking no
  longer merely focuses the HUD. A visible dismiss button and Escape also close them.
- Dismissal suppresses hover reopening until the pointer leaves the HUD.
- Mute All Alerts retracts the current slide-out and suppresses subsequent
  agent, clipboard and music slide-outs while preserving session activity.
- Turning off system banners immediately clears the permission warning.
- Four interaction regressions reproduce the previous failures and pass with
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
