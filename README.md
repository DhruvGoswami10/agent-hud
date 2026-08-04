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
