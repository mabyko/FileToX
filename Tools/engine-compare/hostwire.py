#!/usr/bin/env python3
"""Strict, isolated host-wire-v1 client. No Filee implementation dependencies."""
import copy
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import threading
import time

MAX_LINE = 4 * 1024 * 1024


class ProtocolError(RuntimeError):
    pass


class RPCError(RuntimeError):
    def __init__(self, method, error):
        self.error = error
        super().__init__(f"{method}: {error}")


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True,
                                    allow_nan=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def add_host_arguments(parser):
    parser.add_argument("--host", required=True, type=Path)
    parser.add_argument("--optional-root", type=Path,
                        help="Root containing pandoc/, libreoffice/, calibre/ dev copies")
    parser.add_argument("--own-copy", action="append", default=[], metavar="PACKAGE=PATH")


def own_copies(args):
    result = {}
    if args.optional_root:
        root = args.optional_root.resolve(strict=True)
        for name in ("pandoc", "libreoffice", "calibre"):
            result[name] = str((root / name).resolve(strict=True))
    for entry in args.own_copy:
        name, separator, path = entry.partition("=")
        if not separator or not name:
            raise ValueError("--own-copy must be PACKAGE=PATH")
        result[name] = str(Path(path).resolve(strict=True))
    return result


class Host:
    """One process with fresh core, engine-download, temp and Calibre state.

    Requests are serialized; the reader independently drains stdout, retaining fast
    job.finished events that arrive before the caller begins waiting for them.
    """
    def __init__(self, executable, *, copies=None, stderr_path=None, timeout=120, scratch=None):
        self.timeout = timeout
        self.temporary = tempfile.TemporaryDirectory(prefix="hostwire-", dir=scratch)
        self.root = Path(self.temporary.name).resolve()
        for name in ("core", "engines", "tmp", "calibre-config", "calibre-cache", "calibre-temp"):
            (self.root / name).mkdir()
        self.stderr_path = Path(stderr_path) if stderr_path else self.root / "stderr.log"
        self.stderr_path.parent.mkdir(parents=True, exist_ok=True)
        self._stderr = self.stderr_path.open("ab")
        self.condition = threading.Condition()
        self.serial = threading.Lock()
        self.responses, self.finished, self.pending = {}, {}, set()
        self.received_finished = set()
        self.sequence, self.failure, self.eof, self.closed = 0, None, False, False
        self.hello = None
        environment = dict(os.environ, TMPDIR=str(self.root / "tmp") + "/",
                           CALIBRE_CONFIG_DIRECTORY=str(self.root / "calibre-config"),
                           CALIBRE_CACHE_DIRECTORY=str(self.root / "calibre-cache"),
                           CALIBRE_TEMP_DIR=str(self.root / "calibre-temp"))
        try:
            self.proc = subprocess.Popen(
                [str(Path(executable).resolve(strict=True)), "--data", str(self.root / "core"),
                 "--engines", str(self.root / "engines"), "--lang", "en"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._stderr,
                env=environment, start_new_session=True)
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
            self._wait(lambda: self.hello, timeout, "hello")
            if self.hello.get("protocol") != 1:
                raise ProtocolError(f"Unsupported hello: {self.hello}")
            if copies:
                self.configure(copies)
        except BaseException:
            self.close(check=False)
            raise

    def _read(self):
        try:
            while raw := self.proc.stdout.readline(MAX_LINE + 2):
                if len(raw) > MAX_LINE + 1 or not raw.endswith(b"\n"):
                    raise ProtocolError("Oversize or unterminated stdout line")
                try:
                    message = json.loads(raw.decode("utf-8"),
                                         parse_constant=lambda x: (_ for _ in ()).throw(ValueError(x)))
                except (ValueError, UnicodeError) as error:
                    raise ProtocolError(f"Non-JSON stdout: {raw[:200]!r}") from error
                if not isinstance(message, dict) or type(message.get("v")) is not int or message["v"] != 1:
                    raise ProtocolError(f"Invalid envelope: {message!r}")
                with self.condition:
                    if "event" in message:
                        event, data = message["event"], message.get("data")
                        if not isinstance(data, dict):
                            raise ProtocolError("Event data must be an object")
                        if event == "fatal":
                            raise ProtocolError(f"Host fatal: {data}")
                        if event == "hello":
                            if self.hello is not None:
                                raise ProtocolError("Duplicate hello")
                            self.hello = data
                        elif event == "job.finished":
                            job = data.get("jobId")
                            if not isinstance(job, str) or job in self.received_finished:
                                raise ProtocolError("Invalid/duplicate job.finished")
                            self.received_finished.add(job)
                            self.finished[job] = data
                        elif event != "job.updated":
                            raise ProtocolError(f"Unknown event: {event}")
                    else:
                        rid = message.get("id")
                        if rid not in self.pending or rid in self.responses:
                            raise ProtocolError(f"Unknown/duplicate response id: {rid!r}")
                        if ("result" in message) == ("error" in message):
                            raise ProtocolError("Response must have exactly one of result/error")
                        self.responses[rid] = message
                    self.condition.notify_all()
        except BaseException as error:
            with self.condition:
                self.failure = error
        finally:
            with self.condition:
                self.eof = True
                self.condition.notify_all()

    def _wait(self, getter, timeout, description):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                if self.failure:
                    raise self.failure
                value = getter()
                if value is not None:
                    return value
                if self.eof:
                    raise ProtocolError(f"Host EOF waiting for {description}; see {self.stderr_path}")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"Timed out waiting for {description}")
                self.condition.wait(remaining)

    def call(self, method, *, timeout=None, **params):
        with self.serial:
            with self.condition:
                self.sequence += 1
                rid = str(self.sequence)
                self.pending.add(rid)
            raw = (json.dumps({"v": 1, "id": rid, "method": method, "params": params},
                              ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
            if len(raw) > MAX_LINE + 1:
                raise ValueError("Request exceeds host-wire-v1 line limit")
            self.proc.stdin.write(raw)
            self.proc.stdin.flush()
            message = self._wait(lambda: self.responses.get(rid), timeout or self.timeout, method)
            with self.condition:
                self.pending.remove(rid)
                del self.responses[rid]
            if "error" in message:
                raise RPCError(method, message["error"])
            return message["result"]

    def configure(self, copies=None, first=None):
        library = self.call("library.get")
        settings = copy.deepcopy(library["settings"])
        settings["engineOwnCopies"].update(copies or {})
        if first:
            settings["enginePriority"] = [first] + [e for e in settings["enginePriority"] if e != first]
        return self.call("settings.save", baseRevision=library["revision"], settings=settings)

    def finish(self, job_id, timeout=180):
        result = self._wait(lambda: self.finished.get(job_id), timeout, f"job.finished {job_id}")
        with self.condition:
            del self.finished[job_id]
        return result

    def convert(self, paths, *, timeout=180, **how):
        job_id = self.call("job.start", paths=[str(Path(p).resolve()) for p in paths], **how)["jobId"]
        try:
            return self.finish(job_id, timeout)
        except TimeoutError:
            self.call("job.cancel", jobId=job_id)
            try:
                self.finish(job_id, 10)
            except (TimeoutError, ProtocolError):
                self.close(check=False)
            raise

    def close(self, check=True):
        if self.closed:
            return
        self.closed = True
        proc = getattr(self, "proc", None)
        if proc:
            if proc.stdin and not proc.stdin.closed:
                try:
                    proc.stdin.close()
                except BrokenPipeError:
                    pass
            try:
                proc.wait(7)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(5)
            if hasattr(self, "reader"):
                self.reader.join(2)
            proc.stdout.close()
        self._stderr.close()
        self.temporary.cleanup()
        if check and (self.failure or (proc and proc.returncode)):
            raise self.failure or ProtocolError(f"Host exit status {proc.returncode}")

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        self.close(check=kind is None)
