# OpenJPEG 2.5.4

Pinned upstream: https://github.com/uclouvain/openjpeg/releases/tag/v2.5.4
Archive: https://github.com/uclouvain/openjpeg/archive/refs/tags/v2.5.4.tar.gz
SHA-256: `a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a`.

`src/` contains the unmodified full upstream `src/lib/openjp2` C library sources and headers, excluding CMake files. The two generated configuration headers target macOS arm64 and x86_64. FileToX's separate bridge writes J2K codestreams using ImageMagick 7.1.2-32's PSNR quality settings. ImageIO retains the JP2 container, ICC, resolution and metadata. Quality 100 retains ImageIO's lossless writer. Unsupported source ICC profiles retain ImageIO's existing output-space behavior; native samples are converted to the color space actually stored in the container. Arbitrary ICC byte preservation is not claimed.

BSD-2-Clause (see LICENSE and individual source headers). Binary redistribution must include the notices aggregated in NOTICES; the engine resource bundle carries them as OpenJPEG.LICENSE. No Homebrew libraries, installed app binaries, external tools, absolute install names or dynamic OpenJPEG library are used. The package builds the codec statically for the selected architecture; all upstream codecs remain present. Thread support is enabled with pthreads.
