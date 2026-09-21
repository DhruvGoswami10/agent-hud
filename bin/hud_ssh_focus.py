"""Link an SSH connection to its originating Mac terminal. No remote commands.

Capture runs from the existing SSH LocalCommand / bootstrap integration.
Navigation reads the saved link and verifies that the same SSH process and
connection are still alive. A reconnect can reuse the same recorded cmux pane
only after validating its replacement SSH connection. The HUD selects cmux's
pane through its scripting interface; its control socket stays restricted.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from hud_focus import capture_focus, ssh_connection, valid_uuid

CMUX = "/Applications/cmux.app/Contents/Resources/bin/cmux"
MAX_LINKS = 256


def output(argv):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=3, env=dict(os.environ, LC_ALL="C"))
        return p.stdout.strip() if p.returncode == 0 and len(p.stdout) <= 2_000_000 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def parse_connections(text):
    pid, command = None, ""
    connections = []
    for line in text.splitlines():
        if line.startswith("p"):
            pid = int(line[1:]) if line[1:].isdigit() else None
            command = ""
        elif line.startswith("c"):
            command = line[1:]
        elif line.startswith("n") and "->" in line and pid and command == "ssh":
            try:
                source, destination = line[1:].split("->")
                client, cport = source.rsplit(":", 1)
                server, sport = destination.rsplit(":", 1)
                connection = ssh_connection("%s %s %s %s" %
                    (client.strip("[]"), cport, server.strip("[]"), sport))
                row = {"pid": pid, "connection": connection}
                if connection and row not in connections:
                    connections.append(row)
            except ValueError:
                pass
    return connections


def connections():
    return parse_connections(output(["/usr/sbin/lsof", "-nP", "-a", "-u", str(os.getuid()),
        "-c", "ssh", "-iTCP", "-sTCP:ESTABLISHED", "-Fpcn"]))


def process_tty(pid):
    tty = output(["/bin/ps", "-p", str(pid), "-o", "tty="])
    return tty if re.fullmatch(r"ttys?\d+", tty) else ""


def process_start(pid):
    return output(["/bin/ps", "-p", str(pid), "-o", "lstart="])


def dedicated_connection(pid):
    # A ControlMaster can carry several unrelated terminal tabs on one TCP
    # connection. A Unix control/agent socket makes attribution ambiguous:
    # be conservative, including when a master gains clients after capture.
    try:
        p = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-U", "-Ff"],
                           capture_output=True, text=True, timeout=3)
        return p.returncode in (0, 1) and not p.stdout.strip() and not p.stderr.strip()
    except (OSError, subprocess.SubprocessError):
        return False


def cmux_terminals(tree):
    targets = {}
    for window in tree.get("windows", []):
        for workspace in window.get("workspaces", []):
            wid = valid_uuid(workspace.get("id"))
            for pane in workspace.get("panes", []):
                for surface in pane.get("surfaces", []):
                    tty = surface.get("tty", "")
                    sid = valid_uuid(surface.get("id"))
                    if wid and sid and re.fullmatch(r"ttys?\d+", tty):
                        targets.setdefault(tty, []).append({"application": "com.cmuxterm.app",
                                                            "workspace": wid, "surface": sid})
    # Never guess if a terminal was adopted into more than one surface.
    return {tty: matches[0] for tty, matches in targets.items() if len(matches) == 1}


def link_dir():
    return Path(os.environ.get("AGENT_HUD_SSH_LINK_DIR",
        str(Path.home() / "Library/Application Support/AgentHUD/ssh-links")))


def link_path(connection):
    return link_dir() / (hashlib.sha256(connection.encode()).hexdigest() + ".json")


def save_link(row, tty, focus, started):
    root = link_dir()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".link-", dir=str(root))
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(dict(row, tty=tty, focus=focus, started=started), f)
        os.replace(temp, link_path(row["connection"]))
        paths = sorted(root.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in paths[MAX_LINKS:]:
            path.unlink()
    finally:
        try:
            os.unlink(temp)
        except OSError:
            pass


def capture_sources(all_terminals=False):
    if sys.platform != "darwin":
        return 0
    try:
        own_tty = process_tty(os.getpid())
        own_focus = capture_focus(tty="/dev/" + own_tty if own_tty else "")
        own_focus.pop("ssh_connection", None)
        tree = {}
        if all_terminals or (not own_focus.get("workspace") and
                own_focus.get("application", "") in ("", "com.cmuxterm.app", "com.mitchellh.ghostty")):
            tree = json.loads(output([CMUX, "--json", "--id-format", "both", "tree", "--all"]) or "{}")
        targets = cmux_terminals(tree)
        count = 0
        for row in connections():
            tty = process_tty(row["pid"])
            if not tty or (not all_terminals and tty != own_tty):
                continue
            focus = targets.get(tty) or (own_focus if tty == own_tty else {})
            started = process_start(row["pid"])
            if focus and started and dedicated_connection(row["pid"]):
                save_link(row, tty, focus, started)
                count += 1
        return count
    except (OSError, ValueError, TypeError, AttributeError):
        return 0  # navigation capture must never break SSH or bootstrap


def read_link(connection):
    try:
        path = link_path(connection)
        if path.stat().st_size > 8192:
            raise ValueError("oversized link")
        link = json.loads(path.read_text())
        if (isinstance(link, dict) and link.get("connection") == connection
                and isinstance(link.get("focus"), dict)):
            return link
    except (OSError, ValueError):
        pass
    return {}


def matches_process(row, link):
    return (link.get("pid") == row["pid"] and link.get("connection") == row["connection"]
            and bool(link.get("started")) and link["started"] == process_start(row["pid"])
            and bool(link.get("tty")) and link["tty"] == process_tty(row["pid"]))


def cmux_destination(link):
    focus = link.get("focus", {})
    workspace, surface = valid_uuid(focus.get("workspace")), valid_uuid(focus.get("surface"))
    if focus.get("application") == "com.cmuxterm.app" and workspace and surface:
        return {"application": "com.cmuxterm.app", "workspace": workspace, "surface": surface}
    return None


def resolve_reconnected(connection, live):
    # A background Claude can keep reporting the connection it started under.
    # Preserve its original pane identity across reconnects, never infer a pane
    # merely because it connects to the same host. Both links must name the
    # exact same workspace AND surface, and the new process must still match.
    wanted = cmux_destination(read_link(connection))
    if not wanted:
        return {"error": "This session's SSH connection is no longer open on this Mac."}
    destination = connection.split()[2:]
    candidates = []
    for row in live:
        if row["connection"].split()[2:] != destination:
            continue
        link = read_link(row["connection"])
        if link.get("pid") == row["pid"] and cmux_destination(link) == wanted:
            candidates.append((row, link))
            if len(candidates) > 1:
                return {"error": "More than one SSH connection is using this cmux pane. Agent HUD cannot choose between them."}
    if len(candidates) == 1:
        row, link = candidates[0]
        if matches_process(row, link) and dedicated_connection(row["pid"]):
            return {"focus": wanted, "reconnected": True}
    return {"error": "This session's SSH connection has closed. Reconnect in its original cmux pane, then try again."}


def resolve(connection):
    connection = ssh_connection(connection)
    if not connection:
        return {"error": "This session did not report a valid SSH connection."}
    live = connections()
    candidates = [row for row in live if row["connection"] == connection]
    if not candidates:
        return resolve_reconnected(connection, live)
    if len(candidates) != 1:
        return {"error": "This session's SSH connection could not be identified uniquely."}
    row = candidates[0]
    if not dedicated_connection(row["pid"]):
        return {"error": "This SSH connection is shared or forwarded, so its terminal tab cannot be identified safely."}
    link = read_link(connection)
    if matches_process(row, link):
        return {"focus": link["focus"]}
    return {"error": "This SSH tab is not linked yet. Connect with the Agent HUD SSH hook to link this terminal."}


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] in ("--capture", "--capture-all"):
        print(json.dumps({"linked": capture_sources(all_terminals=sys.argv[1] == "--capture-all")}))
    elif len(sys.argv) == 3 and sys.argv[1] == "--resolve":
        print(json.dumps(resolve(sys.argv[2])))
    else:
        raise SystemExit("Usage: hud_ssh_focus.py --capture | --capture-all | --resolve 'SSH_CONNECTION'")
