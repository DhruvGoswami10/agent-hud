# September reliability audit — v0.2.0

This release addresses the 25 findings from the 18 September 2026 review.
The table distinguishes implemented fixes from verification still requiring
real hardware or a longer observation period. It is not a claim of zero bugs.

| # | Finding | Change and evidence |
|---|---|---|
| 1 | Panel overflow and seven-card cutoff | Bounded scroll areas expose all 12 retained sessions while keeping music, clipboard and activity controls in the panel. Inspected with synthetic accounts, music and 12 sessions; scrolled to the last card. |
| 2 | Codex completion identity | Thread-first IDs and provider namespaces match registry IDs; internal title replies are filtered. Adapter and state regressions pass. |
| 3 | File age mistaken for completion | Incremental rollout parsing reads explicit lifecycle records. Stale or missing sources become unavailable, never successful by inference. Tests cover completed, quiet-running and abandoned rollouts. |
| 4 | Registry ends another provider's task | Snapshots declare provider ownership. Claude/Codex snapshots preserve Cursor and generic jobs. Swift regression passes. |
| 5 | Clipboard collisions and lossy restore | Full content/path hashes, preserved whitespace, original restoration, and disabled copy for preview-only oversized entries. Text/path/fidelity regressions pass. |
| 6 | Stale public release | v0.2.0 artifacts include the intervening privacy and HTTP hardening, bundled reporters, version/commit stamps and SHA-256 checksums. |
| 7 | Codex stdin hooks ignored | Six lifecycle hooks accept stdin JSON and return an observational empty object. Permission requests never grant or deny approval. Regression passes. |
| 8 | Installer loses configuration | Conservative TOML array editing, preserved notifier chains, atomic backups, feature-level idempotence, fresh-directory support, and rejection of malformed Cursor JSON. Install/upgrade/uninstall round trips pass. |
| 9 | Incomplete uninstall | Restore owned Codex notify/hooks, remove owned Cursor/Claude hooks, unregister the app login service, and stop its relay/keeper. Installer tests verify unrelated configuration survives. |
| 10 | Browser identities and false finishes | Shared conversation aliases survive initial URL assignment. Navigation and ambiguous DOM changes produce unknown outcomes; explicit user stops are interrupted. Actual adapter scripts are tested with controlled DOM fixtures. |
| 11 | Guessed context capacity | Use source capacity; otherwise show usage with unknown capacity. No discontinuous 200K-to-1M heuristic. Model regression passes. |
| 12 | Stale/misattributed accounts | Expiry runs independently of successful reports; disconnected host totals are removed. Unattributed Codex readings say account unverified. State and reporter checks pass. |
| 13 | Attempted edits presented as a diff | Count matched successful Edit/Write results and actual user turns. Label the result as estimated editing activity. Unconfirmed tool calls are excluded by regression. |
| 14 | Timed holds become indefinite | Persist and validate deadlines; expired holds stay off after restart. Manual system-only holds have the correct reason. Restart-state regression passes. |
| 15 | Review opens an arbitrary terminal | Recorded cmux pane, browser conversation, or workspace metadata drives source navigation. Fallback labels describe opening an app/workspace without claiming exact conversation targeting. |
| 16 | Ambiguous outcomes and actions | Separate success/error/interrupted/unknown labels and colors; clean task-notification text. Clear event history preserves sessions. State regressions pass. |
| 17 | Clipboard actor warning | Explicit nonisolated immutable-payload processing boundary. Swift tests and release compilation use warnings as errors. |
| 18 | Layout churn and unbounded reporter work | Compositor-driven pulses, unchanged-snapshot suppression, incremental Codex reads and cache eviction. A five-minute synthetic run completed 600 snapshots with no monotonic RSS growth; this does not establish overnight behavior. |
| 19 | Author-specific installation path | App-bundled reporters/scripts, relocatable support lookup, application-support configuration, visible reporter health. Source checkout remains an optional fallback. |
| 20 | Live remote reporters never update | Content checksums, verified upload, atomic script replacement, deliberate reporter restart and reported protocol/version. Shell entry points preserve existing LaunchAgent/SSH invocation compatibility. |
| 21 | Watch transport/identity/scoping | Opt-in read-only TLS relay, random pairing token, pinned certificate, keychain storage, stable IDs, foreground polling, and scoped activity labels. Watch simulator connected to the real relay; auth/route rejection is covered by Python tests. Physical Watch deployment remains unverified. |
| 22 | Music arbitration/artwork | Prefer a playing native source; cancel/invalidate artwork on every identity change, including no-art tracks; focus the originating browser tab. Native arbitration regression passes. |
| 23 | Edge bounds/accessibility | Clamp the expanded panel to the display's visible frame; consume preference changes on the main queue. Add keyboard actions, key-window capability and accessibility labels. Geometry tests pass; physical external-display and full VoiceOver review remain manual. |
| 24 | Broad extension trust and hidden failures | Extension pairing key plus strict Origin/client validation; websites remain rejected even with the key. Listener/reporter state, errors and versions are visible. Live HTTP probes verified 403/200 behavior. |
| 25 | Documentation/build/release drift | Updated installation, remote, browser, Watch and outcome documentation; universal Mac packaging; Safari/Watch build checks in CI. |

## Validation

- 194 Swift tests, 51 Python tests, and 14 browser checks passed locally.
- Universal arm64/x86_64 Mac build targets macOS 14; Safari wrapper and Watch
  simulator Release builds passed. The Xcode 27 SDK emits an Intel architecture
  deprecation notice; Swift source compilation passes with warnings as errors.
- Five-minute synthetic stress test: 600 snapshots, 12 retained sessions,
  approximately 30–84 MB RSS; final sample about 41 MB. Most collapsed CPU
  samples were below 1% of one core. This is a short check, not a controlled
  benchmark against the previous release or a multi-day leak result.
- The simulator exercised the Watch's actual pinned TLS client against the
  Python relay. It does not establish physical-device installation, network
  permissions, or watchOS background delivery. Polling is foreground-only.

## Upgrade notes and remaining manual checks

Update/reload browser bridges and enter the key from Mac Settings → Connections.
The previous blanket extension trust is intentionally removed. Restart agent
sessions after hook installation and review optional Codex hooks with `/hooks`.
Run `agent-hud-bootstrap HOST` for each configured remote reporter after updates.

OS notification and Accessibility permissions remain the user's choice; the app
now reports their state. Ad-hoc signing cannot replace Developer ID notarization
or Apple Watch development signing. Release Watch binaries are for the simulator.

An overnight workload, a physical Watch, live Cursor/site DOM behavior, a full
VoiceOver pass, and physical external-display/clamshell changes still need human
validation. Browser DOM changes can require future adapter updates. Editing
counts remain estimates and unavailable account/context metadata stays explicit.
