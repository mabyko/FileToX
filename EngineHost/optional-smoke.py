#!/usr/bin/env python3
"""Exercise optional Filee engines and cancellation using isolated host state.

Usage: optional-smoke.py <FileToXEngine> <new work directory>
Reports actual sample conversions; it does not certify all format pairs.
"""
import hashlib
import json
import os
import pathlib
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import wave
import zipfile


def processes():
    text = subprocess.check_output(["ps", "-axo", "pid=,ppid=,pgid=,command="], text=True)
    return {int(fields[0]): {"pid": int(fields[0]), "parent": int(fields[1]),
                           "group": int(fields[2]), "command": fields[3]}
            for line in text.splitlines() if len(fields := line.strip().split(None, 3)) == 4}


def children(pid):
    table, found, frontier = processes(), [], [pid]
    while frontier:
        parent = frontier.pop()
        for entry in table.values():
            if entry["parent"] == parent:
                found.append(entry)
                frontier.append(entry["pid"])
    return found


class Host:
    def __init__(self, executable, work):
        self.work = work
        work.mkdir(parents=True, exist_ok=True)
        self.error_log = open(work / "stderr.log", "ab")
        environment = dict(os.environ, CALIBRE_CONFIG_DIRECTORY=str(work / "calibre-config"),
                           CALIBRE_CACHE_DIRECTORY=str(work / "calibre-cache"),
                           CALIBRE_TEMP_DIR=str(work / "calibre-temp"))
        self.proc = subprocess.Popen([str(executable), "--data", str(work / "core"), "--lang", "en"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.error_log,
                                     env=environment, start_new_session=True)
        self.messages, self.condition, self.sequence, self.reader_error = [], threading.Condition(), 0, None
        threading.Thread(target=self.read, daemon=True).start()
        try:
            self.wait(lambda message: message.get("event") == "hello", 60)
        except Exception:
            self.close()
            raise

    def read(self):
        try:
            for raw in self.proc.stdout:
                message = json.loads(raw)
                with self.condition:
                    self.messages.append(message)
                    self.condition.notify_all()
        except Exception as error:
            self.reader_error = repr(error)
        finally:
            with self.condition:
                self.condition.notify_all()

    def wait(self, predicate, timeout=180):
        end = time.monotonic() + timeout
        with self.condition:
            while True:
                for message in self.messages:
                    if predicate(message):
                        return message
                if self.reader_error:
                    raise RuntimeError(self.reader_error)
                if self.proc.poll() is not None:
                    raise RuntimeError(f"Host exited {self.proc.returncode}: {self.work / 'stderr.log'}")
                if time.monotonic() >= end:
                    raise TimeoutError(f"Host response timed out: {self.work}")
                self.condition.wait(0.1)

    def call(self, method, **params):
        self.sequence += 1
        identifier = str(self.sequence)
        request = {"v": 1, "id": identifier, "method": method, "params": params}
        self.proc.stdin.write((json.dumps(request) + "\n").encode())
        self.proc.stdin.flush()
        response = self.wait(lambda message: message.get("id") == identifier)
        if "error" in response:
            raise RuntimeError(f"{method}: {response['error']}")
        return response["result"]

    def start(self, path, target):
        return self.call("job.start", paths=[str(path)], targetFormat=target)["jobId"]

    def finish(self, job):
        return self.wait(lambda message: message.get("event") == "job.finished"
                         and message["data"]["jobId"] == job)["data"]

    def convert(self, path, target):
        result = self.finish(self.start(path, target))
        outputs = [pathlib.Path(output["path"]) for file in result["files"] for output in file.get("outputs", [])]
        assert result["state"] == "completed" and len(outputs) == 1, result
        assert outputs[0].is_file() and outputs[0].stat().st_size > 0, result
        return outputs[0], result

    def configure(self, engines, first=None):
        library = self.call("library.get")
        settings = library["settings"]
        settings["engineOwnCopies"].update({key: str(value) for key, value in engines.items()})
        if first:
            settings["enginePriority"] = [first] + [engine for engine in settings["enginePriority"] if engine != first]
        return self.call("settings.save", baseRevision=library["revision"], settings=settings)

    def close(self):
        if self.proc.poll() is None:
            self.proc.stdin.close()
            try:
                self.proc.wait(15)
            except subprocess.TimeoutExpired:
                os.killpg(self.proc.pid, signal.SIGKILL)
                self.proc.wait(5)
        self.error_log.close()


def run(arguments, timeout=60):
    return subprocess.check_output([str(value) for value in arguments], stderr=subprocess.STDOUT,
                                   timeout=timeout, text=True)


def probe(ffprobe, path, video=False, duration=3):
    data = json.loads(run([ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))
    types = [stream["codec_type"] for stream in data["streams"]]
    assert "audio" in types and ("video" in types) == video, data
    assert abs(float(data["format"]["duration"]) - duration) < 0.5, data
    return {"duration": data["format"]["duration"],
            "streams": [{key: stream.get(key) for key in ["codec_type", "codec_name", "width", "height", "sample_rate"]}
                        for stream in data["streams"]]}


def epub(path):
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr("book.opf", '<?xml version="1.0"?><package version="2.0" unique-identifier="id" xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>FileToX optional smoke</dc:title><dc:language>en</dc:language><dc:identifier id="id">urn:uuid:filetox-smoke</dc:identifier><dc:creator>FileToX</dc:creator></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="chapter"/></spine></package>')
        archive.writestr("chapter.xhtml", '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Smoke</title></head><body><h1>FileToX smoke</h1><p>Conversion content survives.</p></body></html>')


def wait_engine(host, name, job, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        active = [entry for entry in children(host.proc.pid) if name in pathlib.Path(entry["command"].split()[0]).name]
        if active:
            return active
        if any(message.get("event") == "job.finished" and message["data"]["jobId"] == job
               for message in host.messages):
            raise AssertionError(f"Job finished before observing {name}")
        time.sleep(0.05)
    raise TimeoutError(f"No actual {name} process observed")


def gone(pids, group=None, timeout=10):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        table = processes()
        remaining = [entry for pid, entry in table.items() if pid in pids or (group and entry["group"] == group)]
        if not remaining:
            return []
        time.sleep(0.1)
    return remaining


def main():
    if len(sys.argv) == 2 and sys.argv[1] in ["-h", "--help"]:
        print(__doc__.strip())
        return 0
    if len(sys.argv) != 3:
        print("Usage: optional-smoke.py <FileToXEngine> <new work directory>", file=sys.stderr)
        return 2
    executable, work = pathlib.Path(sys.argv[1]).resolve(), pathlib.Path(sys.argv[2]).resolve()
    assert not work.exists(), "Choose a new work directory to avoid changing an earlier report"
    work.mkdir(parents=True)
    files = work / "files"
    files.mkdir()
    engine_root = pathlib.Path(__file__).resolve().parents[1] / "build/optional-engines/osx-arm64"
    candidates = {"pandoc": engine_root / "pandoc/bin/pandoc",
                  "libreoffice": engine_root / "libreoffice/LibreOffice.app/Contents/MacOS/soffice",
                  "calibre": engine_root / "calibre/calibre.app/Contents/MacOS/ebook-convert"}
    for name in ["ffmpeg", "ffprobe"]:
        if found := shutil.which(name):
            candidates[name] = pathlib.Path(found)
    engines = {name: path for name, path in candidates.items() if path.is_file() and name != "ffprobe"}
    report = {"host": str(executable), "work": str(work), "enginePaths": {key: str(value) for key, value in engines.items()},
              "cases": [], "unavailableEngines": {}, "scope": "Actual sample conversions only; not all format pairs"}
    log = open(work / "results.log", "w")

    def case(name, action):
        try:
            detail = action()
            result = {"name": name, "passed": True, "detail": detail}
        except Exception as error:
            result = {"name": name, "passed": False, "error": repr(error)}
        report["cases"].append(result)
        text = json.dumps(result, ensure_ascii=False)
        print(("PASS " if result["passed"] else "FAIL ") + name + (" " + result["error"] if "error" in result else ""), flush=True)
        print(text, file=log, flush=True)
        (work / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        return result

    host = None
    try:
        host = Host(executable, work / "primary")
        host.configure(engines)
        catalog = host.call("catalog.get")
        available = {entry["id"] for entry in catalog["engines"] if entry["available"]}
        report["unavailableEngines"] = {entry["id"]: {"reasonKey": entry.get("reasonKey"), "detail": entry.get("detail")}
                                        for entry in catalog["engines"] if not entry["available"]}

        def converted(path, target, validate):
            original = hashlib.sha256(path.read_bytes()).hexdigest()
            output, result = host.convert(path, target)
            detail = validate(output)
            assert hashlib.sha256(path.read_bytes()).hexdigest() == original, "Source changed"
            return {"output": str(output), "validation": detail, "job": result}

        def archive_check(path, member, text):
            with zipfile.ZipFile(path) as archive:
                content = archive.read(member).decode("utf-8")
                assert text in content, content[:500]
                return {"member": member, "contains": text}

        def pdf_check(path):
            assert path.read_bytes().startswith(b"%PDF-"), "Missing PDF signature"
            text, _ = host.convert(path, "txt")
            assert "LibreOffice content survives" in text.read_text(), "PDF text content was lost"
            return {"pdf": True, "parsedTextContains": "LibreOffice content survives"}

        if "pandoc" in available:
            rst = files / "Pandoc sample.rst"
            rst.write_text("Optional smoke\n==============\n\nPandoc preserves **sample content**.\n")
            case("Pandoc RST→DOCX actual content", lambda: converted(rst, "docx", lambda path: archive_check(path, "word/document.xml", "sample content")))

        if "pandoc" in available:
            def pandoc_media():
                # Pandoc's extracted media is staged with the output: it lands next to the Markdown file, linked
                # relatively, and a media folder in the way stops the conversion before anything is published.
                import base64, re
                source = files / "media source"
                source.mkdir()
                (source / "pic.png").write_bytes(base64.b64decode(
                    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
                (source / "doc.md").write_text("# Title\n\n![alt](pic.png)\n")
                docx, _ = host.convert(source / "doc.md", "docx")
                folder = files / "media docx"
                folder.mkdir()
                moved = folder / "doc.docx"
                shutil.move(docx, moved)
                original = hashlib.sha256(moved.read_bytes()).hexdigest()

                md, _ = host.convert(moved, "md")
                link = re.search(r"\(?(?:src=\")?(doc_files/[^\")]+)", md.read_text())
                assert md == folder / "doc.md" and link and (folder / link.group(1)).is_file(), md.read_text()
                assert not [p for p in folder.rglob(".filee-out-*")], "staging folder left"

                md.unlink()
                shutil.rmtree(folder / "doc_files" / "media")
                (folder / "doc_files" / "media").mkdir()
                theirs = folder / "doc_files" / "media" / "mine.txt"
                theirs.write_text("mine")
                result = host.finish(host.start(moved, "md"))
                keys = [file["errorKey"] for file in result["files"]]
                assert result["state"] == "failed" and keys == ["error.output_exists"], result
                assert not (folder / "doc.md").exists() and theirs.read_text() == "mine"
                assert [p.name for p in (folder / "doc_files").iterdir()] == ["media"], "media folder was changed"
                assert not [p for p in folder.rglob(".filee-out-*")], "staging folder left"
                assert hashlib.sha256(moved.read_bytes()).hexdigest() == original, "Source changed"
                return {"link": link.group(1)}
            case("Pandoc DOCX→Markdown media is staged and conflicts publish nothing", pandoc_media)

        if "libreoffice" in available:
            host.configure(engines, first="libreoffice")
            rtf = files / "LibreOffice sample.rtf"
            rtf.write_text(r"{\rtf1\ansi Optional smoke\par LibreOffice content survives.}")
            case("LibreOffice RTF→ODT actual content", lambda: converted(rtf, "odt", lambda path: archive_check(path, "content.xml", "LibreOffice content survives")))
            case("LibreOffice RTF→PDF parsed text content", lambda: converted(rtf, "pdf", pdf_check))

            def cancel_libreoffice():
                large = files / "LibreOffice cancellation.rtf"
                large.write_text(r"{\rtf1\ansi " + (r"Long document content for active cancellation.\par " * 100000) + "}")
                original = hashlib.sha256(large.read_bytes()).hexdigest()
                before = {path.name for path in files.iterdir()}
                job = host.start(large, "odt")
                actual = wait_engine(host, "soffice", job)
                time.sleep(0.2)
                actual = children(host.proc.pid)
                assert any("soffice" in entry["command"] for entry in actual), "LibreOffice already exited"
                host.call("job.cancel", jobId=job)
                result = host.finish(job)
                remaining = gone([entry["pid"] for entry in actual])
                assert not remaining, remaining
                assert hashlib.sha256(large.read_bytes()).hexdigest() == original, "Source changed"
                outputs = [pathlib.Path(output["path"]) for file in result["files"] for output in file.get("outputs", [])]
                if result["state"] == "completed":
                    assert len(outputs) == 1, result
                    archive_check(outputs[0], "content.xml", "Long document content")
                else:
                    assert result["state"] == "cancelled" and not outputs, result
                    assert {path.name for path in files.iterdir()} == before, "Cancelled LibreOffice output/staging remains"
                assert not list(files.rglob(".filee-out-*")), "LibreOffice staging remains"
                return {"observedProcesses": actual, "state": result["state"], "outputs": [str(path) for path in outputs],
                        "childrenGone": True, "sourcePreserved": True}

            case("G5 cancel actual active LibreOffice and clean output", cancel_libreoffice)
            host.configure(engines)

        if "calibre" in available:
            book = files / "Calibre sample.epub"
            epub(book)

            def mobi_check(path):
                assert path.read_bytes()[60:68] == b"BOOKMOBI", "Missing MOBI database signature"
                return {"signature": "BOOKMOBI", "bytes": path.stat().st_size}

            case("Calibre EPUB→MOBI actual book", lambda: converted(book, "mobi", mobi_check))

        if "ffmpeg" in available and "ffprobe" in candidates:
            ffmpeg, ffprobe = candidates["ffmpeg"], candidates["ffprobe"]
            clip = files / "영상 sample.mp4"
            run([ffmpeg, "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30",
                 "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "3", "-c:v", "libx264",
                 "-preset", "ultrafast", "-c:a", "aac", clip])
            case("FFmpeg MP4→MP3 duration/audio", lambda: converted(clip, "mp3", lambda path: probe(ffprobe, path)))
            case("FFmpeg MP4→MP4 duration/video/audio", lambda: converted(clip, "mp4", lambda path: probe(ffprobe, path, video=True)))
            wav = files / "tone.wav"
            with wave.open(str(wav), "wb") as audio:
                audio.setparams((1, 2, 44100, 44100 * 3, "NONE", "not compressed"))
                import math
                audio.writeframes(b"".join(struct.pack("<h", int(10000 * math.sin(index * 2 * math.pi * 440 / 44100))) for index in range(44100 * 3)))
            case("FFmpeg WAV→M4A duration/audio", lambda: converted(wav, "m4a", lambda path: probe(ffprobe, path)))
            long_clip = files / "long cancellation.mp4"
            run([ffmpeg, "-v", "error", "-stream_loop", "59", "-i", clip, "-c", "copy", long_clip])
            initial = hashlib.sha256(long_clip.read_bytes()).hexdigest()

            def cancel_active():
                before = {path.name for path in files.iterdir()}
                job = host.start(long_clip, "mp4")
                actual = wait_engine(host, "ffmpeg", job)
                host.call("job.cancel", jobId=job)
                result = host.finish(job)
                assert result["state"] == "cancelled", result
                assert not gone([entry["pid"] for entry in actual]), "Encoder child survived job.cancel"
                assert {path.name for path in files.iterdir()} == before, "Cancelled output/staging remains"
                assert hashlib.sha256(long_clip.read_bytes()).hexdigest() == initial, "Source changed"
                return {"observedProcesses": actual, "job": result, "childrenGone": True, "sourcePreserved": True}

            case("G5 cancel actual active FFmpeg and clean output", cancel_active)

            def kill_group():
                before = {path.name for path in files.iterdir()}
                isolated = Host(executable, work / "group-exit")
                try:
                    isolated.configure(engines)
                    job = isolated.start(long_clip, "mp4")
                    actual = wait_engine(isolated, "ffmpeg", job)
                    os.killpg(isolated.proc.pid, signal.SIGTERM)
                    isolated.proc.wait(15)
                    residual = gone([entry["pid"] for entry in actual], group=isolated.proc.pid)
                    assert not residual, residual
                finally:
                    isolated.close()
                restarted = Host(executable, work / "group-exit")
                try:
                    restarted.call("catalog.get")
                    leftovers = [str(path) for path in files.rglob(".filee-out-*")]
                    assert not leftovers, leftovers
                    assert {path.name for path in files.iterdir()} == before, "Interrupted final output remains"
                    assert hashlib.sha256(long_clip.read_bytes()).hexdigest() == initial, "Source changed"
                finally:
                    restarted.close()
                return {"observedProcesses": actual, "groupGone": True, "restartHasNoStaging": True,
                        "sourcePreserved": True, "noInterruptedOutput": True}

            case("G5 terminate host process group with active encoder", kill_group)

        leftovers = [str(path) for path in files.rglob(".filee-out-*")]
        report["stagingLeftovers"] = leftovers
        assert not leftovers, leftovers
    except Exception as error:
        report["fatal"] = repr(error)
        print(f"FATAL {error!r}", file=log, flush=True)
    finally:
        if host:
            host.close()
        report["passed"] = bool(report["cases"]) and all(case["passed"] for case in report["cases"]) and "fatal" not in report
        (work / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        output = pathlib.Path(__file__).resolve().parents[1] / "build"
        (output / "optional-smoke-results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
        summary = {key: report.get(key) for key in ["host", "work", "passed", "unavailableEngines", "stagingLeftovers", "fatal"]}
        summary["cases"] = [{key: case[key] for key in ["name", "passed", "error"] if key in case} for case in report["cases"]]
        (output / "optional-smoke-summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
        shutil.copyfile(work / "results.log", output / "optional-smoke-results.log")
        log.close()
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
