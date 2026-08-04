#!/usr/bin/env python3
"""Idempotently add Agent HUD forwarder hooks to a Claude Code settings.json.

Usage: install-hooks.py /abs/path/to/agent-hud-send [settings.json path]

Backs up the existing settings file, then appends hook entries for
UserPromptSubmit, Notification and Stop unless an agent-hud-send hook is
already present for that event. Existing hooks are left untouched.
"""
import json
import os
import shutil
import sys
import time


def main():
    send = (
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
        backup = "%s.bak-agenthud-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("backup: %s" % backup, file=sys.stderr)

    hooks = settings.setdefault("hooks", {})
    added = []
    for ev in ("UserPromptSubmit", "Notification", "Stop"):
        groups = hooks.setdefault(ev, [])
        existing = [h.get("command", "") for g in groups for h in g.get("hooks", [])]
        if any("agent-hud-send" in c for c in existing):
            continue
        groups.append({"hooks": [{"type": "command", "command": send, "timeout": 10}]})
        added.append(ev)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")
    print(
        "hooks added: %s" % (", ".join(added) if added else "none (already installed)"),
        file=sys.stderr,
    )
    print("note: already-running Claude sessions pick this up after a restart", file=sys.stderr)


if __name__ == "__main__":
    main()
