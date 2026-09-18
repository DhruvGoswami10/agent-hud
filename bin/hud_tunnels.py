#!/usr/bin/env python3
"""Keep explicitly configured reverse SSH tunnels alive; own only our children."""
import os
from pathlib import Path
import re
import signal
import subprocess
import threading

import hud_bootstrap as bootstrap


def main():
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, lambda *_: stop.set())
    children = {}
    try:
        while not stop.is_set():
            path = bootstrap.config_dir() / 'hosts.conf'
            hosts = [h.strip() for h in path.read_text().splitlines()] if path.exists() else []
            hosts = [h for h in hosts if re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.@:-]*', h)]
            for host in list(children):
                if host not in hosts or children[host].poll() is not None:
                    if children[host].poll() is None:
                        children[host].terminate()
                    children.pop(host)
            for host in hosts:
                if stop.is_set():
                    break
                try:
                    probe = bootstrap.ssh(host, 'curl -fsS -m 2 http://127.0.0.1:48085/health >/dev/null')
                    if probe.returncode == 0:
                        continue
                except subprocess.TimeoutExpired:
                    pass
                child = children.pop(host, None)
                if child and child.poll() is None:
                    child.terminate()
                    try: child.wait(timeout=3)
                    except subprocess.TimeoutExpired: child.kill()
                children[host] = subprocess.Popen(['ssh', '-n', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                    '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=3',
                    '-o', 'PermitLocalCommand=no', '-N', '-R', '48085:127.0.0.1:48085', '--', host],
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            stop.wait(60)
    finally:
        for child in children.values():
            if child.poll() is None:
                child.terminate()


if __name__ == '__main__':
    main()
