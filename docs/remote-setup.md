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

## Return to the original SSH pane

**Go to session** can return from a remote Claude session to its originating
cmux pane. SSH does not normally carry the Mac's pane IDs. Agent HUD records
the source terminal on the Mac and matches the full live SSH connection
(client address and port, server address and port) reported by the remote
agent. It never runs a command in that terminal.

If your SSH configuration already runs `agent-hud-bootstrap` as a LocalCommand,
updating the checkout is enough for new connections. Otherwise, add it for
the configured host, using the absolute path to your checkout or app's script:

```sshconfig
Host my-dev-box
    PermitLocalCommand yes
    LocalCommand /absolute/path/to/agent-hud/bin/agent-hud-bootstrap %h >/dev/null 2>&1 &
```

The bootstrap argument (`%h` above) must match an entry in `hosts.conf`. Keep
any existing LocalCommand tasks when adding this integration. The background
hook captures the source terminal even when the remote reporter is current.
cmux and Warp can provide exact pane links; Terminal and iTerm2 use the local
TTY. Other supported terminals may provide only an app fallback.

For SSH tabs already open in cmux before this update, run this once from a
local cmux terminal:

```sh
python3 bin/hud_ssh_focus.py --capture-all
```

The updated reporter can recover an existing Claude process's SSH identity on
Linux; the Claude session does not need to restart. cmux navigation uses its
native scripting interface to select the existing workspace and terminal.
macOS asks for **Agent HUD → cmux** Automation access when first used. This
does not require Accessibility or changes to cmux's restricted control socket.
The initial capture runs within an authorized cmux terminal. Navigation URLs
used in 0.3.1 could switch away from cmux's full-screen desktop on a second
display; 0.3.2 avoids that URL-opening path.

Navigation requires that the original SSH connection remain open. Shared
ControlMaster connections, Unix-socket forwarding (including agent forwarding),
and sessions inside tmux/screen are not attributed automatically because they
can make the source pane ambiguous. Proxies or NAT that change the reported
connection addresses can also prevent a match. A host name or remote path alone
is never used to guess a terminal tab.

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
