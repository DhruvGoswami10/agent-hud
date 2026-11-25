"""Conservative, atomic integration config edits. Python 3.9+, no dependencies."""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import tempfile
import time

CODEX_EVENTS = ('SessionStart', 'UserPromptSubmit', 'PermissionRequest', 'Stop', 'Interrupt', 'SessionEnd')
CURSOR_EVENTS = ('beforeSubmitPrompt', 'sessionStart', 'sessionEnd', 'stop')
BEGIN = '# BEGIN Agent HUD hooks\n'
END = '# END Agent HUD hooks\n'


def atomic_write(path, text, backup=True):
    path = Path(path)
    if path.exists() and path.read_text() == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    if backup and path.exists():
        shutil.copy2(path, str(path) + '.bak-agenthud-' + str(time.time_ns()))
    fd, tmp = tempfile.mkstemp(prefix='.agenthud-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        if path.exists():
            shutil.copymode(path, tmp)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    return True


def load_json(path):
    path = Path(path)
    data = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(data, dict) or not isinstance(data.get('hooks', {}), dict):
        raise ValueError('Invalid hooks configuration: ' + str(path))
    return data


def owns(command, executable):
    try:
        args = shlex.split(command)
    except (ValueError, TypeError):
        return False
    # Match an executable, not a comment or arbitrary substring in another hook.
    return bool(args) and (Path(args[0]).name == executable or
                           (Path(args[0]).name.startswith('python') and len(args) > 1
                            and Path(args[1]).name == executable))


def json_hooks(path, forwarder, events, cursor=False, remove=False):
    cfg = load_json(path)  # malformed data is never overwritten
    hooks = cfg.setdefault('hooks', {})
    if cursor and not remove:
        cfg.setdefault('version', 1)
    name = Path(forwarder).name
    for ev in list(hooks):
        groups = hooks[ev]
        if not isinstance(groups, list):
            raise ValueError('Invalid hook list: ' + ev)
        kept = []
        for group in groups:
            if not isinstance(group, dict):
                raise ValueError('Invalid hook entry: ' + ev)
            if cursor:
                if not owns(group.get('command', ''), name):
                    kept.append(group)
            else:
                inner = group.get('hooks', [])
                if not isinstance(inner, list) or not all(isinstance(h, dict) for h in inner):
                    raise ValueError('Invalid hook group: ' + ev)
                rest = [h for h in inner if not owns(h.get('command', ''), name)]
                if rest or not inner:
                    kept.append(dict(group, hooks=rest) if inner else group)
        if kept:
            hooks[ev] = kept
        else:
            hooks.pop(ev, None)
    if not remove:
        command = shlex.quote(str(Path(forwarder).resolve()))
        for ev in events:
            hook = {'command': command, 'timeout': 3 if name == 'agent-hud-codex' else 5}
            if not cursor:
                hook = {'hooks': [dict(hook, type='command')]}
            hooks.setdefault(ev, []).append(hook)
    # Keep original bytes (and do not make a backup) on semantic no-ops.
    original = load_json(path)
    if cfg != original:
        atomic_write(path, json.dumps(cfg, indent=2) + '\n')


def _string(s, i):
    """Decode TOML basic/literal strings, including multiline forms."""
    q = s[i]
    triple = s.startswith(q * 3, i)
    delimiter = q * (3 if triple else 1)
    i += len(delimiter)
    if triple and s.startswith('\r\n', i):
        i += 2
    elif triple and s[i:i+1] == '\n':
        i += 1
    out = []
    escapes = {'b': '\b', 't': '\t', 'n': '\n', 'f': '\f', 'r': '\r', '"': '"', '\\': '\\'}
    while i < len(s):
        if s.startswith(delimiter, i):
            i += len(delimiter)
            if triple:
                for _ in range(2):
                    if s[i:i+1] == q:
                        out.append(q)
                        i += 1
            return ''.join(out), i
        c = s[i]
        i += 1
        if c == '\n' and not triple:
            raise ValueError('Unterminated TOML string')
        if c == '\\' and q == '"':
            if i >= len(s):
                break
            e = s[i]
            i += 1
            if triple and e in ' \t\r\n':
                start = i - 1
                while i < len(s) and s[i] in ' \t\r\n':
                    i += 1
                if '\n' not in s[start:i]:
                    raise ValueError('Invalid TOML continuation')
                continue
            if e in ('u', 'U'):
                length = 4 if e == 'u' else 8
                digits = s[i:i+length]
                if len(digits) != length or not re.fullmatch('[0-9a-fA-F]+', digits):
                    raise ValueError('Invalid TOML unicode escape')
                cp = int(digits, 16)
                if cp > 0x10ffff or 0xd800 <= cp <= 0xdfff:
                    raise ValueError('Invalid TOML unicode scalar')
                out.append(chr(cp))
                i += length
            elif e in escapes:
                out.append(escapes[e])
            else:
                raise ValueError('Invalid TOML escape')
        else:
            if ord(c) < 32 and c not in ('\t', '\n', '\r'):
                raise ValueError('Invalid TOML control character')
            out.append(c)
    raise ValueError('Unterminated TOML string')


def _space(s, i):
    while i < len(s):
        if s[i].isspace():
            i += 1
        elif s[i] == '#':
            end = s.find('\n', i)
            i = len(s) if end < 0 else end + 1
        else:
            break
    return i


def string_array(s, i=0):
    i = _space(s, i)
    if s[i:i+1] != '[':
        raise ValueError('notify must be a TOML array of strings; left unchanged')
    i += 1
    result = []
    while True:
        i = _space(s, i)
        if s[i:i+1] == ']':
            return result, i + 1
        if s[i:i+1] not in ('"', "'"):
            raise ValueError('notify must contain only TOML strings; left unchanged')
        value, i = _string(s, i)
        result.append(value)
        i = _space(s, i)
        if s[i:i+1] == ']':
            return result, i + 1
        if s[i:i+1] != ',':
            raise ValueError('Invalid notify array; left unchanged')
        i += 1


def notify_span(text):
    """Find only the root notify key; skip strings, multiline values and tables.

    This edits a single typed value, not the rest of the user's TOML. Unsupported
    or malformed notify syntax fails before any backup/config/chain is written.
    """
    found = None
    i = 0
    while i < len(text):
        start = i
        i = _space(text, i)
        if i == len(text) or text[i] == '[':
            break
        line_start = text.rfind('\n', 0, i) + 1
        m = re.match(r'(?:notify|"notify"|\'notify\')\s*=', text[i:])
        if m:
            if found:
                raise ValueError('Duplicate root notify key; left unchanged')
            value, end = string_array(text, i + m.end())
            line_end = text.find('\n', end)
            line_end = len(text) if line_end < 0 else line_end + 1
            trailing = text[end:line_end].strip()
            if trailing and not trailing.startswith('#'):
                raise ValueError('Invalid text after notify array')
            found = (line_start, line_end, value)
            i = line_end
            continue
        # Skip one other assignment, respecting multiline strings and arrays.
        depth = 0
        while i < len(text):
            c = text[i]
            if c in ('"', "'"):
                _, i = _string(text, i)
                continue
            if c == '#':
                end = text.find('\n', i)
                i = len(text) if end < 0 else end
                continue
            if c in '[{':
                depth += 1
            if c in ']}':
                depth -= 1
            i += 1
            if c == '\n' and depth == 0:
                break
        if i <= start:
            raise ValueError('Cannot parse config; left unchanged')
    return found


def _remove_hook_block(text):
    if BEGIN in text:
        start = text.index(BEGIN)
        stop = text.find(END, start)
        if stop < 0:
            raise ValueError('Incomplete Agent HUD hook block; left unchanged')
        text = text[:start] + text[stop + len(END):]
    # Migrate the old installer's unbounded trailing block only when every
    # line is recognisably ours. Never discard user additions after it.
    marker = '# Added by Agent HUD — remove this block to uninstall.'
    if marker in text:
        start = text.index(marker)
        tail = text[start + len(marker):]
        allowed = re.compile(r'^(?:\[\[hooks\.(?:SessionStart|UserPromptSubmit|Stop|PermissionRequest)(?:\.hooks)?\]\]|type = "command"|command = ".*agent-hud-codex"|timeout = 5000)$')
        if not all(not line.strip() or allowed.fullmatch(line.strip()) for line in tail.splitlines()):
            raise ValueError('Legacy Agent HUD hooks have user edits; move those edits outside the block first')
        text = text[:start]
    return text


def codex(path, forwarder, with_hooks=False, remove=False):
    path = Path(path)
    chain = path.parent / 'agent-hud-chain.json'
    saved = path.parent / 'agent-hud-install.json'
    text = path.read_text() if path.exists() else ''
    original = text
    text = _remove_hook_block(text) if remove or with_hooks else text
    span = notify_span(text)
    previous = span[2] if span else []
    is_ours = owns(' '.join(shlex.quote(a) for a in previous), 'agent-hud-codex')
    if remove:
        if is_ours:
            if saved.exists():
                stanza = json.loads(saved.read_text()).get('notify', '')
            elif chain.exists():
                old = json.loads(chain.read_text())
                if not isinstance(old, list) or not all(isinstance(x, str) for x in old):
                    raise ValueError('Invalid saved notify chain; left unchanged')
                stanza = 'notify = ' + json.dumps(old) + '\n' if old else ''
            else:
                raise ValueError('Missing saved notify chain; refusing to discard it')
            text = text[:span[0]] + stanza + text[span[1]:]
        if text != original:
            atomic_write(path, text)
        json_hooks(path.parent / 'hooks.json', forwarder, (), remove=True)
        if is_ours:
            for p in (chain, saved):
                if p.exists():
                    p.unlink()
        return
    replacement = 'notify = ' + json.dumps([str(Path(forwarder).resolve())]) + '\n'
    if not is_ours:
        # Persist the recovery information before switching the notification slot.
        atomic_write(chain, json.dumps(previous) + '\n', backup=False)
        atomic_write(saved, json.dumps({'notify': text[span[0]:span[1]] if span else ''}) + '\n', backup=False)
    if span:
        text = text[:span[0]] + replacement + text[span[1]:]
    else:
        text = replacement + text
    if with_hooks:
        block = ['\n' + BEGIN.rstrip()]
        command = shlex.quote(str(Path(forwarder).resolve()))
        for ev in CODEX_EVENTS:
            block += ['[[hooks.%s]]' % ev, '[[hooks.%s.hooks]]' % ev,
                      'type = "command"', 'command = ' + json.dumps(command), 'timeout = 3', '']
        text = text.rstrip() + '\n' + '\n'.join(block) + END
    if text != original:
        atomic_write(path, text)
