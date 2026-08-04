# Remote machines (SSH'd VMs → Mac notch)

List your boxes in `~/agent-hud/hosts.conf` (one IP/host or shell pattern per
line; the file is gitignored). The tunnel keeper and auto-bootstrap read it.
For a new box:

## 1. Install the forwarder on the box

```sh
ssh <box> 'mkdir -p ~/agent-hud/bin'
scp bin/agent-hud-send bin/agent-hud-payload.py bin/install-hooks.py <box>:agent-hud/bin/
ssh <box> 'chmod +x ~/agent-hud/bin/* && python3 ~/agent-hud/bin/install-hooks.py ~/agent-hud/bin/agent-hud-send'
```

The installer backs up `~/.claude/settings.json` and appends hooks additively.
Claude Code sessions already running on the box pick the hooks up after a
restart; new sessions report immediately.

## 2. Carry the events home

`~/.ssh/config` on the Mac:

```
Host <box-ip-or-alias>
    RemoteForward 48085 127.0.0.1:48085
```

Any interactive SSH session you have open to the box now doubles as the event
tunnel. Notes:

- Only one session can hold the remote port; extra sessions print
  `Warning: remote port forwarding failed for listen port 48085` — benign.
- If you close every SSH session to the box, events stop until you reconnect
  (hooks fail silently; agents are never blocked). For an always-on tunnel run:
  `ssh -N -R 48085:127.0.0.1:48085 <box>` under autossh/launchd.
- No SSH at all? Point the box's hooks straight at the Mac if routable:
  `AGENT_HUD_URL=http://<mac-ip>:48085` in the environment Claude runs in
  (requires changing the app to bind non-loopback — not enabled by default).

## 3. Live session registry reporter

Hooks only fire on turn boundaries; for the live SESSIONS list (names + status,
no session restart needed) each box also runs a reporter that streams
`~/.claude/sessions` snapshots to `POST /sessions` every 5s:

```sh
ssh <box> 'nohup ./agent-hud/bin/agent-hud-registry </dev/null >/dev/null 2>&1 &'
```

Gotchas learned the hard way: keep `</dev/null` (otherwise the process pins the
SSH session open and dies with it), and never `pkill -f` it in a command line
that also contains the script path — the pattern matches the invoking shell and
kills the connection. Use `pkill -f "[a]gent-hud-registry"` in its own ssh call.

## 4. Test

```sh
ssh <box> 'printf %s "{\"hook_event_name\":\"Notification\",\"session_id\":\"t\",\"cwd\":\"$HOME\",\"message\":\"tunnel test\"}" | ~/agent-hud/bin/agent-hud-send'
curl -s http://127.0.0.1:48085/health   # received count should bump
```
