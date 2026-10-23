# LibRaw

FileToX's conversion helper (`FileToXEngine.app`) contains **LibRaw 0.22.2-Release**, a library for reading camera
RAW files, compiled from unmodified LibRaw source and statically linked. LibRaw is offered under LGPL-2.1 or
CDDL-1.0; FileToX uses it under the **Common Development and Distribution License (CDDL) Version 1.0**
([LibRaw.LICENSE](LibRaw.LICENSE)).

- Source code of the LibRaw used: the official 0.22.2 release, <https://www.libraw.org/data/LibRaw-0.22.2.tar.gz>
  (SHA-256 `de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`; the same files as tag `0.22.2` of
  <https://github.com/LibRaw/LibRaw>). FileToX's source tree carries the copy it compiles in `Vendor/LibRaw`.
- FileToX made no modifications to LibRaw. FileToX's own glue code (`Vendor/LibRaw/FileToX`) is FileToX code under
  FileToX's MIT licence.
- Any terms of FileToX's licence that differ from the CDDL are offered by FileToX alone, not by LibRaw LLC or any
  other LibRaw contributor.

## LibRaw COPYRIGHT

```text
 ** LibRaw: Raw images processing library **

Copyright (C) 2008-2025 LibRaw LLC (http://www.libraw.org, info@libraw.org)

LibRaw is free software; you can redistribute it and/or modify
it under the terms of the one of two licenses as you choose:

1. GNU LESSER GENERAL PUBLIC LICENSE version 2.1
   (See file LICENSE.LGPL provided in LibRaw distribution archive for details).

2. COMMON DEVELOPMENT AND DISTRIBUTION LICENSE (CDDL) Version 1.0
   (See file LICENSE.CDDL provided in LibRaw distribution archive for details).

LibRaw uses code from dcraw.c -- Dave Coffin's raw photo decoder,
dcraw.c is copyright 1997-2018 by Dave Coffin, dcoffin a cybercom o net.
LibRaw do not use RESTRICTED code from dcraw.c

LibRaw uses DCB demosaic and FBDD denoise licensed under BSD-like 3-clause license
DCB and FBDD are Copyright (C) 2010,  Jacek Gozdz (cuniek@kft.umcs.lublin.pl)

LibRaw uses X3F library to unpack Foveon Files, licensed BSD-style license
Copyright (c) 2010, Roland Karlsson (roland@proxel.se)
All rights reserved.

LibRaw uses pieces of code from Adobe DNG SDK 1.4,
Copyright (c) 2005 Adobe Systems Incorporated, licensed under MIT license
```

The AAHD and DHT demosaic code (Copyright 2013 Anton Petrusevich) and the Fujifilm compressed and Canon CR3 decoders
(Copyright 2016-2019 Alexey Danilchenko, 2019 LibRaw LLC) are part of LibRaw under the same LGPL-2.1 / CDDL-1.0 terms.

## DCB demosaic and FBDD denoise

From `src/demosaic/dcb_demosaic.cpp` (compiled into the helper):

```text
Copyright (C) 2010,  Jacek Gozdz (cuniek@kft.umcs.lublin.pl)

This code is licensed under a (3-clause) BSD license as follows :

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following
conditions are met:

* Redistributions of source code must retain the above copyright
  notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above
  copyright notice, this list of conditions and the following
  disclaimer in the documentation and/or other materials provided
  with the distribution.
* Neither the name of the author nor the names of its
  contributors may be used to endorse or promote products
  derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY
OF SUCH DAMAGE.
```

FBDD denoising is by Jacek Gozdz and Luis Sanz Rodríguez (luis.sanz.rodriguez@gmail.com).

## X3F tools

From `src/x3f/` and `internal/x3f_tools.h`. FileToX builds LibRaw without `USE_X3FTOOLS`, so this code is in the
source tree but not compiled into the helper:

```text
Library for accessing X3F Files
----------------------------------------------------------------
BSD-style License
----------------------------------------------------------------

* Copyright (c) 2010, Roland Karlsson (roland@proxel.se)
* All rights reserved.
*
* Redistribution and use in source and binary forms, with or without
* modification, are permitted provided that the following conditions are met:
*     * Redistributions of source code must retain the above copyright
*       notice, this list of conditions and the following disclaimer.
*     * Redistributions in binary form must reproduce the above copyright
*       notice, this list of conditions and the following disclaimer in the
*       documentation and/or other materials provided with the distribution.
*     * Neither the name of the organization nor the
*       names of its contributors may be used to endorse or promote products
*       derived from this software without specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY ROLAND KARLSSON ''AS IS'' AND ANY
* EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
* WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
* DISCLAIMED. IN NO EVENT SHALL ROLAND KARLSSON BE LIABLE FOR ANY
* DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
* LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
* ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
* SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Adobe DNG SDK

LibRaw contains pieces of code from the Adobe DNG SDK 1.4 (e.g. the half-float conversion and floating-point
predictor of `src/decoders/fp_dng.cpp`), licensed under the MIT license:

```text
Copyright (c) 2005 Adobe Systems Incorporated

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
