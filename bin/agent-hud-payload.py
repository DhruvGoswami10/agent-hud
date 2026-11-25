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
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from hud_focus import capture_focus, remember_focus

try:
    _user = getpass.getuser()
except Exception:
    _user = os.environ.get("USER", "")
AUTO_NAME = re.compile("^" + re.escape(re.sub(r"[^a-zA-Z0-9]+", "-", _user)) + r"-[0-9a-f]{2}$")


def scan_transcript(path):
    """Return (last assistant text, last custom title, outcome) from a transcript JSONL.

    Only the last ~256KB is read for the reply and outcome: transcripts grow
    to tens of MB, and a full scan on every Stop can blow the 10s hook
    timeout — losing the 'done' event and leaving the session stuck
    'running'. The last assistant message and outcome always live in the
    tail; the (possibly partial) first line after the seek simply fails to
    parse and is skipped.

    A rename, though, is written once wherever it happened — usually in the
    first minutes — so the head is swept for custom-title records too. Tail
    alone lost the name of every session bigger than the window, and those
    reported Claude Code's auto-generated "<user>-<hex>" instead.
    """
    last, title, outcome = "", "", ""
    if not path:
        return last, title, outcome
    try:
        with open(path, "rb") as f:
            size = os.fstat(f.fileno()).st_size
            if size > 262144:
                # One extra 64KB read; the tail below still wins for a
                # session renamed later on. A trailing partial line just
                # fails to parse.
                for raw in f.read(65536).split(b"\n"):
                    if b"custom-title" not in raw:
                        continue
                    try:
                        j = json.loads(raw)
                    except Exception:
                        continue
                    if j.get("type") == "custom-title" and j.get("customTitle"):
                        title = j["customTitle"]
                f.seek(size - 262144)
            for raw in f:
                if b"[Request interrupted by user" in raw:
                    outcome = "interrupted"
                    continue
                # Parse rather than byte-match the value: JSON spacing varies.
                if b"isApiErrorMessage" in raw:
                    try:
                        if json.loads(raw).get("isApiErrorMessage"):
                            outcome = "error"
                            continue
                    except Exception:
                        pass
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


def decision_prompt(d):
    ev, tool = d.get("hook_event_name"), d.get("tool_name")
    if ev == "PostToolUse":
        return None
    inp = d.get("tool_input") or {}
    if not isinstance(inp, dict):
        return None
    if tool == "AskUserQuestion":
        parts = []
        for index, question in enumerate(inp.get("questions", [])[:8], 1):
            if not isinstance(question, dict):
                continue
            text = question.get("question")
            if not isinstance(text, str):
                continue
            parts.append(str(index) + ". " + text)
            for option in question.get("options", [])[:12]:
                if isinstance(option, dict) and isinstance(option.get("label"), str):
                    parts.append("  • " + option["label"] + (" — " + str(option["description"]) if option.get("description") else ""))
            if question.get("multiSelect"):
                parts.append("  Choose one or more in Claude.")
            parts.append("")
        kind, title, detail = "question", "Claude has a question", "\n".join(parts).strip()
    elif tool == "ExitPlanMode":
        kind, title, detail = "plan", "Review Claude’s plan", str(inp.get("plan") or "Open the session to review the plan and choose how to continue.")
    elif ev == "PermissionRequest":
        kind, title = "permission", "Allow " + str(tool or "this action") + "?"
        detail = json.dumps(inp, indent=2, ensure_ascii=False)
    elif ev == "Notification":
        kind, title, detail = "input", "Claude needs your input", str(d.get("message") or d.get("title") or "Open the session to continue.")
    else:
        return None
    if len(detail.encode("utf-8")) > 32_000:
        detail = detail.encode("utf-8")[:30_000].decode("utf-8", errors="ignore") + "\n\nMore details in the session."
    return {"id": str(d.get("tool_use_id") or uuid.uuid4()), "kind": kind, "title": title[:200], "detail": detail}


def build_event(d):
    if not isinstance(d, dict):
        return None
    ev = d.get("hook_event_name", "")
    kind = {
        "UserPromptSubmit": "running",
        "Stop": "done",
        "Notification": "attention",
        "PermissionRequest": "attention",
        "PreToolUse": "attention",
        "PostToolUse": "running",
    }.get(ev)
    if not kind:
        return
    if ev in ("PreToolUse", "PostToolUse") and d.get("tool_name") not in ("AskUserQuestion", "ExitPlanMode"):
        return

    # Claude Code fires Notification for real permission prompts, for
    # "waiting for your input" idle pings ~60s after every turn, AND for
    # purely informational notices ("Claude Code login successful", update
    # notes, …). Only genuinely actionable ones may arm the orange
    # needs-you state — an informational notice stuck a Review button on a
    # session for a whole turn. Idle pings stay dropped; the rest demote to
    # info (visible in the feed, no glow, no banner).
    if ev == "Notification":
        notification_type = d.get("notification_type") or ""
        text = ((d.get("message") or "") + " " + (d.get("title") or "")).lower()
        if notification_type == "idle_prompt" or (not notification_type and
                ("waiting for your input" in text or "waiting for input" in text)):
            return
        actionable = notification_type in ("permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                                           "agent_needs_input", "quota_auto_resume_stale", "quota_auto_resume_disabled")
        if not notification_type:
            actionable = ("permission" in text or "approval" in text or "waiting" in text or "needs you" in text)
        if not actionable:
            kind = "info"

    transcript = d.get("transcript_path")
    msg, title, outcome = "", "", ""
    if ev == "Stop":
        msg, title, outcome = scan_transcript(transcript)
        msg = msg[:300]
        # A turn killed before any reply has nothing to quote — the label
        # then stands alone rather than trailing a bare em dash.
        if outcome == "interrupted":
            msg = ("interrupted — " + msg)[:300] if msg else "interrupted"
        elif outcome == "error":
            msg = ("ended with an error — " + msg)[:300] if msg else "ended with an error"
    else:
        _, title, _ = scan_transcript(transcript)
        if ev == "UserPromptSubmit":
            msg = (d.get("prompt") or "").strip()[:220]
        elif ev == "Notification":
            msg = (d.get("message") or d.get("title") or "").strip()[:300]
        elif ev == "PostToolUse":
            msg = "Continuing after your response"

    prompt = decision_prompt(d) if kind == "attention" else None
    if prompt and not msg:
        msg = (prompt["detail"] or prompt["title"])[:300]

    name = registry_name(d.get("session_id", ""))
    if title and (not name or AUTO_NAME.match(name)):
        name = title

    cwd = d.get("cwd") or os.getcwd()
    out = {
        "v": 2,
        "app": "claude",
        "outcome": outcome,
        "focus": remember_focus("claude", d.get("session_id", ""), capture_focus()),
        "event": kind,
        "host": os.environ.get("AGENT_HUD_HOST") or socket.gethostname().split(".")[0],
        "project": os.path.basename(cwd.rstrip("/")) or cwd,
        "cwd": cwd,
        "session_id": d.get("session_id", ""),
        "session_name": name,
        "message": msg,
        "hook": ev,
    }
    if prompt:
        out["prompt"] = prompt
        out["event_id"] = "prompt:" + prompt["id"]
    if ev == "PostToolUse":
        out["resolved_prompt_id"] = str(d.get("tool_use_id") or "")
    return out


def main():
    try:
        event = build_event(json.load(sys.stdin))
        if event:
            print(json.dumps(event))
    except (ValueError, TypeError, AttributeError):
        pass


if __name__ == "__main__":
    main()
