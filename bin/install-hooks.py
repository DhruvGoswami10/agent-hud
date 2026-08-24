#!/usr/bin/env python3
"""Idempotently add Agent HUD forwarder hooks to a Claude Code settings.json.

Usage: install-hooks.py /abs/path/to/agent-hud-send [settings.json path]

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


def main():
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
