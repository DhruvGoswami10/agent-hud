# Contributing

PRs and issues welcome. Ground rules:

- **Identity is sacred**: the collapsed notch states — side indicator bars and
  the bottom glow line — stay. Redesigns build around them.
- **It's a peripheral, not a control center**: the HUD shows and notifies; it
  doesn't grow workflows. (Music controls are the one grandfathered exception.)
- Keep the event protocol dumb: anything that can `curl` JSON to
  `127.0.0.1:48085/event` is a valid source. New agent integrations should be
  small adapter scripts, not app changes.
- Swift code: `make build` must pass with no warnings on current macOS.
- Python scripts in `bin/` must stay dependency-free (stdlib only, python3.9+).

## Dev loop

```sh
make run        # build + relaunch the app
make hooks      # install Claude Code hooks locally
make test       # Swift unit tests + Python script tests
```

## Tests

`make test` runs both halves and takes a few seconds:

- `app/Tests/AgentHUDTests` — hover gating, clipboard/music de-duplication,
  alerting policy, collapsed geometry, HTTP parsing, event parsing.
- `tests/test_scripts.py` — runs `bin/agent-hud-payload.py` and
  `bin/agent-hud-registry` as subprocesses against a fake `~/.claude` tree.

Most tests here exist because something misbehaved in real use, and the
comment above each one says which failure it protects against. When you fix a
bug, add the test that would have caught it — and confirm it *fails* against
the old code before you call it done. Behaviour worth guarding:

- The idle "waiting for your input" ping must never become an alert.
- Re-asserted pasteboard content and re-reported tracks must not re-announce.
- Crossing the notch on the way to another display must not open the panel.
- The collapsed HUD must be exactly the notch when idle.

Test events without an agent:

```sh
curl -X POST -H 'Content-Type: application/json' \
  -d '{"event":"done","host":"test","project":"demo","message":"hello"}' \
  http://127.0.0.1:48085/event
```
