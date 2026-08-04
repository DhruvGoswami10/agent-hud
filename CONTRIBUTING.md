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
```

Test events without an agent:

```sh
curl -X POST -H 'Content-Type: application/json' \
  -d '{"event":"done","host":"test","project":"demo","message":"hello"}' \
  http://127.0.0.1:48085/event
```
