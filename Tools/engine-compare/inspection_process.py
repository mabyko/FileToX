"""Bounded, cancellable children for retained-artifact inspection (never host execution)."""
import os
from pathlib import Path
import selectors
import signal
import subprocess
import tempfile
import time

OUTPUT_LIMIT = 64 * 1024 * 1024


def bounded_command(args, timeout=60, output_limit=OUTPUT_LIMIT, cwd=None, scratch=None, watch=None):
    """Kill the whole child group on timeout, output overflow, SIGTERM or Ctrl-C.

    Children receive only a private home/tmp and this nonsecret allowlist. No user
    environment, plugin configuration, credentials or account data is inherited.
    """
    with tempfile.TemporaryDirectory(prefix="filetox-inspect-", dir=scratch) as folder:
        root = Path(folder)
        home, tmp = root / "home", root / "tmp"
        home.mkdir(); tmp.mkdir()
        watch = Path(watch) if watch is not None else root
        environment = {"HOME": str(home), "TMPDIR": str(tmp) + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                       "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"}
        proc = None
        previous = signal.getsignal(signal.SIGTERM)

        def cancelled(signum, frame):
            raise KeyboardInterrupt("Inspection cancelled")

        signal.signal(signal.SIGTERM, cancelled)
        try:
            proc = subprocess.Popen([str(x) for x in args], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, cwd=cwd or root, env=environment, start_new_session=True)
            buffers = {proc.stdout: bytearray(), proc.stderr: bytearray()}
            deadline, size, checked = time.monotonic() + timeout, 0, 0
            with selectors.DefaultSelector() as selector:
                for pipe in buffers: selector.register(pipe, selectors.EVENT_READ)
                while selector.get_map():
                    remaining = deadline - time.monotonic()
                    if remaining <= 0: raise subprocess.TimeoutExpired([str(x) for x in args], timeout)
                    if time.monotonic() - checked >= .1:
                        checked = time.monotonic()
                        total, count = 0, 0
                        for item in Path(watch).rglob("*"):
                            count += 1
                            if item.is_symlink(): raise RuntimeError("Inspection extraction contains a symlink")
                            try: total += item.stat().st_size if item.is_file() else 0
                            except FileNotFoundError: continue
                            if count > 4096 or total > output_limit:
                                raise RuntimeError("Inspection extracted output exceeds file/byte limit")
                    for key, _ in selector.select(min(remaining, .1)):
                        block = os.read(key.fileobj.fileno(), 65536)
                        if not block:
                            selector.unregister(key.fileobj)
                            continue
                        size += len(block)
                        if size > output_limit: raise RuntimeError("Inspection output exceeds byte limit")
                        buffers[key.fileobj].extend(block)
                try: proc.wait(timeout=max(.001, deadline - time.monotonic()))
                except subprocess.TimeoutExpired: raise subprocess.TimeoutExpired([str(x) for x in args], timeout)
            if proc.returncode:
                detail = buffers[proc.stderr].decode(errors="replace")[-2000:]
                raise RuntimeError(f"{Path(args[0]).name} exited {proc.returncode}: {detail}")
            return bytes(buffers[proc.stdout])
        finally:
            if proc is not None:
                # Descendants can outlive a successful leader or retain its output pipes.
                try: os.killpg(proc.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                proc.wait()
                proc.stdout.close(); proc.stderr.close()
            signal.signal(signal.SIGTERM, previous)
