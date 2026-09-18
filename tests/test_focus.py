"""Source navigation capture survives reporter refreshes and app restarts."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import hud_focus as focus


class FocusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = patch.dict(os.environ, {"AGENT_HUD_FOCUS_DIR": self.temp.name})
        env.start()
        self.addCleanup(env.stop)

    def test_cmux_captures_both_workspace_and_surface(self):
        workspace = "a1459d36-9666-44b4-bd6d-b27a5f97b0d9"
        surface = "e13f2348-1b32-4206-bca2-042bdac9f359"
        self.assertEqual(focus.capture_focus({"CMUX_WORKSPACE_ID": workspace, "CMUX_SURFACE_ID": surface}),
                         {"application": "com.cmuxterm.app", "workspace": workspace, "surface": surface})

    def test_warp_uses_the_official_session_link(self):
        url = "warp://session/a1459d36966644b4bd6db27a5f97b0d9"
        self.assertEqual(focus.capture_focus({"WARP_FOCUS_URL": url})["warp_url"], url)
        self.assertEqual(focus.warp_url("warp://action/new_tab?path=/tmp"), "")
        self.assertEqual(focus.warp_url(url + "?command=anything"), "")

    def test_current_terminal_wins_over_inherited_location_variables(self):
        env = {"WARP_FOCUS_URL": "warppreview://session/a1459d36966644b4bd6db27a5f97b0d9",
               "CMUX_WORKSPACE_ID": "a1459d36-9666-44b4-bd6d-b27a5f97b0d9",
               "TERM_PROGRAM": "WarpTerminal"}
        self.assertEqual(focus.capture_focus(env)["application"], "dev.warp.Warp-Preview")
        env["TERM_PROGRAM"] = "ghostty"
        self.assertEqual(focus.capture_focus(env)["application"], "com.cmuxterm.app")

    def test_iterm_captures_identity_and_tty_without_shell_commands(self):
        sid = "a1459d36-9666-44b4-bd6d-b27a5f97b0d9"
        captured = focus.capture_focus({"TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t1p2:" + sid}, tty="/dev/ttys012")
        self.assertEqual(captured["terminal_id"], sid)
        self.assertEqual(captured["tty"], "/dev/ttys012")
        self.assertEqual(captured["application"], "com.googlecode.iterm2")

    def test_terminal_captures_the_original_tty(self):
        self.assertEqual(focus.capture_focus({"TERM_PROGRAM": "Apple_Terminal"}, tty="/dev/ttys003"),
                         {"application": "com.apple.Terminal", "tty": "/dev/ttys003"})

    def test_record_is_private_and_survives_a_sparse_update(self):
        data = {"application": "com.cmuxterm.app", "workspace": "workspace", "surface": "surface"}
        focus.remember_focus("codex", "S", data)
        focus.remember_focus("codex", "S", {"application": "com.cmuxterm.app"})
        self.assertEqual(focus.recorded_focus("codex", "S"), data)
        self.assertEqual(focus.record_path("codex", "S").stat().st_mode & 0o777, 0o600)
        self.assertEqual(focus.recorded_focus("claude", "S"), {})

    def test_resuming_in_another_terminal_replaces_the_old_location(self):
        focus.remember_focus("codex", "S", {"application": "com.cmuxterm.app", "workspace": "old"})
        focus.remember_focus("codex", "S", {"application": "dev.warp.Warp-Stable", "warp_url": "new"})
        self.assertNotIn("workspace", focus.recorded_focus("codex", "S"))

    def test_stale_records_are_ignored_and_storage_is_bounded(self):
        with patch.object(focus, "MAX_RECORDS", 2):
            for sid in ("one", "two", "three"):
                focus.remember_focus("codex", sid, {"application": "com.cmuxterm.app"})
        self.assertEqual(len(list(Path(self.temp.name).glob("*.json"))), 2)
        path = focus.record_path("codex", "three")
        os.utime(path, (1, 1))
        self.assertEqual(focus.recorded_focus("codex", "three"), {})
