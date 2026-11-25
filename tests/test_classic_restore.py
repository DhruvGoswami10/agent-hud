"""Upgrading from decision cards restores observational hooks cleanly."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

BIN = Path(__file__).resolve().parents[1] / 'bin'
sys.path.insert(0, str(BIN))


class ClassicHookRestoreTests(unittest.TestCase):
    def test_cached_permission_hook_exits_without_answering_or_reporting_an_error(self):
        result = subprocess.run([sys.executable, str(BIN / 'agent-hud-permission')],
                                input=json.dumps({'hook_event_name': 'PermissionRequest',
                                                  'tool_name': 'Bash', 'tool_input': {'command': 'demo'}}),
                                text=True, capture_output=True, timeout=2, check=True)
        self.assertEqual(result.stdout, '')
        self.assertEqual(result.stderr, '')

    def test_upgrade_removes_only_owned_decision_hooks_and_is_idempotent(self):
        for arguments in ([], ['--notify-only']):
            with self.subTest(arguments=arguments), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                path = root / '.claude/settings.json'
                path.parent.mkdir()
                other = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': '/other/policy'}]}
                old = {'hooks': [{'type': 'command', 'command': str(BIN / 'agent-hud-send')}]}
                permission = {'hooks': [{'type': 'command', 'command': str(BIN / 'agent-hud-permission'), 'timeout': 130}]}
                cfg = {'hooks': {'PermissionRequest': [other, permission], 'PreToolUse': [old],
                                 'PostToolUse': [old]}, 'permissions': {'defaultMode': 'default'}}
                path.write_text(json.dumps(cfg))
                env = dict(os.environ, HOME=tmp, AGENT_HUD_CODEX_DIR=str(root / '.codex'))
                command = [sys.executable, str(BIN / 'install-hooks.py'), *arguments]
                subprocess.run(command, env=env, capture_output=True, check=True)
                first = path.read_bytes()
                result = json.loads(first)
                self.assertEqual(result['permissions'], cfg['permissions'])
                self.assertEqual(result['hooks']['PermissionRequest'], [other])
                self.assertEqual(set(result['hooks']), {'PermissionRequest', 'UserPromptSubmit', 'Notification', 'Stop'})
                subprocess.run(command, env=env, capture_output=True, check=True)
                self.assertEqual(path.read_bytes(), first)
                subprocess.run([sys.executable, str(BIN / 'install-hooks.py'), '--uninstall'],
                               env=env, capture_output=True, check=True)
                self.assertEqual(json.loads(path.read_text())['hooks'], {'PermissionRequest': [other]})


class ReporterOwnershipTests(unittest.TestCase):
    def reporter(self):
        loader = importlib.machinery.SourceFileLoader('classic_hud_registry', str(BIN / 'agent-hud-registry'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        return module

    def test_a_reporter_with_a_lost_parent_exits_before_scanning_or_posting(self):
        reporter = self.reporter()
        with patch.dict(os.environ, {'AGENT_HUD_PARENT_PID': '1234', 'AGENT_HUD_ONESHOT': ''}), \
             patch.object(reporter.os, 'getppid', return_value=1), \
             patch.object(reporter, 'payload') as payload:
            reporter.main()
            payload.assert_not_called()

    def test_parent_loss_is_checked_again_after_each_reporting_cycle(self):
        reporter = self.reporter()
        with patch.dict(os.environ, {'AGENT_HUD_PARENT_PID': '1234', 'AGENT_HUD_ONESHOT': ''}), \
             patch.object(reporter.os, 'getppid', side_effect=[1234, 1]), \
             patch.object(reporter, 'payload', return_value={}) as payload, \
             patch.object(reporter.urllib.request, 'urlopen') as post, \
             patch.object(reporter.time, 'sleep'):
            reporter.main()
            payload.assert_called_once()
            post.assert_called_once()
