"""Permission decisions are explicit, single-request replies, never inferred."""
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
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

BIN = Path(__file__).resolve().parents[1] / 'bin'
sys.path.insert(0, str(BIN))


def load(name):
    loader = importlib.machinery.SourceFileLoader(name.replace('-', '_'), str(BIN / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class PermissionHookTests(unittest.TestCase):
    def setUp(self):
        self.hook = load('agent-hud-permission')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.payload = {'hook_event_name': 'PermissionRequest', 'session_id': 'test-session',
                        'cwd': self.temp.name, 'tool_name': 'Bash', 'tool_input': {'command': "printf 'demo'"}}

    def run_hook(self, decision='allow', wrong_id=False, redirect=False):
        seen = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                seen.append((self.path, body))
                if redirect and self.path == '/approval':
                    self.send_response(307)
                    self.send_header('Location', '/wrong-destination')
                    self.end_headers()
                    return
                reply = {'request_id': 'different' if wrong_id else body.get('request_id'), 'decision': decision,
                         'updatedPermissions': [{'behavior': 'allow'}]}
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(reply).encode())

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            env = dict(os.environ, HOME=self.temp.name, AGENT_HUD_HOST='test', AGENT_HUD_FOCUS_DIR=self.temp.name,
                       AGENT_HUD_URL='http://127.0.0.1:%d' % server.server_port)
            result = subprocess.run([sys.executable, str(BIN / 'agent-hud-permission')],
                input=json.dumps(self.payload), text=True, capture_output=True, env=env, timeout=8, check=True)
            return result.stdout, seen
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

    def test_explicit_allow_returns_only_a_one_time_permission(self):
        output, seen = self.run_hook()
        self.assertEqual(json.loads(output), {'hookSpecificOutput': {'hookEventName': 'PermissionRequest',
                                                                   'decision': {'behavior': 'allow'}}})
        self.assertEqual(seen[0][0], '/approval')
        self.assertEqual(seen[0][1]['tool_input'], self.payload['tool_input'])

    def test_reject_returns_deny_without_changing_future_rules(self):
        output, _ = self.run_hook('deny')
        decision = json.loads(output)['hookSpecificOutput']['decision']
        self.assertEqual(decision['behavior'], 'deny')
        self.assertNotIn('updatedPermissions', decision)
        self.assertNotIn('interrupt', decision)

    def test_mismatched_reply_cannot_approve_a_different_request(self):
        output, _ = self.run_hook(wrong_id=True)
        self.assertEqual(output, '')

    def test_handoff_timeout_and_disconnect_never_become_allow(self):
        for choice in ('session', 'expired', 'disconnected', 'pending', '', 'approve', None):
            with self.subTest(choice=choice):
                self.assertIsNone(self.hook.hook_output({'request_id': 'one', 'decision': choice}, 'one'))

    def test_redirects_never_receive_the_permission_request(self):
        output, seen = self.run_hook(redirect=True)
        self.assertEqual(output, '')
        self.assertEqual([path for path, _ in seen], ['/approval', '/event'])

    def test_only_loopback_or_ssh_forwarded_urls_are_accepted(self):
        self.assertEqual(self.hook.local_url('http://127.0.0.1:48085'), 'http://127.0.0.1:48085')
        for raw in ('https://example.com', 'http://10.0.0.1:48085', 'http://user@localhost',
                    'http://localhost/path', 'http://localhost?token=x', 'file:///tmp/reply'):
            with self.assertRaises(ValueError):
                self.hook.local_url(raw)

    def test_questions_do_not_offer_fake_yes_no_answers(self):
        self.payload['tool_name'] = 'AskUserQuestion'
        output, seen = self.run_hook()
        self.assertEqual(output, '')
        self.assertEqual(seen, [])

    def test_malformed_hook_input_is_ignored(self):
        self.payload.pop('session_id')
        output, seen = self.run_hook()
        self.assertEqual(output, '')
        self.assertEqual(seen, [])

    def test_unavailable_hud_does_not_produce_a_permission_decision(self):
        with patch.dict(os.environ, {'AGENT_HUD_URL': 'http://127.0.0.1:1', 'AGENT_HUD_FOCUS_DIR': self.temp.name}), \
             patch.object(sys, 'stdin', io.StringIO(json.dumps(self.payload))), \
             patch.object(sys, 'stdout', io.StringIO()) as output:
            self.hook.main()
            self.assertEqual(output.getvalue(), '')


class QuestionNotificationTests(unittest.TestCase):
    def setUp(self):
        self.payload = load('agent-hud-payload.py')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        env = patch.dict(os.environ, {'HOME': self.temp.name, 'AGENT_HUD_FOCUS_DIR': self.temp.name})
        env.start()
        self.addCleanup(env.stop)

    def event(self, **fields):
        return self.payload.build_event(dict({'session_id': 'one', 'cwd': self.temp.name}, **fields))

    def test_multiple_questions_keep_all_options_and_multi_select_label(self):
        questions = [
            {'question': 'Which database?', 'options': [{'label': name} for name in ['Postgres', 'SQLite', 'MySQL', 'Redis', 'Other']], 'multiSelect': True},
            {'question': 'Which region?', 'options': [{'label': 'UAE'}, {'label': 'Europe'}]}
        ]
        event = self.event(hook_event_name='PreToolUse', tool_name='AskUserQuestion', tool_use_id='question-123',
                           tool_input={'questions': questions})
        self.assertEqual(event['event'], 'attention')
        self.assertEqual(event['prompt']['kind'], 'question')
        self.assertEqual(event['prompt']['id'], 'question-123')
        for text in ['Which database?', 'Postgres', 'SQLite', 'MySQL', 'Redis', 'Other', 'Which region?', 'UAE', 'Europe', 'one or more']:
            self.assertIn(text, event['prompt']['detail'])

    def test_plan_review_is_a_session_action(self):
        event = self.event(hook_event_name='PreToolUse', tool_name='ExitPlanMode', tool_input={'plan': 'First run tests, then review.'})
        self.assertEqual(event['prompt']['kind'], 'plan')
        self.assertIn('First run tests', event['prompt']['detail'])

    def test_question_answer_clears_attention_without_claiming_task_completion(self):
        event = self.event(hook_event_name='PostToolUse', tool_name='AskUserQuestion', tool_input={})
        self.assertEqual(event['event'], 'running')
        self.assertNotIn('prompt', event)

    def test_ordinary_tools_do_not_create_decision_alerts(self):
        self.assertIsNone(self.event(hook_event_name='PreToolUse', tool_name='Read', tool_input={}))
        self.assertIsNone(self.event(hook_event_name='PostToolUse', tool_name='Read', tool_input={}))

    def test_notification_type_is_used_instead_of_guessing_from_english_text(self):
        for kind in ['permission_prompt', 'agent_needs_input', 'elicitation_dialog', 'elicitation_url_dialog']:
            event = self.event(hook_event_name='Notification', notification_type=kind, message='Choose an option')
            self.assertEqual(event['event'], 'attention')
            self.assertEqual(event['prompt']['detail'], 'Choose an option')

    def test_idle_and_information_notices_are_not_decisions(self):
        self.assertIsNone(self.event(hook_event_name='Notification', notification_type='idle_prompt', message='Waiting'))
        event = self.event(hook_event_name='Notification', notification_type='auth_success', message='Permission to sign in confirmed')
        self.assertEqual(event['event'], 'info')
        self.assertNotIn('prompt', event)


class DecisionInstallerTests(unittest.TestCase):
    def test_install_is_idempotent_preserves_other_hooks_and_uninstalls_its_own(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / '.claude/settings.json'
            path.parent.mkdir()
            other = {'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': '/other/policy'}]}
            path.write_text(json.dumps({'hooks': {'PermissionRequest': [other]}}))
            env = dict(os.environ, HOME=tmp, AGENT_HUD_CODEX_DIR=str(root / '.codex'))
            command = [sys.executable, str(BIN / 'install-hooks.py')]
            subprocess.run(command, env=env, capture_output=True, check=True)
            first = path.read_bytes()
            backup_count = len(list(path.parent.glob('*.bak-agenthud-*')))
            subprocess.run(command, env=env, capture_output=True, check=True)
            self.assertEqual(path.read_bytes(), first)
            self.assertEqual(len(list(path.parent.glob('*.bak-agenthud-*'))), backup_count)
            hooks = json.loads(first)['hooks']
            self.assertEqual(hooks['PermissionRequest'][0], other)
            self.assertEqual(hooks['PermissionRequest'][1]['hooks'][0]['timeout'], 130)
            self.assertEqual(hooks['PreToolUse'][0]['matcher'], '^(AskUserQuestion|ExitPlanMode)$')
            subprocess.run(command + ['--uninstall'], env=env, capture_output=True, check=True)
            self.assertEqual(json.loads(path.read_text())['hooks'], {'PermissionRequest': [other]})

    def test_notify_only_removes_only_the_owned_permission_hook(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, HOME=tmp)
            command = [sys.executable, str(BIN / 'install-hooks.py')]
            subprocess.run(command, env=env, capture_output=True, check=True)
            subprocess.run(command + ['--notify-only'], env=env, capture_output=True, check=True)
            hooks = json.loads((Path(tmp) / '.claude/settings.json').read_text())['hooks']
            self.assertNotIn('PermissionRequest', hooks)
            self.assertIn('PreToolUse', hooks)


class ReporterOwnershipTests(unittest.TestCase):
    def test_a_reporter_with_a_lost_parent_exits_before_scanning_or_posting(self):
        reporter = load('agent-hud-registry')
        with patch.dict(os.environ, {'AGENT_HUD_PARENT_PID': '1234', 'AGENT_HUD_ONESHOT': ''}), \
             patch.object(reporter.os, 'getppid', return_value=1), \
             patch.object(reporter, 'payload') as payload:
            reporter.main()
            payload.assert_not_called()

    def test_parent_loss_is_checked_again_after_each_reporting_cycle(self):
        reporter = load('agent-hud-registry')
        with patch.dict(os.environ, {'AGENT_HUD_PARENT_PID': '1234', 'AGENT_HUD_ONESHOT': ''}), \
             patch.object(reporter.os, 'getppid', side_effect=[1234, 1]), \
             patch.object(reporter, 'payload', return_value={}) as payload, \
             patch.object(reporter.urllib.request, 'urlopen') as post, \
             patch.object(reporter.time, 'sleep'):
            reporter.main()
            payload.assert_called_once()
            post.assert_called_once()


if __name__ == '__main__':
    unittest.main()
