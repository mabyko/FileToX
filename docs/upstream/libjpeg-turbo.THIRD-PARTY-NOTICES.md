# libjpeg-turbo

This software is based in part on the work of the Independent JPEG Group.

FileToX's conversion helper (`FileToXEngine.app`) contains **libjpeg-turbo 3.2.0**, compiled from unmodified source
and statically linked: its libjpeg API library (no SIMD, no TurboJPEG API, no programs). FileToX uses it to write JPEG
files and LibRaw uses it to decode lossy DNG and Kodak JPEG camera RAW files. The libjpeg API library is covered by the
IJG License below; [libjpeg-turbo.LICENSE](libjpeg-turbo.LICENSE) (libjpeg-turbo's `LICENSE.md`) describes the
licences of the whole libjpeg-turbo project.

- Source code of the libjpeg-turbo used: the official 3.2.0 release,
  <https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.2.0/libjpeg-turbo-3.2.0.tar.gz>
  (SHA-256 `6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e`; the same files as tag `3.2.0` of
  <https://github.com/libjpeg-turbo/libjpeg-turbo>). FileToX's source tree carries the subset it compiles in
  `Vendor/libjpeg-turbo`.
- FileToX made no modifications to libjpeg-turbo. FileToX's build configuration and JPEG writer
  (`Vendor/libjpeg-turbo/FileToX`) are FileToX code under FileToX's MIT licence.

## IJG License (libjpeg-turbo's README.ijg)

```text
LEGAL ISSUES
============

In plain English:

1. We don't promise that this software works.  (But if you find any bugs,
   please let us know!)
2. You can use this software for whatever you want.  You don't have to pay us.
3. You may not pretend that you wrote this software.  If you use it in a
   program, you must acknowledge somewhere in your documentation that
   you've used the IJG code.

In legalese:

The authors make NO WARRANTY or representation, either express or implied,
with respect to this software, its quality, accuracy, merchantability, or
fitness for a particular purpose.  This software is provided "AS IS", and you,
its user, assume the entire risk as to its quality and accuracy.

This software is copyright (C) 1991-2020, Thomas G. Lane, Guido Vollbeding.
All Rights Reserved except as specified below.

Permission is hereby granted to use, copy, modify, and distribute this
software (or portions thereof) for any purpose, without fee, subject to these
conditions:
(1) If any part of the source code for this software is distributed, then this
README file must be included, with this copyright and no-warranty notice
unaltered; and any additions, deletions, or changes to the original files
must be clearly indicated in accompanying documentation.
(2) If only executable code is distributed, then the accompanying
documentation must state that "this software is based in part on the work of
the Independent JPEG Group".
(3) Permission for use of this software is granted only if the user accepts
full responsibility for any undesirable consequences; the authors accept
NO LIABILITY for damages of any kind.

These conditions apply to any software derived from or based on the IJG code,
not just to the unmodified library.  If you use our work, you ought to
acknowledge us.

Permission is NOT granted for the use of any IJG author's name or company name
in advertising or publicity relating to this software or products derived from
it.  This software may be referred to only as "the Independent JPEG Group's
software".

We specifically permit and encourage the use of this software as the basis of
commercial products, provided that all warranty or liability claims are
assumed by the product vendor.
```
