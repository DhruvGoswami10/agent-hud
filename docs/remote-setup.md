# Remote reporters and SSH tunnels

The Mac’s event/control API remains loopback-only. Use a reverse SSH tunnel;
do not expose port 48085 on a public or local-network interface.

## Configure hosts

Put one SSH host alias/IP per line in `hosts.conf` in the checkout, or in
`~/Library/Application Support/AgentHUD/`. Comments start with `#`. Bootstrap
also accepts shell patterns in this file; the persistent keeper uses explicit
host entries only. `AGENT_HUD_ROOT` selects a different configuration root.
These files are private and gitignored.

## Install or update a reporter

From the Mac checkout (or the downloaded app’s `Contents/Resources/bin`):

```sh
bin/agent-hud-bootstrap my-dev-box
```

The host must be configured and reachable through batch-mode SSH. Python 3.9+
and `pgrep`/`pkill` are required remotely. Bootstrap compares content checksums,
verifies the upload, installs scripts atomically, preserves existing Claude hooks,
and restarts same-user HUD reporters. Agent sessions are not restarted. Repeat
this command after each HUD release; a healthy old reporter is still updated.
Codex rollouts are included automatically. To install its optional hooks remotely:

```sh
ssh my-dev-box 'python3 ~/agent-hud/bin/install-hooks.py --codex --with-hooks'
```

Restart existing agent sessions and review Codex hooks with `/hooks` as needed.

## Carry reports home

In the Mac’s `~/.ssh/config`:

```sshconfig
Host my-dev-box
    RemoteForward 48085 127.0.0.1:48085
```

An interactive connection then carries reports to the Mac. For persistent
connections, run `bin/agent-hud-tunnels` through your LaunchAgent. It probes the
forward, creates a tunnel only when needed, and stops only children it owns.
It uses SSH server-alive checks to recover after network changes. Existing
interactive tunnels can coexist; only one connection binds the remote port.

## Check health

```sh
ssh my-dev-box 'curl -fsS --max-time 3 http://127.0.0.1:48085/health'
```

Mac Settings → Connections lists reporter versions; `/debug` includes heartbeat
ages. Debug output contains private session information. Reporter startup errors
are retained in `~/agent-hud/reporter.log` on the remote host. If a host disappears,
its cards become unavailable and its aggregate usage is removed after the grace
period; silence is not reported as successful completion.

## Remove remote integration

Run these as separate commands on that host:

```sh
pkill -u "$(id -u)" -f '[a]gent-hud-registry'
python3 ~/agent-hud/bin/install-hooks.py --uninstall
```

The uninstaller keeps transcripts, unrelated hooks, and backups.
