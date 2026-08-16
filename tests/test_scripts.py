#!/usr/bin/env python3
"""Tests for the bin/ forwarder scripts.

These run the real scripts as subprocesses against a fake ~/.claude tree, so
they cover exactly what Claude Code's hooks will hit in production. Run with:

    python3 tests/test_scripts.py        (or: make test)
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin")
PAYLOAD = os.path.join(BIN, "agent-hud-payload.py")
REGISTRY = os.path.join(BIN, "agent-hud-registry")

SESSION_ID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"


def auto_name():
    """What Claude Code generates for an unnamed session, for this user."""
    import getpass
    import re
    return re.sub(r"[^a-zA-Z0-9]+", "-", getpass.getuser()) + "-d4"


def assistant_line(text, ts=None, model="claude-fable-5", effort="max"):
    return json.dumps({
        "type": "assistant",
        "timestamp": ts or time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "effort": effort,
        "message": {
            "model": model,
            "content": [{"type": "text", "text": text}],
            "usage": {
                "input_tokens": 10,
                "cache_creation_input_tokens": 5,
                "cache_read_input_tokens": 100,
                "output_tokens": 20,
            },
        },
    })


def tool_use_line(name, inp):
    """An assistant record containing one Edit/Write tool call."""
    return json.dumps({
        "type": "assistant",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()),
        "message": {"model": "claude-fable-5",
                    "content": [{"type": "tool_use", "name": name, "input": inp}]},
    })


class Fixture:
    """A throwaway ~/.claude with one session and one transcript."""

    def __init__(self, transcript_lines, session_name=None, status="busy"):
        self.home = tempfile.mkdtemp(prefix="agenthud-test-")
        self.cwd = os.path.join(self.home, "my-project")
        os.makedirs(self.cwd)
        sessions = os.path.join(self.home, ".claude", "sessions")
        projects = os.path.join(self.home, ".claude", "projects", "-my-project")
        os.makedirs(sessions)
        os.makedirs(projects)
        # Named with a pid that is genuinely alive (ours): the reporter now
        # skips registry files whose process is dead.
        self.session_file = os.path.join(sessions, "%d.json" % os.getpid())
        with open(self.session_file, "w") as f:
            json.dump({
                "sessionId": SESSION_ID,
                "name": session_name if session_name is not None else auto_name(),
                "cwd": self.cwd,
                "status": status,
                "updatedAt": int(time.time() * 1000),
            }, f)
        self.transcript = os.path.join(projects, SESSION_ID + ".jsonl")
        with open(self.transcript, "w") as f:
            f.write("\n".join(transcript_lines) + "\n")

    def env(self):
        e = dict(os.environ)
        e["HOME"] = self.home
        return e

    def cleanup(self):
        shutil.rmtree(self.home, ignore_errors=True)


def run_payload(hook, fixture, **extra):
    payload = {"hook_event_name": hook, "session_id": SESSION_ID,
               "cwd": fixture.cwd, "transcript_path": fixture.transcript}
    payload.update(extra)
    out = subprocess.run([sys.executable, PAYLOAD], input=json.dumps(payload),
                         capture_output=True, text=True, env=fixture.env()).stdout.strip()
    return json.loads(out) if out else None


class PayloadTests(unittest.TestCase):
    def setUp(self):
        self.fx = Fixture([assistant_line("all done here")])
        self.addCleanup(self.fx.cleanup)

    # --- notification noise -------------------------------------------------

    def test_idle_ping_is_dropped(self):
        """Claude Code pings 'waiting for your input' ~60s after EVERY turn.
        Forwarding it made the notch alert all day long."""
        for msg in ["Claude is waiting for your input",
                    "Claude is waiting for input"]:
            self.assertIsNone(run_payload("Notification", self.fx, message=msg),
                              "idle ping must not become an event: %r" % msg)

    def test_permission_request_still_alerts(self):
        ev = run_payload("Notification", self.fx,
                         message="Claude needs your permission to use Bash")
        self.assertIsNotNone(ev)
        self.assertEqual(ev["event"], "attention")
        self.assertIn("permission", ev["message"])

    def test_informational_notification_is_not_attention(self):
        """'Claude Code login successful' stuck an orange Review button on a
        session for a whole turn — notices aren't approval requests."""
        for msg in ["Claude Code login successful",
                    "Auto-update installed, restart to apply"]:
            ev = run_payload("Notification", self.fx, message=msg)
            self.assertIsNotNone(ev, msg)
            self.assertEqual(ev["event"], "info",
                             "informational notice must not arm Review: %r" % msg)

    def test_unknown_hooks_are_ignored(self):
        self.assertIsNone(run_payload("PreToolUse", self.fx))

    def test_malformed_input_does_not_crash(self):
        r = subprocess.run([sys.executable, PAYLOAD], input="not json at all",
                           capture_output=True, text=True, env=self.fx.env())
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.strip(), "")

    # --- turn outcomes ------------------------------------------------------

    def test_completed_turn_reports_the_reply(self):
        ev = run_payload("Stop", self.fx)
        self.assertEqual(ev["event"], "done")
        self.assertEqual(ev["message"], "all done here")

    def test_interrupted_turn_is_labelled(self):
        fx = Fixture([assistant_line("partial answer"),
                      json.dumps({"type": "user", "message": {"content":
                                 "[Request interrupted by user]"}})])
        self.addCleanup(fx.cleanup)
        ev = run_payload("Stop", fx)
        self.assertTrue(ev["message"].startswith("interrupted"),
                        "an interrupted turn must not claim it finished: %r" % ev["message"])

    def test_errored_turn_is_labelled(self):
        """Both spacings, because JSON formatting is not a stable contract."""
        for err in ['{"type":"user","isApiErrorMessage":true,"message":{"content":"API Error"}}',
                    json.dumps({"type": "user", "isApiErrorMessage": True,
                                "message": {"content": "API Error"}})]:
            fx = Fixture([assistant_line("something"), err])
            self.addCleanup(fx.cleanup)
            ev = run_payload("Stop", fx)
            self.assertIn("error", ev["message"].lower(),
                          "unrecognised error line: %s" % err)

    def test_healthy_turn_is_not_called_an_error(self):
        """isApiErrorMessage:false appears on ordinary lines — don't match it."""
        fx = Fixture([assistant_line("fine"),
                      '{"type":"user","isApiErrorMessage":false,"message":{"content":"hi"}}'])
        self.addCleanup(fx.cleanup)
        self.assertNotIn("error", run_payload("Stop", fx)["message"].lower())

    def test_prompt_submit_reports_running(self):
        ev = run_payload("UserPromptSubmit", self.fx, prompt="do the thing")
        self.assertEqual(ev["event"], "running")
        self.assertEqual(ev["message"], "do the thing")

    # --- session naming -----------------------------------------------------

    def test_auto_generated_name_falls_back_to_transcript_title(self):
        fx = Fixture([json.dumps({"type": "custom-title", "sessionId": SESSION_ID,
                                  "customTitle": "BIG-BRAIN"}),
                      assistant_line("hi")])
        self.addCleanup(fx.cleanup)
        ev = run_payload("Stop", fx)
        self.assertEqual(ev["session_name"], "BIG-BRAIN",
                         "resumed sessions lose their name in the registry")

    def test_real_name_is_kept(self):
        fx = Fixture([assistant_line("hi")], session_name="My Session")
        self.addCleanup(fx.cleanup)
        self.assertEqual(run_payload("Stop", fx)["session_name"], "My Session")


class RegistryTests(unittest.TestCase):
    def snapshot(self, fixture):
        env = fixture.env()
        env["AGENT_HUD_ONESHOT"] = "1"
        out = subprocess.run([sys.executable, REGISTRY], capture_output=True,
                             text=True, env=env)
        self.assertEqual(out.returncode, 0, out.stderr)
        return json.loads(out.stdout)

    def test_reports_session_with_stats(self):
        fx = Fixture([assistant_line("hello")])
        self.addCleanup(fx.cleanup)
        snap = self.snapshot(fx)
        self.assertEqual(len(snap["sessions"]), 1)
        s = snap["sessions"][0]
        self.assertEqual(s["status"], "busy")
        self.assertEqual(s["model"], "claude-fable-5")
        self.assertEqual(s["effort"], "max")
        self.assertEqual(s["ctx_used"], 135)
        self.assertEqual(s["last_in"], 115)
        self.assertEqual(s["last_out"], 20)
        self.assertEqual(s["outcome"], "finished")

    def test_dead_pid_session_is_skipped(self):
        """A killed terminal leaves its registry file behind still saying
        'busy' — that must not read as a live session forever."""
        fx = Fixture([assistant_line("x")])
        self.addCleanup(fx.cleanup)
        sessions = os.path.join(fx.home, ".claude", "sessions")
        with open(os.path.join(sessions, "4194303.json"), "w") as f:
            json.dump({"sessionId": "dead-dead-dead", "name": "ghost", "cwd": fx.cwd,
                       "status": "busy", "updatedAt": int(time.time() * 1000)}, f)
        snap = self.snapshot(fx)
        self.assertEqual([s["sessionId"] for s in snap["sessions"]], [SESSION_ID])

    def test_file_changes_are_reported(self):
        fx = Fixture([
            assistant_line("working"),
            tool_use_line("Edit", {"file_path": "/p/App.swift",
                                   "old_string": "a", "new_string": "x\ny\nz"}),
            tool_use_line("Write", {"file_path": "/p/New.swift",
                                    "content": "1\n2\n3\n4\n5"}),
        ])
        self.addCleanup(fx.cleanup)
        s = self.snapshot(fx)["sessions"][0]
        self.assertEqual(s["files_changed"], 2)
        self.assertEqual(s["lines_added"], 8)
        self.assertEqual(s["lines_removed"], 1)
        self.assertEqual(s["top_file"], "New.swift")

    def test_interrupted_outcome_is_reported(self):
        fx = Fixture([assistant_line("partial"),
                      json.dumps({"type": "user", "message": {"content":
                                 "[Request interrupted by user for tool use]"}})])
        self.addCleanup(fx.cleanup)
        self.assertEqual(self.snapshot(fx)["sessions"][0]["outcome"], "interrupted")

    def test_usage_windows_and_burn_hours(self):
        fx = Fixture([assistant_line("hello")])
        self.addCleanup(fx.cleanup)
        usage = self.snapshot(fx)["usage"]
        # Costly tokens only: input + cache-write + output (cache reads are cheap).
        self.assertEqual(usage["h5"], 35)
        self.assertEqual(usage["d7"], 35)
        self.assertEqual(sum(usage["hours"].values()), 35,
                         "burn strip cells must add up to the 5h window")

    def test_stale_sessions_are_skipped(self):
        fx = Fixture([assistant_line("old")])
        self.addCleanup(fx.cleanup)
        path = fx.session_file
        with open(path) as f:
            data = json.load(f)
        data["updatedAt"] = int((time.time() - 3 * 86400) * 1000)
        with open(path, "w") as f:
            json.dump(data, f)
        self.assertEqual(self.snapshot(fx)["sessions"], [],
                         "sessions untouched for days are not live")


if __name__ == "__main__":
    unittest.main(verbosity=2)
