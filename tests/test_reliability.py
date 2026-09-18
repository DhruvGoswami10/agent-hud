"""Boundary regressions from the September reliability audit (no live I/O)."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

BIN = Path(__file__).resolve().parents[1] / "bin"


def script(name):
    loader = importlib.machinery.SourceFileLoader(name.replace("-", "_"), str(BIN / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class AdapterTests(unittest.TestCase):
    def test_codex_notify_wrapper_cannot_reenter_the_hud(self):
        # The live chain was HUD -> Computer Use -> --previous-notify HUD.
        # Bound the fake wrapper itself so the old code fails without leaving
        # a real runaway process tree behind.
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            calls = root / "wrapper-calls"
            wrapper = root / "wrapper.py"
            wrapper.write_text("""import json, pathlib, subprocess, sys
calls = pathlib.Path(sys.argv[1])
count = int(calls.read_text()) + 1 if calls.exists() else 1
calls.write_text(str(count))
if count < 3:
    subprocess.run(json.loads(sys.argv[3]) + [sys.argv[4]], check=True)
""")
            previous = [sys.executable, str(BIN / "agent-hud-codex")]
            chain = [sys.executable, str(wrapper), str(calls), "--previous-notify", json.dumps(previous)]
            (root / "agent-hud-chain.json").write_text(json.dumps(chain))
            received = []

            class Handler(BaseHTTPRequestHandler):
                def do_POST(self):
                    received.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
                    self.send_response(200)
                    self.end_headers()

                def log_message(self, *args):
                    pass

            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                env = dict(os.environ, AGENT_HUD_CODEX_DIR=tmp,
                           AGENT_HUD_URL="http://127.0.0.1:%d" % server.server_port)
                env.pop("AGENT_HUD_CODEX_NOTIFY_ACTIVE", None)
                data = {"type": "agent-turn-complete", "thread-id": "thread", "turn-id": "turn"}
                subprocess.run(previous + [json.dumps(data)], env=env, check=True, timeout=10,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            finally:
                server.shutdown()
                server.server_close()
                worker.join()
            self.assertEqual(len(received), 1, "a chained notifier must not repost the same completion")
            self.assertEqual(calls.read_text(), "1", "the previous notifier should still run exactly once")

    def test_codex_retries_have_stable_ids_but_new_turns_are_distinct(self):
        m = script("agent-hud-codex")
        ids = []
        for turn in ("one", "one", "two"):
            data = {"type": "agent-turn-complete", "thread-id": "thread", "turn-id": turn}
            with patch.object(m.sys, "argv", ["codex-hook", json.dumps(data)]), \
                    patch.object(m, "post") as post, patch.object(m, "handoff"):
                m.main()
            ids.append(post.call_args[0][0].get("event_id"))
        self.assertTrue(ids[0])
        self.assertEqual(ids[0], ids[1])
        self.assertNotEqual(ids[0], ids[2])

    def test_remote_restart_filter_excludes_the_updater_manifest(self):
        import re
        m = script("hud_bootstrap.py")
        pattern = m.REPORTER_PATTERN.replace("[[:space:]]", r"\s")
        self.assertRegex("python3 /home/dev/agent-hud/bin/agent-hud-registry", pattern)
        self.assertIsNone(re.search(pattern, "python3 - checksum " + json.dumps(m.FILES)))
        self.assertIsNone(re.search(pattern, "python3 /home/dev/agent-hud/bin/agent-hud-registry-backup"))

    def test_codex_completion_uses_thread_identity(self):
        m = script("agent-hud-codex")
        data = {"type": "agent-turn-complete", "thread-id": "thread", "turn-id": "turn"}
        with patch.object(m.sys, "argv", ["codex-hook", json.dumps(data)]), \
                patch.object(m, "post") as post, patch.object(m, "handoff"):
            m.main()
        self.assertEqual(post.call_args[0][0]["session_id"], "thread")

    def test_codex_stdin_permission_hook_is_observational(self):
        m = script("agent-hud-codex")
        data = {"hook_event_name": "PermissionRequest", "session_id": "thread"}
        output = io.StringIO()
        with patch.object(m.sys, "argv", ["codex-hook"]), \
                patch.object(m.sys, "stdin", io.StringIO(json.dumps(data))), \
                patch.object(m, "post") as post, patch.object(m, "handoff") as handoff, \
                contextlib.redirect_stdout(output):
            m.main()
        self.assertTrue(post.called)
        self.assertEqual(post.call_args[0][0]["event"], "attention")
        self.assertEqual(json.loads(output.getvalue()), {})
        handoff.assert_not_called()


class RegistryTests(unittest.TestCase):
    def rollout(self, records, age=0):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        path = root / "2026/09/18/rollout-test.jsonl"
        path.parent.mkdir(parents=True)
        records = [{"type": "session_meta", "payload": {"id": "S", "cwd": "/tmp/project"}}] + records
        path.write_text("\n".join(json.dumps(r) for r in records) + "\n")
        import os
        os.utime(path, (time.time() - age,) * 2)
        m = script("agent-hud-registry")
        m.CODEX_SESSIONS = str(root)
        return m, path

    def test_completed_codex_is_idle_immediately(self):
        m, _ = self.rollout([{"type": "event_msg", "payload": {"type": "task_complete"}}])
        row = m.codex_snapshot()[0]
        self.assertEqual(row["status"], "idle")
        self.assertEqual(row["outcome"], "finished")

    def test_quiet_running_codex_does_not_become_a_success(self):
        m, _ = self.rollout([{"type": "event_msg", "payload": {"type": "task_started"}}], age=120)
        row = m.codex_snapshot()[0]
        self.assertEqual(row["status"], "busy")
        self.assertNotEqual(row.get("outcome"), "finished")

    def test_abandoned_codex_loses_contact_without_claiming_success(self):
        m, _ = self.rollout([{"type": "event_msg", "payload": {"type": "task_started"}}], age=3601)
        row = m.codex_snapshot()[0]
        self.assertEqual(row["status"], "unknown")
        self.assertEqual(row["outcome"], "unknown")

    def test_unconfirmed_edit_does_not_count(self):
        m, path = self.rollout([])
        path.write_text(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": "tool", "name": "Edit", "input": {
                "file_path": "/tmp/file", "old_string": "a", "new_string": "b"}}
        ]}}) + "\n")
        with patch.object(m, "transcript_for", return_value=str(path)):
            self.assertEqual(m.file_changes("S").get("files_changed", 0), 0)


class InstallerTests(unittest.TestCase):
    def test_codex_toml_chain_install_upgrade_and_restore(self):
        m = script("install-hooks.py")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "fresh/config.toml"
            path.parent.mkdir()
            original = "# my notifier\nnotify = [\n 'python3', # preserve comments\n '/tmp/my notifier.py', 'literal\\path',\n]\nmodel = 'example'\n[projects.test]\nnotify = ['not-the-root']\n"
            path.write_text(original)
            m.install_codex([str(path)])
            chain = path.parent / "agent-hud-chain.json"
            self.assertEqual(json.loads(chain.read_text()), ["python3", "/tmp/my notifier.py", "literal\\path"])
            m.install_codex([str(path), "--with-hooks"])
            self.assertIn("hooks.PermissionRequest", path.read_text())
            installed = path.read_text()
            backups = list(path.parent.glob("*.bak*"))
            m.install_codex([str(path), "--with-hooks"])
            self.assertEqual(installed, path.read_text())
            self.assertEqual(backups, list(path.parent.glob("*.bak*")))
            m.codex(path, m.BIN / "agent-hud-codex", remove=True)
            self.assertEqual(path.read_text().rstrip(), original.rstrip())
            self.assertFalse(chain.exists())

    def test_codex_first_install_creates_missing_directory(self):
        m = script("install-hooks.py")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "missing/config.toml"
            m.install_codex([str(path)])
            self.assertTrue(path.exists())
            self.assertEqual(json.loads((path.parent / "agent-hud-chain.json").read_text()), [])

    def test_codex_invalid_notify_never_replaces_configuration(self):
        m = script("install-hooks.py")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text("notify = [1, false]\n")
            with self.assertRaises(ValueError):
                m.install_codex([str(path)])
            self.assertEqual(path.read_text(), "notify = [1, false]\n")
            self.assertFalse((path.parent / "agent-hud-chain.json").exists())

    def test_uninstall_preserves_notifier_changed_by_user(self):
        m = script("install-hooks.py")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            m.install_codex([str(path)])
            path.write_text("notify = ['new-notifier']\n")
            m.codex(path, m.BIN / "agent-hud-codex", remove=True)
            self.assertEqual(path.read_text(), "notify = ['new-notifier']\n")

    def test_malformed_cursor_config_is_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "hooks.json"
            path.write_text("{broken")
            m = script("install-hooks.py")
            with self.assertRaises((ValueError, SystemExit)):
                m.install_cursor([str(path)])
            self.assertEqual(path.read_text(), "{broken")


class WatchRelayTests(unittest.TestCase):
    def test_tls_pairing_and_read_only_authorization(self):
        import ssl
        import threading
        import urllib.request
        import urllib.error
        m = script("agent-hud-watch-bridge")
        with tempfile.TemporaryDirectory() as tmp:
            pair = m.prepare(tmp, host="127.0.0.1")
            again = m.prepare(tmp, host="127.0.0.1")
            self.assertEqual(pair["pin"], again["pin"])
            self.assertEqual(pair["token"], again["token"])
            self.assertEqual((Path(tmp) / "watch-pairing.json").stat().st_mode & 0o777, 0o600)
            server = m.WatchServer(("127.0.0.1", 0), tmp, pair["token"])
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                # Trust this fixture's certificate only; no global trust bypass.
                context = ssl.create_default_context(cafile=str(Path(tmp) / "watch-cert.pem"))
                context.verify_flags |= ssl.VERIFY_X509_STRICT
                context.check_hostname = False  # identity is pinned by the Watch client
                base = "https://127.0.0.1:%d" % server.server_port
                for endpoint, token, status in [("/watch", "wrong", 401), ("/debug", pair["token"], 404),
                                                ("/event", pair["token"], 404)]:
                    req = urllib.request.Request(base + endpoint, headers={"Authorization": "Bearer " + token})
                    with self.assertRaises(urllib.error.HTTPError) as error:
                        urllib.request.urlopen(req, context=context, timeout=3)
                    self.assertEqual(error.exception.code, status)
                    error.exception.close()
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
