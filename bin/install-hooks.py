#!/usr/bin/env python3
"""Idempotently add Agent HUD forwarder hooks to Claude Code or Cursor.

Usage: install-hooks.py /abs/path/to/agent-hud-send [settings.json path]
       install-hooks.py --cursor [hooks.json path]

Cursor (1.7+) keeps its own hooks.json — same idea, different shape and
location (~/.cursor/hooks.json). --cursor wires the events the HUD cares
about: prompt submitted, session started/ended, and the agent loop stopping
(which reports completed / aborted / error, so outcomes come for free).

Appends hook entries for UserPromptSubmit, Notification and Stop unless an
agent-hud-send hook is already present for that event, backing the settings
file up first when anything will actually change. Existing hooks are left
untouched, and a run with nothing to add doesn't write the file at all.
"""
import json
import os
import shlex
import shutil
import sys
import time


CURSOR_EVENTS = ["beforeSubmitPrompt", "sessionStart", "sessionEnd", "stop"]


def install_cursor(argv):
    """Add our forwarder to Cursor's hooks.json without touching other hooks."""
    forwarder = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent-hud-cursor")
    path = argv[0] if argv else os.path.expanduser("~/.cursor/hooks.json")

    cfg = {}
    if os.path.exists(path):
        with open(path) as f:
            try:
                cfg = json.load(f)
            except ValueError:
                cfg = {}
        backup = "%s.bak-agenthud-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("backup: %s" % backup, file=sys.stderr)

    cfg.setdefault("version", 1)
    hooks = cfg.setdefault("hooks", {})
    added = []
    for ev in CURSOR_EVENTS:
        entries = hooks.setdefault(ev, [])
        if any("agent-hud-cursor" in (e.get("command") or "") for e in entries):
            continue
        entries.append({"command": forwarder, "timeout": 5})
        added.append(ev)

    if not added:
        print("cursor hooks: none (already installed)", file=sys.stderr)
        return

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp-agenthud"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    print("cursor hooks added: %s" % ", ".join(added), file=sys.stderr)
    print("note: reload the Cursor window to pick these up", file=sys.stderr)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--cursor":
        install_cursor(sys.argv[2:])
        return
    # Hook commands run through a shell — a repo path with a space in it
    # must not word-split. quote() leaves the common no-space path as-is.
    send = shlex.quote(
        os.path.abspath(sys.argv[1])
        if len(sys.argv) > 1
        else os.path.expanduser("~/agent-hud/bin/agent-hud-send")
    )
    path = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.expanduser("~/.claude/settings.json")
    )

    settings = {}
    if os.path.exists(path):
        with open(path) as f:
            settings = json.load(f)

    hooks = settings.setdefault("hooks", {})
    added = []
    for ev in ("UserPromptSubmit", "Notification", "Stop"):
        groups = hooks.setdefault(ev, [])
        existing = [h.get("command", "") for g in groups for h in g.get("hooks", [])]
        if any("agent-hud-send" in c for c in existing):
            continue
        groups.append({"hooks": [{"type": "command", "command": send, "timeout": 10}]})
        added.append(ev)

    # Touch the file only when something is actually being added: bootstrap
    # re-runs this on every remote reboot, and a no-op rewrite both accreted
    # .bak-agenthud-* files and reflowed the user's own formatting for
    # nothing. Backing up first, then writing, keeps that order for runs that
    # do change something.
    if added:
        if os.path.exists(path):
            backup = "%s.bak-agenthud-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
            shutil.copy2(path, backup)
            print("backup: %s" % backup, file=sys.stderr)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # Write-and-rename: a run killed midway (closing terminal, dropped
        # ssh) must never leave a truncated settings.json behind. The temp
        # file shares the directory so the rename is atomic, and inherits the
        # old file's mode so permissions survive the swap.
        tmp = "%s.agenthud-tmp" % path
        with open(tmp, "w") as f:
            json.dump(settings, f, indent=2)
            f.write("\n")
        if os.path.exists(path):
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    print(
        "hooks added: %s" % (", ".join(added) if added else "none (already installed)"),
        file=sys.stderr,
    )
    print("note: already-running Claude sessions pick this up after a restart", file=sys.stderr)


if __name__ == "__main__":
    main()
