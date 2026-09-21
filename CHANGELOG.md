# Changelog

## 0.3.5 — 2026-09-21

- Recover **Go to session** after reconnecting SSH in the original cmux pane.
  A background Claude session can keep reporting a closed connection; the old
  lookup rejected it and briefly reopened the HUD with an error.
- Match the saved workspace and surface to exactly one replacement SSH link
  for the same server and port. Revalidate its process start time, terminal,
  and dedicated connection before selecting the pane. Other panes on the same
  server, shared connections, reused processes, and ambiguous matches stay rejected.
- Keep cmux's existing native window handoff and display behavior. The fix is
  in the Mac's bundled helper; existing remote reporters do not need an update.
- Eight regression tests cover reconnects, network changes, and rejected matches.
- Mac advances to 0.3.5. Reporter remains 0.3.1, browser/Safari 0.3.0,
  Watch 0.2.0, and the event protocol remains version 2.

## 0.3.4 — 2026-09-21

- Show a green checkmark and **Copied!** for two seconds after copying the
  browser pairing key in Settings → Connections. Repeated clicks restart
  the confirmation; the button keeps the same size throughout.
- Confirm only a successful clipboard write, show **Couldn’t copy** on failure,
  and keep the key marked as concealed for clipboard managers.
- Mac advances to 0.3.4. Reporter remains 0.3.1, browser/Safari 0.3.0,
  Watch 0.2.0, and the event protocol remains version 2.

## 0.3.3 — 2026-09-21

- Replace the ambiguous awake toggle with a badge that shows the effect,
  mode, and remaining time. Clicking opens explicit **Off / Auto / Manual**
  controls, shared with Settings.
- Keep the badge, popover, and mode selector at stable sizes and positions
  while switching modes. Moving into the popover keeps the HUD open;
  closing or dismissing it restores normal hover behavior.
- Show Mac and display sleep behavior separately, plus accurate idle-lock
  status. Auto distinguishes working, attention, the 10-minute grace period,
  and ready with sleep allowed. Failed assertions never claim **Active**.
- Off releases manual and automatic holds. Ending a manual hold returns to
  the previous Auto/Off setting; timers preserve their original deadline and
  selected duration across restarts. Expiry keeps running during menu tracking.
- Use consistent manual-hold wording in the menu bar and add an explicit
  **Off — Allow Sleep** action.
- Mac advances to 0.3.3. Reporter remains 0.3.1, browser/Safari 0.3.0,
  Watch 0.2.0, and the event protocol remains version 2.

## 0.3.2 — 2026-09-18

- Select cmux sessions through its native scripting interface. The previous
  navigation URL could switch away from cmux's full-screen desktop on an
  external monitor, even with the HUD closed. Match the recorded workspace
  and terminal IDs and wait for cmux's reply before reporting success.
- Activate cmux after the pane is selected, so navigation also brings it
  forward from another desktop. Never activate an unrelated pane if selection
  fails, and report failed window activation instead of claiming success.
- Request Automation access to cmux only when **Go to session** is clicked.
  A denied grant gets a specific explanation; closed or missing terminals
  get a separate error. Accessibility and cmux's private control socket are
  not needed for navigation.
- Dismiss the HUD and release its keyboard focus before opening a session,
  so a late panel dismissal cannot interfere with the destination's focus.
- Use normal AppKit window ordering to release panel focus instead of calling
  the `resignKey` notification directly. Mouse interactions claim keyboard
  focus only when needed; the collapsed indicators and hover behavior remain.
- Browser navigation uses the same focus handoff and still waits for its
  acknowledgment. Failed navigation reopens the panel with an explanation.
- Six regression tests cover HUD handoff ordering, native success/failure,
  browser dispatch, and cmux selection followed by window activation.
- Mac advances to 0.3.2. Reporter remains 0.3.1, browser/Safari 0.3.0, Watch
  0.2.0, and the event protocol remains version 2.

## 0.3.1 — 2026-09-18

- Return to the original cmux pane for remote Claude sessions over ordinary
  SSH. Capture the Mac terminal through the existing SSH bootstrap hook and
  recover connection metadata from already-running same-user Claude processes
  on Linux, without restarting those sessions or forwarding environment values.
- Use cmux's public navigation links from the standalone HUD. Its default
  terminal-only control socket remains restricted; no new permission is needed.
- Verify the complete live SSH connection, process start time, and terminal
  before using a saved link. Refuse ambiguous shared/forwarded connections and
  stale multiplexer environments. Keep at most 256 private local SSH links.
- Use **Go to session** consistently. Sessions without a linked source show
  a disabled button and **No linked window yet**.
- Remove the notification ×. Clicking the popup still dismisses it when that
  setting is enabled, and the accessible dismiss action remains available.
  The hover behavior fixed in 0.3.0 is unchanged.
- Mac and reporter versions advance to 0.3.1. Browser/Safari remain 0.3.0,
  Watch remains 0.2.0, and the event protocol remains version 2.

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
