#!/usr/bin/env python3
"""Give only ad-hoc helpers the exception needed to load their bundled PDFium."""
import pathlib
import plistlib
import sys


def prepare(output, identity):
    # Ad-hoc signatures have no Team ID; certificate-signed helpers keep library validation.
    values = {"com.apple.security.cs.disable-library-validation": True} if identity == "-" else {}
    contents = plistlib.dumps(values)
    output.parent.mkdir(parents=True, exist_ok=True)
    if not output.is_file() or output.read_bytes() != contents:
        output.write_bytes(contents)


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]), sys.argv[2])
