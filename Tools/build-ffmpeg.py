#!/usr/bin/env python3
"""Build FileToX's required FFmpeg codecs in a new folder; never install into Homebrew or the user's system.

Requires native Apple Silicon, Xcode command-line tools, Python 3, CMake and pkg-config.
Example: python3 Tools/build-ffmpeg.py --work build/ffmpeg --jobs 6
Xcode bundles build/ffmpeg/ffmpeg (or FILETOX_FFMPEG_BUNDLE). Publish the binary ZIP
and the accompanying sources ZIP together when a release is actually intended.
"""
import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import tarfile
import tempfile
import zipfile

X264 = "b35605ace3ddf7c1a5d67a2eb553f034aef41d55"
# Xiph publishes SHA256SUMS; the FFmpeg/OpenCORE pins also match Homebrew's source recipes.
PINS = [
    ("libogg", "1.3.6", "https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz", "5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061"),
    ("libvorbis", "1.3.7", "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz", "b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b"),
    ("libtheora", "1.2.0", "https://downloads.xiph.org/releases/theora/libtheora-1.2.0.tar.xz", "ebdf77a8f5c0a8f7a9e42323844fa09502b34eb1d1fece7b5f54da41fe2122ec"),
    ("lame", "3.100", "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz", "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e"),
    ("opus", "1.6.1", "https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz", "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"),
    ("opencore-amr", "0.1.6", "https://downloads.sourceforge.net/project/opencore-amr/opencore-amr/opencore-amr-0.1.6.tar.gz", "483eb4061088e2b34b358e47540b5d495a96cd468e361050fae615b1809dc4a1"),
    ("libvpx", "1.17.0", "https://github.com/webmproject/libvpx/archive/refs/tags/v1.17.0.tar.gz", "1020f184046187baa2985dbde38e0691f49c44088bca7a1842b0236c6081dc0a"),
    ("x264", X264, f"https://code.videolan.org/videolan/x264/-/archive/{X264}/x264-{X264}.tar.bz2", "6eeb82934e69fd51e043bd8c5b0d152839638d1ce7aa4eea65a3fedcf83ff224"),
    ("libaom", "3.14.1", "https://storage.googleapis.com/aom-releases/libaom-3.14.1.tar.gz", "44bf90dbd23e734d50e70a8c41c285193922938bd0d3bc2ee56764d181d55ef5"),
    ("ffmpeg", "9.0.2", "https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz", "8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e"),
]
ENCODERS = set("libopencore_amrnb libvorbis libtheora libx264 libvpx-vp9 libmp3lame libopus aac wmv2 wmav2 mpeg4 mpeg2video mp2 ac3 dvvideo pcm_s16le pcm_s16be pcm_u8 pcm_s24le pcm_s32le pcm_f32le flac png gif wrapped_avframe".split())
MUXERS = set("mp4 mov matroska flv mpegts 3gp 3g2 webm avi asf vob dvd ogg dv mxf mp3 ipod adts wav flac opus aiff ac3 amr au caf mp2 voc image2 gif null ffmetadata".split())
DECODERS = {"libaom-av1"}


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def check_hash(path, expected):
    if sha(path) != expected:
        raise ValueError("Source SHA-256 mismatch: " + str(path))


def unpack(archive, destination):
    """The pinned sources contain only files/directories; validate the whole tree before writing."""
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        paths = [PurePosixPath(member.name) for member in members]
        if not members or len({path.parts[0] for path in paths if path.parts}) != 1:
            raise ValueError("Expected one source directory")
        for member, path in zip(members, paths):
            if not path.parts or path.is_absolute() or ".." in path.parts or "\\" in member.name or ":" in member.name:
                raise ValueError("Unsafe source path: " + member.name)
            if not (member.isdir() or member.isfile()):
                raise ValueError("Source links and special files are not allowed: " + member.name)
        destination.mkdir()
        for member, path in zip(members, paths):
            target = destination.joinpath(*path.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)
                target.chmod(member.mode & 0o755)
    root = destination / paths[0].parts[0]
    if not root.is_dir():
        raise ValueError("Source root is not a directory")
    return root


def listed(text, encoder):
    result = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 2 or fields[1] == "=":
            continue
        flags = fields[0]
        if (encoder and len(flags) == 6 and flags[0] in "VAS") or (not encoder and len(flags) <= 3 and "E" in flags):
            result.update(fields[1].split(","))
    return result


def verify_bundle(folder):
    folder = folder.resolve(strict=True)
    if set(path.name for path in folder.iterdir()) - {"bin", "LICENSES", "PROVENANCE.json", "BUILDING.txt"}:
        raise ValueError("Unexpected files in FFmpeg bundle")
    if set(path.name for path in (folder / "bin").iterdir()) != {"ffmpeg", "ffprobe"}:
        raise ValueError("Unexpected FFmpeg executables")
    if any(path.is_symlink() for path in folder.rglob("*")):
        raise ValueError("FFmpeg bundle must not contain symbolic links")
    provenance = json.loads((folder / "PROVENANCE.json").read_text())
    if (provenance["version"], provenance["runtime"], provenance["minimumMacOS"]) != ("9.0.2", "osx-arm64", "15.0"):
        raise ValueError("Unexpected FFmpeg bundle version or platform")
    if [tuple(source[key] for key in ("name", "version", "url", "sha256")) for source in provenance["sources"]] != PINS:
        raise ValueError("FFmpeg source pins do not match this build recipe")
    for name in ("ffmpeg", "ffprobe"):
        program = folder / "bin" / name
        if program.is_symlink() or not program.is_file() or not program.stat().st_mode & 0o111:
            raise ValueError("Expected a regular executable: " + str(program))
        check_hash(program, provenance["programs"][name]["sha256"])
    for name, *_ in PINS:
        if not any(path.is_file() for path in (folder / "LICENSES" / name).rglob("*")):
            raise ValueError("FFmpeg license notices are missing: " + name)


def build(work, jobs, source_cache):
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Build natively on Apple Silicon")
    if not 1 <= jobs <= 32:
        raise ValueError("--jobs must be between 1 and 32")
    work = work.resolve()
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", str(work)):
        raise ValueError("Autotools requires a build path without spaces or shell metacharacters")
    pkg_config = shutil.which("pkg-config")
    cmake = shutil.which("cmake")
    if not pkg_config or not cmake:
        raise ValueError("CMake and pkg-config are required; no tools are installed by this script")
    work.mkdir(parents=True, exist_ok=False)
    for folder in ("home", "tmp", "archives", "sources", "logs", "prefix", "ffmpeg/bin", "ffmpeg/LICENSES"):
        (work / folder).mkdir(parents=True)
    prefix, payload = work / "prefix", work / "ffmpeg"
    flags = "-O2 -fPIC -arch arm64 -mmacosx-version-min=15.0"
    env = {"HOME": str(work / "home"), "TMPDIR": str(work / "tmp") + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "MACOSX_DEPLOYMENT_TARGET": "15.0",
           "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++", "CFLAGS": flags, "CXXFLAGS": flags,
           "CPPFLAGS": "-I" + str(prefix / "include"), "LDFLAGS": "-arch arm64 -mmacosx-version-min=15.0 -L" + str(prefix / "lib"),
           "PKG_CONFIG": pkg_config, "PKG_CONFIG_PATH": "", "PKG_CONFIG_LIBDIR": str(prefix / "lib/pkgconfig"),
           "PKG_CONFIG_ALLOW_SYSTEM_CFLAGS": "1", "PKG_CONFIG_ALLOW_SYSTEM_LIBS": "1"}
    if "DEVELOPER_DIR" in os.environ:
        env["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
    commands, sources = [], []

    def run(command, folder, label, environment=None):
        command = [str(value) for value in command]
        commands.append(dict(command=command, cwd=str(folder)))
        print(label, flush=True)
        with (work / "logs" / (label + ".log")).open("wb") as log:
            result = subprocess.run(command, cwd=folder, env=environment or env, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        if result.returncode:
            raise RuntimeError(f"{label} exited {result.returncode}; see {work / 'logs' / (label + '.log')}")

    def output(command):
        return subprocess.check_output([str(value) for value in command], cwd=work, env=env, text=True, stderr=subprocess.STDOUT, timeout=30)

    for name, version, url, expected in PINS:
        suffix = ".tar." + url.rsplit(".", 1)[1]
        archive = work / "archives" / (name + "-" + version + suffix)
        cached = source_cache / archive.name if source_cache else None
        if cached and cached.is_file():
            check_hash(cached, expected)
            shutil.copy2(cached, archive)
        else:
            run(["/usr/bin/curl", "--fail", "--location", "--proto", "=https", "--retry", "1", "--max-time", "300", "--output", archive, url], work, name + "-download")
        check_hash(archive, expected)
        source = unpack(archive, work / "sources" / name)
        source_record = dict(name=name, version=version, url=url, sha256=expected, archive=archive.name)
        sources.append(source_record)
        for license_file in sorted(source.rglob("*")):
            if license_file.is_file() and (license_file.name in ("COPYING", "LICENSE", "LICENSE.md", "NOTICE", "PATENTS", "AUTHORS") or license_file.name.startswith("COPYING.")):
                target = payload / "LICENSES" / name / license_file.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(license_file, target)
        if name == "libvorbis":
            # Upstream's old Darwin flag is rejected by Apple's arm64 compiler (same patch as Homebrew).
            configure = source / "configure"
            configure.write_text(configure.read_text().replace(" -force_cpusubtype_ALL", ""))
            source_record["patch"] = "Remove obsolete -force_cpusubtype_ALL from configure"
        build_env = dict(env)
        if name == "libaom":
            build_dir = work / "aom-build"
            configure = [cmake, "-S", source, "-B", build_dir, "-DCMAKE_INSTALL_PREFIX=" + str(prefix),
                         "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
                         "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                         "-DCONFIG_AV1_ENCODER=0", "-DCONFIG_AV1_DECODER=1", "-DCONFIG_RUNTIME_CPU_DETECT=1",
                         "-DENABLE_DOCS=OFF", "-DENABLE_EXAMPLES=OFF", "-DENABLE_TESTS=OFF", "-DENABLE_TOOLS=OFF"]
            source_record["configure"] = [str(value) for value in configure]
            run(configure, work, name + "-configure")
            run([cmake, "--build", build_dir, "--parallel", str(jobs)], work, name + "-make")
            run([cmake, "--install", build_dir], work, name + "-install")
            continue
        if name == "x264":
            options = ["--enable-static", "--enable-pic", "--disable-cli", "--disable-opencl"]
        elif name == "libvpx":
            options = ["--target=arm64-darwin24-gcc", "--disable-shared", "--enable-static", "--enable-pic", "--disable-examples",
                       "--disable-tools", "--disable-docs", "--disable-unit-tests", "--enable-runtime-cpu-detect", "--enable-vp9-highbitdepth"]
        elif name == "ffmpeg":
            options = ["--arch=arm64", "--target-os=darwin", "--cc=/usr/bin/clang", "--cxx=/usr/bin/clang++",
                       "--pkg-config=" + pkg_config, "--pkg-config-flags=--static", "--enable-static", "--disable-shared", "--disable-autodetect",
                       "--disable-doc", "--disable-debug", "--disable-ffplay", "--enable-gpl", "--enable-version3", "--enable-zlib", "--enable-iconv",
                       "--extra-cflags=" + flags + " -I" + str(prefix / "include"), "--extra-ldflags=" + env["LDFLAGS"], "--extra-libs=-liconv",
                       "--enable-libaom", "--disable-encoder=libaom_av1",
                       "--enable-libopencore-amrnb", "--enable-libvorbis", "--enable-libtheora", "--enable-libx264", "--enable-libvpx", "--enable-libmp3lame", "--enable-libopus"]
        else:
            options = ["--disable-shared", "--enable-static", "--disable-dependency-tracking"]
            if name == "lame":
                options += ["--disable-frontend"]
                build_env["CFLAGS"] += " -std=gnu11 -Wno-implicit-function-declaration"
            elif name == "libtheora":
                options += ["--disable-examples", "--disable-oggtest", "--disable-vorbistest"]
            elif name == "opus":
                options += ["--disable-doc", "--disable-extra-programs", "--disable-dred", "--disable-deep-plc", "--disable-osce"]
        configure = ["/bin/sh", "./configure", "--prefix=" + str(prefix), *options]
        source_record["configure"] = configure
        run(configure, source, name + "-configure", build_env)
        run(["/usr/bin/make", "-j" + str(jobs)], source, name + "-make", build_env)
        run(["/usr/bin/make", "install"], source, name + "-install", build_env)

    programs = {}
    for name in ("ffmpeg", "ffprobe"):
        program = payload / "bin" / name
        shutil.copy2(prefix / "bin" / name, program)
        program.chmod(0o755)
        run(["/usr/bin/codesign", "--force", "--sign", "-", program], work, name + "-sign")
        if output(["/usr/bin/lipo", "-archs", program]).strip() != "arm64":
            raise ValueError("Expected arm64 only: " + name)
        libraries = [line.split()[0] for line in output(["/usr/bin/otool", "-L", program]).splitlines()[1:] if line.strip()]
        if not libraries or any(not library.startswith(("/usr/lib/", "/System/Library/")) for library in libraries):
            raise ValueError("Non-system dynamic dependency: " + repr(libraries))
        build_info = output(["/usr/bin/xcrun", "vtool", "-show-build", program])
        minimums = re.findall(r"\bminos (\d+)\.(\d+)", build_info)
        if not minimums or any(tuple(map(int, version)) > (15, 0) for version in minimums):
            raise ValueError("Unexpected minimum OS: " + build_info)
        version = output([program, "-hide_banner", "-version"])
        if "version 9.0.2" not in version or "--enable-nonfree" in version:
            raise ValueError("Unexpected FFmpeg build: " + version)
        programs[name] = dict(sha256=sha(program), version=version, dynamicLibraries=libraries, buildInfo=build_info)
    ffmpeg = payload / "bin/ffmpeg"
    for option, expected, encoder in [("-encoders", ENCODERS, True), ("-muxers", MUXERS, False), ("-decoders", DECODERS, True)]:
        text = output([ffmpeg, "-hide_banner", option])
        (work / "logs" / (option[1:] + ".txt")).write_text(text)
        missing = expected - listed(text, encoder)
        if missing:
            raise ValueError("Missing " + option + ": " + ", ".join(sorted(missing)))
    recipe = Path(__file__).resolve()
    provenance = dict(version="9.0.2", runtime="osx-arm64", minimumMacOS="15.0", sources=sources,
                      programs=programs, commands=commands, recipeSHA256=sha(recipe), compiler=output(["/usr/bin/clang", "--version"]),
                      cmake=output([cmake, "--version"]))
    (payload / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2) + "\n")
    (payload / "BUILDING.txt").write_text("Built by Tools/build-ffmpeg.py from SHA-256 pinned upstream sources.\n"
        "External codec libraries are static; system libraries remain dynamic.\n"
        "GPLv3 build, with each upstream license under LICENSES/.\n"
        "Distribute the accompanying sources ZIP with the binary ZIP. No --enable-nonfree.\n"
        "The recipe is repeatable; byte-for-byte reproducibility and notarization are not claimed.\n")
    verify_bundle(payload)
    binary_zip = work / "ffmpeg-9.0.2-osx-arm64.zip"
    with zipfile.ZipFile(binary_zip, "x", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in sorted(payload.rglob("*")):
            if path.is_file():
                bundle.write(path, str(Path("ffmpeg") / path.relative_to(payload)))
    source_zip = work / "ffmpeg-9.0.2-sources.zip"
    with zipfile.ZipFile(source_zip, "x", compression=zipfile.ZIP_STORED) as bundle:
        for path in sorted((work / "archives").iterdir()):
            bundle.write(path, "archives/" + path.name)
        bundle.write(recipe, "build-ffmpeg.py")
        bundle.write(payload / "PROVENANCE.json", "PROVENANCE.json")
    package = dict(version="9.0.2", runtime="osx-arm64", kind="zip", sha256=sha(binary_zip), size=binary_zip.stat().st_size,
                   archive=str(binary_zip), sourceArchive=str(source_zip), sourceSHA256=sha(source_zip), folder=str(payload))
    (work / "package.json").write_text(json.dumps(package, indent=2) + "\n")
    print(json.dumps(package, indent=2), flush=True)


def self_test():
    assert len({name for name, *_ in PINS}) == len(PINS)
    assert all(url.startswith("https://") and re.fullmatch(r"[0-9a-f]{64}", digest) for _, _, url, digest in PINS)
    assert listed(" V..... = Video\n V....D png PNG\n", True) == {"png"}
    assert listed(" V..... libaom-av1 AV1\n", True) == DECODERS
    assert listed(" .E. = Muxing\n E mov,mp4 MOV\n D wav input\n", False) == {"mov", "mp4"}
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        bundle = root / "ffmpeg"
        (bundle / "bin").mkdir(parents=True)
        for name, *_ in PINS:
            (bundle / "LICENSES" / name).mkdir(parents=True)
            (bundle / "LICENSES" / name / "LICENSE").write_text("test notice")
        programs = {}
        for name in ("ffmpeg", "ffprobe"):
            program = bundle / "bin" / name
            program.write_bytes(name.encode())
            program.chmod(0o755)
            programs[name] = dict(sha256=sha(program))
        provenance = dict(version="9.0.2", runtime="osx-arm64", minimumMacOS="15.0", programs=programs,
                          sources=[dict(zip(("name", "version", "url", "sha256"), pin)) for pin in PINS])
        (bundle / "PROVENANCE.json").write_text(json.dumps(provenance))
        verify_bundle(bundle)
        for relative in ("bin/ffplay", "libextra.dylib", "LICENSES/ffmpeg/link"):
            extra = bundle / relative
            if relative.endswith("link"):
                extra.symlink_to(bundle / "PROVENANCE.json")
            else:
                extra.write_bytes(b"unexpected code")
            try:
                verify_bundle(bundle)
            except ValueError:
                pass
            else:
                raise AssertionError("Unexpected FFmpeg payload accepted: " + relative)
            extra.unlink()
        (bundle / "bin/ffprobe").write_bytes(b"changed")
        try:
            verify_bundle(bundle)
        except ValueError:
            pass
        else:
            raise AssertionError("Changed FFmpeg bundle accepted")
        for index, (name, kind, valid) in enumerate([("source/configure", tarfile.REGTYPE, True),
                                                   ("../escape", tarfile.REGTYPE, False),
                                                   ("/escape", tarfile.REGTYPE, False),
                                                   ("source/link", tarfile.SYMTYPE, False)]):
            archive = root / (str(index) + ".tar")
            with tarfile.open(archive, "w") as bundle:
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = kind, 0o755
                if kind == tarfile.REGTYPE:
                    entry.size = 2
                    bundle.addfile(entry, io.BytesIO(b"ok"))
                else:
                    entry.linkname = "../escape"
                    bundle.addfile(entry)
            try:
                result = unpack(archive, root / ("out" + str(index)))
            except ValueError:
                assert not valid
            else:
                assert valid and (result / "configure").read_bytes() == b"ok"
                assert stat.S_IMODE((result / "configure").stat().st_mode) == 0o755
            check_hash(archive, sha(archive))
            try:
                check_hash(archive, "0" * 64)
            except ValueError:
                pass
            else:
                raise AssertionError("Bad hash accepted")
    print("PASS: source pins, listing parser, archive containment, executable modes, bundle and checksum rejection")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, help="New build directory; existing paths are refused")
    parser.add_argument("--source-cache", type=Path, help="Optional read-only directory of the pinned source archives")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--verify-bundle", type=Path, help="Verify the pinned bundle and executable hashes before staging")
    args = parser.parse_args()
    if args.self_test:
        self_test()
    elif args.verify_bundle:
        verify_bundle(args.verify_bundle)
        print("Verified FFmpeg bundle:", args.verify_bundle)
    elif args.work:
        build(args.work, args.jobs, args.source_cache)
    else:
        parser.error("Pass --work, --verify-bundle or --self-test")
