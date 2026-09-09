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


CODEX_EVENTS = ["SessionStart", "UserPromptSubmit", "Stop", "PermissionRequest"]


def install_codex(argv):
    """Wire Agent HUD into Codex through `notify`, and optionally hooks.

    Codex has two integration points and only one of them is dependable here.
    Hooks are richer — they carry running and attention, not just turn-end —
    but they are off unless the session is launched with `--enable hooks`,
    they need a trust grant, and inside cmux they are overridden on the
    command line anyway. `notify` needs no flags, no trust, and cmux leaves it
    alone. It holds a single program, so whatever was there is saved and
    chained rather than replaced.

    Pass --with-hooks to add the hook tables as well, for sessions you launch
    yourself with `codex --enable hooks`.
    """
    with_hooks = "--with-hooks" in argv
    argv = [a for a in argv if a != "--with-hooks"]
    here = os.path.dirname(os.path.abspath(__file__))
    forwarder = os.path.join(here, "agent-hud-codex")
    path = argv[0] if argv else os.path.expanduser("~/.codex/config.toml")
    chain = os.path.expanduser("~/.codex/agent-hud-chain.json")

    lines = []
    if os.path.exists(path):
        with open(path) as f:
            lines = f.read().split("\n")
        backup = "%s.bak-agenthud-%s" % (path, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(path, backup)
        print("backup: %s" % backup, file=sys.stderr)

    # --- notify: take the slot, remember who had it -----------------------
    done = []
    notify_line = next((i for i, l in enumerate(lines)
                        if l.strip().startswith("notify") and "=" in l), None)
    already = any("agent-hud-codex" in l for l in lines)
    if already:
        print("codex: already installed", file=sys.stderr)
        return

    if notify_line is not None:
        raw = lines[notify_line].split("=", 1)[1].strip()
        try:
            # TOML arrays of strings are close enough to JSON for this.
            previous = json.loads(raw)
        except Exception:
            previous = []
        with open(chain, "w") as f:
            json.dump(previous, f)
        if previous:
            print("chained behind: %s" % previous[0], file=sys.stderr)
        lines[notify_line] = 'notify = ["%s"]' % forwarder
        done.append("notify (chained)")
    else:
        with open(chain, "w") as f:
            json.dump([], f)
        lines.insert(0, 'notify = ["%s"]' % forwarder)
        done.append("notify")

    # --- hooks: opt-in, appended as their own tables at the end -----------
    if with_hooks:
        hook_toml = ["", "# Added by Agent HUD — remove this block to uninstall."]
        for ev in CODEX_EVENTS:
            hook_toml += ["[[hooks.%s]]" % ev,
                          "[[hooks.%s.hooks]]" % ev,
                          'type = "command"',
                          'command = "%s"' % forwarder,
                          "timeout = 5000",
                          ""]
        lines += hook_toml
        done.append("hooks: " + ", ".join(CODEX_EVENTS))

    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp-agenthud"
    with open(tmp, "w") as f:
        f.write("\n".join(lines))
    os.replace(tmp, path)
    print("codex wired: %s" % " · ".join(done), file=sys.stderr)
    print("note: restart the Codex session to pick these up", file=sys.stderr)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--cursor":
        install_cursor(sys.argv[2:])
        return
    if len(sys.argv) > 1 and sys.argv[1] == "--codex":
        install_codex(sys.argv[2:])
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
