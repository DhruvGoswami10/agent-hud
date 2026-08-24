<pre>
 █████╗  ██████╗ ███████╗███╗   ██╗████████╗    ██╗  ██╗██╗   ██╗██████╗
██╔══██╗██╔════╝ ██╔════╝████╗  ██║╚══██╔══╝    ██║  ██║██║   ██║██╔══██╗
███████║██║  ███╗█████╗  ██╔██╗ ██║   ██║       ███████║██║   ██║██║  ██║
██╔══██║██║   ██║██╔══╝  ██║╚██╗██║   ██║       ██╔══██║██║   ██║██║  ██║
██║  ██║╚██████╔╝███████╗██║ ╚████║   ██║       ██║  ██║╚██████╔╝██████╔╝
╚═╝  ╚═╝ ╚═════╝ ╚══════╝╚═╝  ╚═══╝   ╚═╝       ╚═╝  ╚═╝ ╚═════╝ ╚═════╝

              your agents · every machine · one glance

──────────────────────────────────────────────────────────────────────────

  ⚡  Claude Code everywhere — this Mac, your SSH boxes, browser tabs
  ●  live sessions with real names, context %, model & effort
  ▎▎  the side bars — pulsing blue means working, orange needs you
  ✓  truthful endings: finished, interrupted, or errored — never a lie
  ☕  keep-awake that knows when agents are working
  ♪  your music in the notch — Spotify, Apple Music, even YouTube

──────────────────────────────────────────────────────────────────────────
</pre>

# Agent HUD

A notch-style HUD for AI agents. A black panel hugs the MacBook notch (or floats
top-center on external displays) and slides out when:

- a **Claude Code agent finishes a turn** (green, shows the final reply snippet)
- an agent **needs approval / input** (orange, sticky, counts pending items)
- a **prompt starts running** (blue, brief)
- you **copy text or an image** (clipboard preview)

Events come from Claude Code **hooks** (`UserPromptSubmit`, `Notification`,
`Stop`) on any machine — local, or a VM you SSH into. Remote machines POST to
`127.0.0.1:48085`, which an SSH reverse tunnel carries back to the Mac, so the
same forwarder script works everywhere.

```
Claude Code hook (Mac or VM)
  └─ bin/agent-hud-send  ──POST /event──▶  AgentHUD.app listener :48085
                                             ├─ notch slide-out + feed
                                             ├─ menu bar state icon
                                             ├─ macOS notification + sound
                                             └─ clipboard previews (local watcher)
```

## Build & run (Mac)

```sh
make run          # swift build, bundle dist/AgentHUD.app, launch
make hooks        # add forwarder hooks to ~/.claude/settings.json (backs up first)
make test         # Swift + Python test suites
```

First run: macOS will ask once for **notification** permission, and the first
clipboard read triggers the **pasteboard privacy** prompt — choose Always Allow.

Already-running Claude Code sessions snapshot their hooks at startup; they start
reporting after a restart. New sessions report immediately.

## Interactions

- Event arrives → panel slides out, auto-collapses (approval events stay longer
  and leave an orange count on the collapsed pill).
- Hover the notch → full panel: sessions by state, recent events, clipboard
  history (click a chip to copy it back).
- Menu bar sparkle icon = aggregate state (orange approval / blue running /
  green recent done). Menu has toggles + "Send Test Event".

## Quitting and starting again

`Quit Agent HUD` stops the app. Nothing breaks while it's off — the hooks still
fire, they just fail instantly (a refused loopback port costs ~30ms) and no
events are recorded until it's back.

To start it again, any of:

```sh
open ~/agent-hud/dist/AgentHUD.app    # or Spotlight: "AgentHUD"
make run                              # rebuilds first
```

Or turn on **Open at Login** (menu bar, or Settings › General) and it comes back
by itself after every restart.

## Settings

`Settings…` in the menu bar (or ⌘,) opens four tabs:

- **Timing** — how long each slide-out stays (needs-you, done, clipboard,
  music), whether a click dismisses one, the ⌥⎋ dismiss-from-anywhere hot key,
  and how forgiving the hover is before the panel retracts.
- **Appearance** — the resting indicator (the notch is invisible when idle by
  default; turn this on for a dim mark that says it's alive), side bars,
  alerts, animation.
- **Keep Awake** — timed holds (15m / 30m / 1h / 2h / indefinitely) with a
  live countdown, whether a manual hold keeps the screen lit or only stops the
  machine sleeping, and the automatic hold while agents work.
- **Updates** — the running version, a check against the newest release, and
  a switch to stop checking.

A slide-out goes away on the first click, or with **⌥⎋** from any app.

## Updating

```sh
bin/agent-hud-update     # or: make update
```

Fast-forwards this clone, rebuilds, relaunches. It refuses rather than guesses:
uncommitted work is never discarded and diverged history is never merged for
you. The app only ever *tells* you a release exists — updating is a command you
run, because the hooks, the reporter and the tunnel keeper all live in this
repo, so the clone is the update unit, not the `.app`.

## Remote machines

See [docs/remote-setup.md](docs/remote-setup.md). Short version: copy `bin/` to
the box, run `install-hooks.py` there, and let `~/.ssh/config`'s
`RemoteForward 48085 127.0.0.1:48085` carry events home while you're SSH'd in.

## Event API

`POST http://127.0.0.1:48085/event` — anything can send one, not just Claude:

```json
{"event": "attention|running|done|info", "host": "box", "project": "repo",
 "session_id": "abc", "message": "text", "image_b64": "...", "image_path": "..."}
```

`GET /health` → `{"ok":true,"received":N}`.

The API is deliberately generic — Agent HUD is a notification surface for any
long-running thing, not just AI. A build, a deploy, a big download:

```sh
make build && curl -s -X POST http://127.0.0.1:48085/event \
  -H 'Content-Type: application/json' \
  -d '{"event":"done","host":"Mac","project":"kernel","message":"build finished"}'
```

## Uninstall

```sh
make uninstall
```

Stops the app, removes both LaunchAgents, strips only the agent-hud hook
entries from `~/.claude/settings.json` (with a timestamped backup), and clears
`~/.cache/agent-hud`. Your sessions, transcripts, and the repo itself are
untouched. Remote boxes: `pkill -f '[a]gent-hud-registry'` on each.

## Your machines

Remote boxes live in `~/agent-hud/hosts.conf` (one IP/host or pattern per
line) and display aliases in `~/agent-hud/hosts.json` — both gitignored, so
your infrastructure never lands in the repo.

## License & contributing

MIT — see [LICENSE](LICENSE). PRs welcome: read [CONTRIBUTING.md](CONTRIBUTING.md)
first (short, but the design ground rules matter).

## Roadmap

- Approve/deny from the notch (tmux `send-keys` into the session)
- Windows tray client speaking the same protocol
- Other agents (Codex CLI, Gemini CLI, …) — anything that can `curl` works today
- Persistent tunnel via LaunchAgent + autossh instead of piggybacking SSH sessions
