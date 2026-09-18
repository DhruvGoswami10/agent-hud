"""Capture source locations, never commands. Python 3.9+, no dependencies."""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit

MAX_AGE = 24 * 3600
MAX_RECORDS = 256
APPLICATIONS = {
    "WarpTerminal": "dev.warp.Warp-Stable",
    "iTerm.app": "com.googlecode.iterm2",
    "Apple_Terminal": "com.apple.Terminal",
    "ghostty": "com.mitchellh.ghostty",
    "WezTerm": "com.github.wez.wezterm",
    "vscode": "com.microsoft.VSCode",
}
LOCATION_ENV_KEYS = ("TERM_PROGRAM", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "WARP_FOCUS_URL",
                     "ITERM_SESSION_ID", "SSH_CONNECTION", "TMUX", "STY")


def ssh_connection(value):
    """A connection identity, never a hostname or a command to execute."""
    try:
        parts = value.split()
        if len(parts) != 4 or len(value) > 160:
            return ""
        client, cport, server, sport = parts
        if not (cport.isdecimal() and sport.isdecimal() and 0 < int(cport) < 65536 and 0 < int(sport) < 65536):
            return ""
        return "%s %d %s %d" % (ipaddress.ip_address(client), int(cport), ipaddress.ip_address(server), int(sport))
    except (AttributeError, ValueError, TypeError):
        return ""


def valid_uuid(value):
    try:
        return str(uuid.UUID(value)) if isinstance(value, str) and value else ""
    except ValueError:
        return ""


def warp_url(value):
    try:
        u = urlsplit(value)
        if (u.scheme in ("warp", "warppreview", "warposs") and u.netloc == "session"
                and not u.query and not u.fragment and valid_uuid(u.path[1:])):
            return value
    except (ValueError, TypeError):
        pass
    return ""


def terminal_tty():
    for fd in (0, 1, 2):
        try:
            name = os.ttyname(fd)
            if name != "/dev/tty":
                return name
        except OSError:
            pass
    # Hook stdin/stdout are pipes, but their parent still owns a terminal.
    try:
        name = subprocess.check_output(["ps", "-o", "tty=", "-p", str(os.getppid())],
                                       timeout=0.5, stderr=subprocess.DEVNULL).decode().strip()
        if re.fullmatch(r"(?:ttys?\d+|pts/\d+)", name):
            return "/dev/" + name
    except (OSError, subprocess.SubprocessError):
        pass
    return ""


def capture_focus(env=None, tty=None):
    env = os.environ if env is None else env
    focus = {}
    workspace = valid_uuid(env.get("CMUX_WORKSPACE_ID"))
    warp = warp_url(env.get("WARP_FOCUS_URL", ""))
    if warp and (env.get("TERM_PROGRAM") == "WarpTerminal" or not workspace):
        app = "dev.warp.Warp-Preview" if warp.startswith("warppreview:") else "dev.warp.Warp-Stable"
        focus = {"application": app, "warp_url": warp}
    elif workspace:
        focus = {"application": "com.cmuxterm.app", "workspace": workspace,
                 "surface": valid_uuid(env.get("CMUX_SURFACE_ID"))}
    else:
        app = APPLICATIONS.get(env.get("TERM_PROGRAM", ""), "")
        if app:
            focus["application"] = app
        if app == "com.googlecode.iterm2":
            focus["terminal_id"] = valid_uuid(env.get("ITERM_SESSION_ID", "").split(":")[-1])
        if app in ("com.apple.Terminal", "com.googlecode.iterm2"):
            focus["tty"] = terminal_tty() if tty is None else tty
    # A multiplexer can outlive and switch SSH connections; its inherited
    # SSH_CONNECTION is not proof of the client currently displaying it.
    if not env.get("TMUX") and not env.get("STY"):
        focus["ssh_connection"] = ssh_connection(env.get("SSH_CONNECTION", ""))
    return {k: v for k, v in focus.items() if v}


def process_focus(pid, proc_root=Path("/proc")):
    """Recover an already-running remote Claude's source without restarting it.

    Read only a same-user process. Keep the small location allowlist in memory;
    credentials and unrelated environment values are never returned or stored.
    """
    if not str(pid).isdigit() or int(pid) <= 1:
        return {}
    try:
        root = proc_root / str(pid)
        if root.stat().st_uid != os.getuid() or (root / "comm").read_text().strip() not in ("claude", "node"):
            return {}
        with (root / "environ").open("rb") as f:
            raw = f.read(262145)
        if len(raw) > 262144:
            return {}
        env = {}
        for item in raw.split(b"\0"):
            key, _, value = item.partition(b"=")
            name = key.decode(errors="replace")
            if name in LOCATION_ENV_KEYS:
                env[name] = value.decode(errors="replace")
        return capture_focus(env, tty="")
    except OSError:
        return {}


def session_focus(provider, sid, pid):
    saved = recorded_focus(provider, sid)
    recovered = process_focus(pid)
    if recovered and recovered != saved:
        return remember_focus(provider, sid, recovered)
    return saved or recovered


def focus_dir():
    default = (Path.home() / "Library/Application Support/AgentHUD/session-focus" if sys.platform == "darwin"
               else Path.home() / ".cache/agent-hud/session-focus")
    return Path(os.environ.get("AGENT_HUD_FOCUS_DIR", str(default)))


def record_path(provider, sid):
    digest = hashlib.sha256((provider + "\0" + sid).encode()).hexdigest()
    return focus_dir() / (digest + ".json")


def recorded_focus(provider, sid):
    if not sid:
        return {}
    try:
        path = record_path(provider, sid)
        if time.time() - path.stat().st_mtime > MAX_AGE or path.stat().st_size > 8192:
            return {}
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


def remember_focus(provider, sid, focus):
    """Keep hook locations available to the reporter after an app restart."""
    if not isinstance(sid, str) or not sid or not focus:
        return focus
    merged = recorded_focus(provider, sid)
    # A resumed conversation can move to a different terminal application.
    if focus.get("application") and focus.get("application") != merged.get("application"):
        merged = {}
    if focus.get("ssh_connection") and focus.get("ssh_connection") != merged.get("ssh_connection"):
        for key in ("workspace", "surface", "warp_url", "terminal_id", "tty", "application"):
            merged.pop(key, None)
    if focus.get("workspace") and focus.get("workspace") != merged.get("workspace"):
        merged.pop("surface", None)
    merged.update(focus)
    temp = None
    try:
        root = focus_dir()
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temp = tempfile.mkstemp(prefix=".focus-", dir=str(root))
        with os.fdopen(fd, "w") as f:
            json.dump(merged, f)
        os.replace(temp, record_path(provider, sid))
        paths = sorted(root.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        for i, path in enumerate(paths):
            if i >= MAX_RECORDS or time.time() - path.stat().st_mtime > MAX_AGE:
                path.unlink()
    except (OSError, ValueError):
        pass  # navigation must never stop an agent hook
    finally:
        if temp:
            try:
                os.unlink(temp)
            except OSError:
                pass
    return merged
