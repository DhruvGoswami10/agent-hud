"""SSH attribution must select the original terminal, not another tab on a host."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "bin"))
import hud_ssh_focus as focus


class SSHFocusTests(unittest.TestCase):
    connection = "192.0.2.10 49152 198.51.100.20 22"
    target = {"application": "com.cmuxterm.app",
              "workspace": "a1459d36-9666-44b4-bd6d-b27a5f97b0d9",
              "surface": "e13f2348-1b32-4206-bca2-042bdac9f359"}

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        env = patch.dict(os.environ, {"AGENT_HUD_SSH_LINK_DIR": temporary.name})
        env.start(); self.addCleanup(env.stop)

    def test_connections_keep_source_ports_distinct_and_support_ipv6(self):
        rows = focus.parse_connections("p10\ncssh\nn192.0.2.10:49152->198.51.100.20:22\n"
            "p11\ncssh\nn192.0.2.10:49153->198.51.100.20:22\n"
            "p12\ncssh\nn[2001:db8::1]:50000->[2001:db8::2]:22\n"
            "p13\ncother\nn192.0.2.10:49152->198.51.100.20:22\n")
        self.assertEqual([r["pid"] for r in rows], [10, 11, 12])
        self.assertEqual(rows[0]["connection"], self.connection)
        self.assertNotEqual(rows[0]["connection"], rows[1]["connection"])
        self.assertEqual(rows[2]["connection"], "2001:db8::1 50000 2001:db8::2 22")

    def test_cmux_links_use_tty_identity_and_refuse_ambiguous_surfaces(self):
        surface = {"id": self.target["surface"], "tty": "ttys007"}
        tree = {"windows": [{"workspaces": [{"id": self.target["workspace"],
                 "panes": [{"surfaces": [surface]}]}]}]}
        self.assertEqual(focus.cmux_terminals(tree)["ttys007"], self.target)
        tree["windows"][0]["workspaces"][0]["panes"][0]["surfaces"].append(surface)
        self.assertEqual(focus.cmux_terminals(tree), {})

    def test_saved_link_is_private_and_cannot_follow_a_reused_or_closed_connection(self):
        row = {"pid": 10, "connection": self.connection}
        focus.save_link(row, "ttys007", self.target, "original process")
        self.assertEqual(focus.link_path(self.connection).stat().st_mode & 0o777, 0o600)
        with patch.object(focus, "connections", return_value=[row]), \
                patch.object(focus, "dedicated_connection", return_value=True), \
                patch.object(focus, "process_tty", return_value="ttys007"), \
                patch.object(focus, "process_start", return_value="original process") as started:
            self.assertEqual(focus.resolve(self.connection), {"focus": self.target})
            started.return_value = "reused PID"
            self.assertIn("error", focus.resolve(self.connection))
        with patch.object(focus, "connections", return_value=[]):
            self.assertIn("error", focus.resolve(self.connection))

    def test_shared_ssh_connection_never_guesses_a_tab(self):
        row = {"pid": 10, "connection": self.connection}
        focus.save_link(row, "ttys007", self.target, "started")
        with patch.object(focus, "connections", return_value=[row]), \
                patch.object(focus, "dedicated_connection", return_value=False):
            self.assertIn("error", focus.resolve(self.connection))

    def reconnect_fixture(self, target=None, connection=None):
        """A background Claude keeps its old connection after its pane reconnects."""
        focus.save_link({"pid": 10, "connection": self.connection}, "ttys007", self.target, "old process")
        row = {"pid": 20, "connection": connection or "192.0.2.10 50000 198.51.100.20 22"}
        focus.save_link(row, "ttys007", target or self.target, "new process")
        for name, value in (("connections", [row]), ("dedicated_connection", True),
                            ("process_tty", "ttys007"), ("process_start", "new process")):
            mock = patch.object(focus, name, return_value=value)
            mock.start(); self.addCleanup(mock.stop)
        return row

    def test_reconnect_recovers_only_the_original_cmux_workspace_and_surface(self):
        self.reconnect_fixture()
        result = focus.resolve(self.connection)
        self.assertEqual(result.get("focus"), self.target)
        self.assertTrue(result.get("reconnected"))

    def test_same_pane_can_reconnect_after_the_mac_changes_network(self):
        self.reconnect_fixture(connection="192.0.2.99 50000 198.51.100.20 22")
        self.assertEqual(focus.resolve(self.connection).get("focus"), self.target)

    def test_reconnect_does_not_guess_another_pane_on_the_same_server(self):
        row = self.reconnect_fixture()
        for key in ("workspace", "surface"):
            with self.subTest(key=key):
                other = dict(self.target, **{key: "2335370e-ceb8-4fc8-aca4-52162f12c35e"})
                focus.save_link(row, "ttys007", other, "new process")
                self.assertIn("error", focus.resolve(self.connection))

    def test_reconnect_requires_a_saved_original_pane_and_the_same_destination(self):
        row = self.reconnect_fixture()
        for connection in ("192.0.2.10 50000 198.51.100.21 22", "192.0.2.10 50000 198.51.100.20 2222"):
            with self.subTest(connection=connection), patch.object(focus, "connections", return_value=[dict(row, connection=connection)]):
                focus.save_link(dict(row, connection=connection), "ttys007", self.target, "new process")
                self.assertIn("error", focus.resolve(self.connection))
        focus.link_path(self.connection).unlink()
        self.assertIn("error", focus.resolve(self.connection))

    def test_reconnect_revalidates_process_start_tty_and_dedicated_connection(self):
        self.reconnect_fixture()
        for name, invalid in (("process_start", "reused PID"), ("process_tty", "ttys008"),
                              ("process_tty", ""), ("dedicated_connection", False)):
            with self.subTest(name=name, invalid=invalid), patch.object(focus, name, return_value=invalid):
                self.assertIn("error", focus.resolve(self.connection))

    def test_reconnect_refuses_multiple_connections_in_the_same_pane(self):
        row = self.reconnect_fixture()
        other = {"pid": 21, "connection": "192.0.2.10 50001 198.51.100.20 22"}
        focus.save_link(other, "ttys007", self.target, "new process")
        with patch.object(focus, "connections", return_value=[row, other]):
            self.assertIn("error", focus.resolve(self.connection))

    def test_reconnect_requires_complete_cmux_ids_in_both_saved_links(self):
        row = self.reconnect_fixture()
        for bad in ({"application": "com.cmuxterm.app"}, dict(self.target, surface="not-a-uuid"),
                    dict(self.target, application="com.apple.Terminal")):
            with self.subTest(focus=bad):
                focus.save_link(row, "ttys007", bad, "new process")
                self.assertIn("error", focus.resolve(self.connection))
                focus.save_link(row, "ttys007", self.target, "new process")
                focus.save_link({"pid": 10, "connection": self.connection}, "ttys007", bad, "old process")
                self.assertIn("error", focus.resolve(self.connection))
                focus.save_link({"pid": 10, "connection": self.connection}, "ttys007", self.target, "old process")

    def test_existing_connection_failure_never_redirects_to_a_reconnect(self):
        row = self.reconnect_fixture()
        reused = {"pid": 99, "connection": self.connection}
        with patch.object(focus, "connections", return_value=[reused, row]):
            self.assertIn("error", focus.resolve(self.connection))

    def test_link_storage_is_bounded(self):
        with patch.object(focus, "MAX_LINKS", 2):
            for port in (49152, 49153, 49154):
                focus.save_link({"pid": port, "connection": "192.0.2.10 %s 198.51.100.20 22" % port},
                                "ttys007", self.target, "started")
        self.assertEqual(len(list(focus.link_dir().glob("*.json"))), 2)
