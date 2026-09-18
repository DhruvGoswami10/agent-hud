"""Capture source locations, never commands. Python 3.9+, no dependencies."""
import hashlib
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
    return {k: v for k, v in focus.items() if v}


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
