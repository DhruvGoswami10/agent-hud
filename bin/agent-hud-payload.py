#!/usr/bin/env python3
"""Read a Claude Code hook JSON payload on stdin; print an Agent HUD event JSON.

Prints nothing for hook events the HUD doesn't care about. Must never raise.
"""
import getpass
import json
import os
import re
import socket
import sys

try:
    _user = getpass.getuser()
except Exception:
    _user = os.environ.get("USER", "")
AUTO_NAME = re.compile("^" + re.escape(re.sub(r"[^a-zA-Z0-9]+", "-", _user)) + r"-[0-9a-f]{2}$")


def scan_transcript(path, full):
    """Return (last assistant text, last custom title, outcome) from a transcript JSONL."""
    last, title, outcome = "", "", ""
    if not path:
        return last, title, outcome
    try:
        with open(path, "rb") as f:
            if not full:
                size = os.fstat(f.fileno()).st_size
                f.seek(max(0, size - 262144))
            for raw in f:
                if b"[Request interrupted by user" in raw:
                    outcome = "interrupted"
                    continue
                if b'"isApiErrorMessage":true' in raw:
                    outcome = "error"
                    continue
                if b"assistant" not in raw and b"custom-title" not in raw:
                    continue
                try:
                    j = json.loads(raw)
                except Exception:
                    continue
                if j.get("type") == "custom-title" and j.get("customTitle"):
                    title = j["customTitle"]
                elif j.get("type") == "assistant":
                    content = (j.get("message") or {}).get("content")
                    if isinstance(content, list):
                        text = " ".join(
                            part.get("text", "")
                            for part in content
                            if isinstance(part, dict) and part.get("type") == "text"
                        ).strip()
                        if text:
                            last = text
                            outcome = "finished"
    except Exception:
        pass
    return " ".join(last.split()), title, outcome


def registry_name(session_id):
    """The session's name in Claude Code's live registry (may be auto-generated)."""
    if not session_id:
        return ""
    d = os.path.expanduser("~/.claude/sessions")
    best, best_t = "", -1
    try:
        files = os.listdir(d)
    except Exception:
        return ""
    for fn in files:
        if not fn.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, fn)) as f:
                j = json.load(f)
        except Exception:
            continue
        if j.get("sessionId") == session_id:
            t = j.get("updatedAt") or 0
            if t > best_t:
                best_t, best = t, (j.get("name") or "")
    return best


def main():
    try:
        d = json.load(sys.stdin)
    except Exception:
        d = {}
    ev = d.get("hook_event_name", "")
    kind = {
        "UserPromptSubmit": "running",
        "Stop": "done",
        "Notification": "attention",
    }.get(ev)
    if not kind:
        return

    transcript = d.get("transcript_path")
    msg, title = "", ""
    if ev == "Stop":
        msg, title, outcome = scan_transcript(transcript, full=True)
        msg = msg[:300]
        if outcome == "interrupted":
            msg = ("interrupted — " + msg)[:300]
        elif outcome == "error":
            msg = ("ended with an error — " + msg)[:300]
    else:
        _, title, _ = scan_transcript(transcript, full=False)
        if ev == "UserPromptSubmit":
            msg = (d.get("prompt") or "").strip()[:220]
        elif ev == "Notification":
            msg = (d.get("message") or d.get("title") or "").strip()[:300]

    name = registry_name(d.get("session_id", ""))
    if title and (not name or AUTO_NAME.match(name)):
        name = title

    cwd = d.get("cwd") or os.getcwd()
    out = {
        "v": 1,
        "event": kind,
        "host": socket.gethostname().split(".")[0],
        "project": os.path.basename(cwd.rstrip("/")) or cwd,
        "cwd": cwd,
        "session_id": d.get("session_id", ""),
        "session_name": name,
        "message": msg,
        "hook": ev,
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
