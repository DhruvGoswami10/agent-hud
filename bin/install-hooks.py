#!/usr/bin/env python3
"""Install/remove only Agent HUD's hooks, preserving other integrations.

  install-hooks.py /absolute/path/agent-hud-send [settings.json]
  install-hooks.py --cursor [hooks.json]
  install-hooks.py --codex [config.toml] [--with-hooks]
  install-hooks.py --uninstall  (all three providers)
"""
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hud_config import CODEX_EVENTS, CURSOR_EVENTS, codex, json_hooks

BIN = Path(__file__).resolve().parent


def install_cursor(argv):
    path = argv[0] if argv else Path.home() / '.cursor/hooks.json'
    json_hooks(path, BIN / 'agent-hud-cursor', CURSOR_EVENTS, cursor=True)
    print('Cursor hooks installed. Reload the Cursor window.', file=sys.stderr)


def install_codex(argv):
    with_hooks = '--with-hooks' in argv
    args = [a for a in argv if a != '--with-hooks']
    root = Path(os.environ.get('AGENT_HUD_CODEX_DIR', str(Path.home() / '.codex')))
    codex(args[0] if args else root / 'config.toml', BIN / 'agent-hud-codex', with_hooks)
    print('Codex notify installed; previous notifier preserved.', file=sys.stderr)
    if with_hooks:
        print('Review and trust these observational hooks in Codex /hooks.', file=sys.stderr)


def uninstall():
    json_hooks(Path.home() / '.claude/settings.json', BIN / 'agent-hud-send', (), remove=True)
    json_hooks(Path.home() / '.cursor/hooks.json', BIN / 'agent-hud-cursor', (), cursor=True, remove=True)
    root = Path(os.environ.get('AGENT_HUD_CODEX_DIR', str(Path.home() / '.codex')))
    codex(root / 'config.toml', BIN / 'agent-hud-codex', remove=True)


def main():
    args = sys.argv[1:]
    if args[:1] == ['--cursor']:
        install_cursor(args[1:])
    elif args[:1] == ['--codex']:
        install_codex(args[1:])
    elif args[:1] == ['--uninstall']:
        uninstall()
    else:
        forwarder = Path(args[0]) if args else BIN / 'agent-hud-send'
        path = args[1] if len(args) > 1 else Path.home() / '.claude/settings.json'
        json_hooks(path, forwarder, ('UserPromptSubmit', 'Notification', 'Stop'))
        print('Claude hooks installed. Restart existing Claude sessions.', file=sys.stderr)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError) as e:
        print('Agent HUD: ' + str(e), file=sys.stderr)
        sys.exit(1)
