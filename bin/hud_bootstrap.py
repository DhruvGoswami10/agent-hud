#!/usr/bin/env python3
"""Install or update the HUD reporter on one explicitly configured SSH host."""
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
from hud_config import atomic_write

FILES = ('agent-hud-send', 'agent-hud-payload.py', 'agent-hud-registry',
         'install-hooks.py', 'hud_config.py', 'agent-hud-codex', 'agent-hud-cursor')
OPTIONS = ['-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'PermitLocalCommand=no',
           '-o', 'ClearAllForwardings=yes']


def config_dir():
    candidates = [Path(os.environ['AGENT_HUD_ROOT'])] if os.environ.get('AGENT_HUD_ROOT') else []
    candidates += [Path.home() / 'Library/Application Support/AgentHUD', BIN.parent, Path.home() / 'agent-hud']
    return next((p for p in candidates if (p / 'hosts.conf').exists()), candidates[0])


def digest():
    h = hashlib.sha256()
    for name in FILES:
        h.update(name.encode() + b'\0' + (BIN / name).read_bytes())
    return h.hexdigest()


def ssh(host, command, **kwargs):
    return subprocess.run(['ssh', *OPTIONS, '--', host, command], timeout=40,
                          text=True, capture_output=True, **kwargs)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: agent-hud-bootstrap HOST')
    host = sys.argv[1]
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@:-]*', host):
        raise SystemExit('Invalid SSH host')
    root = config_dir()
    conf = root / 'hosts.conf'
    if not conf.exists() or not any(fnmatch.fnmatchcase(host, p.strip()) for p in conf.read_text().splitlines()
                                   if p.strip() and not p.lstrip().startswith('#')):
        raise SystemExit('Host is not listed in hosts.conf')
    version = digest()
    probe = ssh(host, 'cat "$HOME/agent-hud/.reporter-sha256" 2>/dev/null; pgrep -u "$(id -u)" -f "[a]gent-hud-registry" >/dev/null')
    if probe.returncode == 0 and probe.stdout.strip() == version:
        print(host + ': reporter already current')
        return
    directory = 'agent-hud/releases/' + version + '/bin'
    made = ssh(host, 'mkdir -p "$HOME/' + directory + '"')
    if made.returncode:
        raise SystemExit(host + ': could not create reporter directory')
    copied = subprocess.run(['scp', *OPTIONS, '-q', *[str(BIN / n) for n in FILES], host + ':' + directory + '/'], timeout=60)
    if copied.returncode:
        raise SystemExit(host + ': upload failed; existing reporter left running')
    # stdin script keeps process-control text out of the remote shell's argv.
    # Verify all bytes before atomically replacing any active script.
    update = '''import hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
root = pathlib.Path.home() / 'agent-hud'
version = sys.argv[1]
files = json.loads(sys.argv[2])
source = root / 'releases' / version / 'bin'
h = hashlib.sha256()
for name in files:
    h.update(name.encode() + b'\\0' + (source / name).read_bytes())
if h.hexdigest() != version:
    raise SystemExit('Reporter checksum mismatch')
bin = root / 'bin'
bin.mkdir(exist_ok=True)
for name in files:
    tmp = bin / (name + '.new')
    shutil.copyfile(source / name, tmp)
    tmp.chmod(0o755 if name.startswith('agent-hud-') else 0o644)
    os.replace(tmp, bin / name)
subprocess.run([sys.executable, str(bin / 'install-hooks.py'), str(bin / 'agent-hud-send')], check=True)
# Only same-user HUD reporters are restarted; agent sessions are untouched.
subprocess.run(['pkill', '-u', str(os.getuid()), '-f', '[a]gent-hud-registry'], check=False)
log = open(root / 'reporter.log', 'wb')
p = subprocess.Popen([sys.executable, str(bin / 'agent-hud-registry')], stdin=subprocess.DEVNULL,
                     stdout=subprocess.DEVNULL, stderr=log, start_new_session=True)
(root / '.reporter-sha256').write_text(version)
print('reporter updated; pid ' + str(p.pid))
'''
    import shlex
    result = ssh(host, 'python3 - ' + shlex.quote(version) + ' ' + shlex.quote(json.dumps(FILES)), input=update)
    if result.returncode:
        raise SystemExit(host + ': update failed: ' + result.stderr[-1000:])
    print(host + ': ' + result.stdout.strip())
    hostname = ssh(host, 'hostname -s')
    if hostname.returncode == 0 and hostname.stdout.strip():
        import fcntl
        root.mkdir(parents=True, exist_ok=True)
        with (root / '.hosts.lock').open('w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = root / 'hosts.json'
            aliases = json.loads(path.read_text()) if path.exists() else {}
            aliases[hostname.stdout.strip()] = host
            atomic_write(path, json.dumps(aliases, indent=2) + '\n', backup=False)


if __name__ == '__main__':
    try:
        main()
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise SystemExit('Agent HUD bootstrap: ' + str(error))
