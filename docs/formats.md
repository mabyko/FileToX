# Filee 형식 카탈로그

<!-- Tools/import-filee-formats.py가 생성한다. 직접 수정하지 말고 스크립트를 다시 실행한다. -->

Filee `FormatRegistry.Known`이 등록한 형식의 정적 목록이다. **이 목록은 카탈로그일 뿐 실행 시점의 변환 능력이 아니다.** 어떤 형식 사이의 변환이 실제로 가능한지는 엔진 설치 상태, `ConverterCatalog`, `RoutePlanner`가 결정하며, 이 문서와 `Resources/FileeFormats.json`은 그 판단에 쓰지 않는다. 읽기 전용은 Filee가 변환 대상(출력)으로 제공하지 않는 형식이다.

## 출처

- 저장소: https://github.com/KnifeLemon/Filee
- 커밋: `21fdd05ef7181b032ed83ec895cc9bbc4b198985`
- 원본 파일: `src/Filee.Core/Formats/FormatRegistry.cs` (분류 정의는 `src/Filee.Core/Formats/FileFormat.cs`)
- 라이선스: MIT (`Resources/Filee.LICENSE`)
- 생성기: `Tools/import-filee-formats.py` → `Resources/FileeFormats.json`
- 재생성·`--check`에는 위 커밋의 `.reference/Filee` 체크아웃이 필요하다. 앱 빌드에는 필요하지 않다.

## 요약

- 전체 172개 = 실제 형식 171개 + 가상 `folder` 1개
- 읽기 전용 58개, 확장자 257개(중복 없음, 가상 `folder`의 빈 확장자 제외), 분류 14개

| 분류 | 형식 수 |
| --- | ---: |
| Image | 18 |
| Pdf | 1 |
| Document | 16 |
| Spreadsheet | 10 |
| Presentation | 9 |
| Hwp | 2 |
| Text | 5 |
| Video | 22 |
| Audio | 19 |
| Ebook | 23 |
| Archive | 29 |
| Vector | 11 |
| Cad | 2 |
| Font | 5 |

가상 `folder`는 "Extract" 프리셋의 출력(압축 해제 폴더)을 나타내는 의사 형식이며 Archive 분류에 속한다. 확장자 목록은 빈 문자열 하나다.

## Image

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `png` | PNG | `.png` |  |
| `jpg` | JPG | `.jpg`, `.jpeg`, `.jpe`, `.jfif` |  |
| `webp` | WEBP | `.webp` |  |
| `tiff` | TIFF | `.tiff`, `.tif` |  |
| `bmp` | BMP | `.bmp`, `.dib` |  |
| `gif` | GIF | `.gif` |  |
| `ico` | ICO | `.ico` |  |
| `avif` | AVIF | `.avif` |  |
| `heic` | HEIC | `.heic`, `.heif` | 읽기 전용 |
| `jxl` | JPEG XL | `.jxl` |  |
| `jp2` | JPEG 2000 | `.jp2`, `.j2k`, `.jpf`, `.jpx` |  |
| `psd` | PSD | `.psd` |  |
| `psb` | PSB | `.psb` |  |
| `tga` | TGA | `.tga`, `.icb`, `.vda`, `.vst` |  |
| `ppm` | PPM | `.ppm`, `.pgm`, `.pbm`, `.pnm` |  |
| `icns` | ICNS | `.icns` |  |
| `xcf` | XCF | `.xcf` | 읽기 전용 |
| `raw` | RAW | `.dng`, `.cr2`, `.cr3`, `.crw`, `.nef`, `.nrw`, `.arw`, `.srf`, `.sr2`, `.orf`, `.rw2`, `.raf`, `.pef`, `.dcr`, `.kdc`, `.erf`, `.mos`, `.mrw`, `.x3f`, `.3fr`, `.fff`, `.iiq`, `.mef`, `.rwl`, `.srw`, `.raw` | 읽기 전용 |

## Pdf

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `pdf` | PDF | `.pdf` |  |

## Document

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `docx` | DOCX | `.docx` |  |
| `docm` | DOCM | `.docm` |  |
| `dotx` | DOTX | `.dotx` |  |
| `dotm` | DOTM | `.dotm` |  |
| `doc` | DOC | `.doc` |  |
| `dot` | DOT | `.dot` | 읽기 전용 |
| `odt` | ODT | `.odt` |  |
| `rtf` | RTF | `.rtf` |  |
| `wps` | WPS | `.wps` | 읽기 전용 |
| `wpd` | WPD | `.wpd` | 읽기 전용 |
| `lwp` | LWP | `.lwp` | 읽기 전용 |
| `abw` | ABW | `.abw`, `.zabw` | 읽기 전용 |
| `pages` | Pages | `.pages` | 읽기 전용 |
| `sdw` | SDW | `.sdw` | 읽기 전용 |
| `pub` | PUB | `.pub` | 읽기 전용 |
| `eml` | EML | `.eml` | 읽기 전용 |

## Spreadsheet

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `xlsx` | XLSX | `.xlsx` |  |
| `xlsm` | XLSM | `.xlsm` |  |
| `xltx` | XLTX | `.xltx` |  |
| `xls` | XLS | `.xls`, `.xlt` |  |
| `ods` | ODS | `.ods` |  |
| `csv` | CSV | `.csv` |  |
| `tsv` | TSV | `.tsv`, `.tab` |  |
| `et` | ET | `.et` | 읽기 전용 |
| `numbers` | Numbers | `.numbers` | 읽기 전용 |
| `sdc` | SDC | `.sdc` | 읽기 전용 |

## Presentation

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `pptx` | PPTX | `.pptx` |  |
| `pptm` | PPTM | `.pptm` |  |
| `potx` | POTX | `.potx` |  |
| `ppsx` | PPSX | `.ppsx` |  |
| `ppt` | PPT | `.ppt`, `.pps`, `.pot` |  |
| `odp` | ODP | `.odp` |  |
| `key` | Keynote | `.key` | 읽기 전용 |
| `dps` | DPS | `.dps` | 읽기 전용 |
| `sda` | SDA | `.sda`, `.sdd` | 읽기 전용 |

## Hwp

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `hwpx` | HWPX | `.hwpx` |  |
| `hwp` | HWP | `.hwp` |  |

## Text

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `txt` | TXT | `.txt` |  |
| `md` | Markdown | `.md`, `.markdown` |  |
| `html` | HTML | `.html`, `.htm`, `.xhtml` |  |
| `rst` | reStructuredText | `.rst` |  |
| `tex` | LaTeX | `.tex`, `.latex` |  |

## Video

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `mp4` | MP4 | `.mp4` |  |
| `m4v` | M4V | `.m4v` |  |
| `mov` | MOV | `.mov`, `.qt` |  |
| `mkv` | MKV | `.mkv` |  |
| `webm` | WEBM | `.webm` |  |
| `avi` | AVI | `.avi`, `.divx` |  |
| `wmv` | WMV | `.wmv`, `.asf` |  |
| `flv` | FLV | `.flv`, `.f4v` |  |
| `mpg` | MPEG | `.mpg`, `.mpeg`, `.mpe`, `.m1v`, `.m2v` |  |
| `ts` | TS | `.ts` |  |
| `m2ts` | M2TS | `.m2ts`, `.mts`, `.m2t` |  |
| `3gp` | 3GP | `.3gp`, `.3gpp` |  |
| `3g2` | 3G2 | `.3g2` |  |
| `ogv` | OGV | `.ogv` |  |
| `vob` | VOB | `.vob` |  |
| `mod` | MOD | `.mod`, `.tod` | 읽기 전용 |
| `dv` | DV | `.dv`, `.dif` |  |
| `mxf` | MXF | `.mxf` |  |
| `rm` | RM | `.rm`, `.rmvb` | 읽기 전용 |
| `swf` | SWF | `.swf` | 읽기 전용 |
| `wtv` | WTV | `.wtv`, `.dvr-ms`, `.dvr` | 읽기 전용 |
| `cavs` | CAVS | `.cavs` | 읽기 전용 |

## Audio

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `mp3` | MP3 | `.mp3` |  |
| `m4a` | M4A | `.m4a` |  |
| `m4b` | M4B | `.m4b` |  |
| `aac` | AAC | `.aac` |  |
| `wav` | WAV | `.wav`, `.wave` |  |
| `flac` | FLAC | `.flac` |  |
| `ogg` | OGG | `.ogg`, `.oga` |  |
| `opus` | OPUS | `.opus` |  |
| `wma` | WMA | `.wma` |  |
| `aiff` | AIFF | `.aiff`, `.aif`, `.aifc` |  |
| `ac3` | AC3 | `.ac3` |  |
| `amr` | AMR | `.amr` |  |
| `au` | AU | `.au`, `.snd` |  |
| `caf` | CAF | `.caf` |  |
| `weba` | WEBA | `.weba` |  |
| `mka` | MKA | `.mka` |  |
| `mp2` | MP2 | `.mp2`, `.mpa` |  |
| `dss` | DSS | `.dss` | 읽기 전용 |
| `voc` | VOC | `.voc` |  |

## Ebook

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `epub` | EPUB | `.epub` |  |
| `mobi` | MOBI | `.mobi` |  |
| `azw3` | AZW3 | `.azw3` |  |
| `azw` | AZW | `.azw` | 읽기 전용 |
| `azw4` | AZW4 | `.azw4` | 읽기 전용 |
| `prc` | PRC | `.prc` | 읽기 전용 |
| `fb2` | FB2 | `.fb2` |  |
| `cbz` | CBZ | `.cbz` |  |
| `cbr` | CBR | `.cbr` | 읽기 전용 |
| `cb7` | CB7 | `.cb7` | 읽기 전용 |
| `cbt` | CBT | `.cbt` | 읽기 전용 |
| `cbc` | CBC | `.cbc` | 읽기 전용 |
| `htmlz` | HTMLZ | `.htmlz` |  |
| `txtz` | TXTZ | `.txtz` |  |
| `chm` | CHM | `.chm` | 읽기 전용 |
| `lit` | LIT | `.lit` |  |
| `lrf` | LRF | `.lrf` |  |
| `pdb` | PDB | `.pdb` |  |
| `pml` | PML | `.pml` |  |
| `rb` | RB | `.rb` |  |
| `snb` | SNB | `.snb` |  |
| `tcr` | TCR | `.tcr` |  |
| `oeb` | OEB | `.oeb`, `.opf` | 읽기 전용 |

## Archive

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `zip` | ZIP | `.zip` |  |
| `7z` | 7Z | `.7z` |  |
| `rar` | RAR | `.rar` | 읽기 전용 |
| `tar` | TAR | `.tar` |  |
| `tgz` | TAR.GZ | `.tar.gz`, `.tgz`, `.taz` |  |
| `tbz2` | TAR.BZ2 | `.tar.bz2`, `.tbz2`, `.tar.bz`, `.tbz` |  |
| `txz` | TAR.XZ | `.tar.xz`, `.txz` |  |
| `tar7z` | TAR.7Z | `.tar.7z` | 읽기 전용 |
| `tlz` | TAR.LZ | `.tar.lz`, `.tlz` | 읽기 전용 |
| `tz` | TAR.Z | `.tar.z`, `.tz` | 읽기 전용 |
| `gz` | GZ | `.gz` |  |
| `bz2` | BZ2 | `.bz2`, `.bz` |  |
| `xz` | XZ | `.xz` |  |
| `lz` | LZ | `.lz` | 읽기 전용 |
| `lzma` | LZMA | `.lzma` | 읽기 전용 |
| `z` | Z | `.z` | 읽기 전용 |
| `jar` | JAR | `.jar` | 읽기 전용 |
| `cab` | CAB | `.cab` | 읽기 전용 |
| `cpio` | CPIO | `.cpio` | 읽기 전용 |
| `deb` | DEB | `.deb` | 읽기 전용 |
| `rpm` | RPM | `.rpm` | 읽기 전용 |
| `dmg` | DMG | `.dmg` | 읽기 전용 |
| `iso` | ISO | `.iso` | 읽기 전용 |
| `img` | IMG | `.img` | 읽기 전용 |
| `lha` | LHA | `.lha`, `.lzh` | 읽기 전용 |
| `arj` | ARJ | `.arj` | 읽기 전용 |
| `alz` | ALZ | `.alz` | 읽기 전용 |
| `egg` | EGG | `.egg` | 읽기 전용 |
| `folder` | Folder | (없음) | 가상 |

## Vector

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `svg` | SVG | `.svg` |  |
| `svgz` | SVGZ | `.svgz` |  |
| `eps` | EPS | `.eps`, `.epsf`, `.epsi` |  |
| `ps` | PS | `.ps` |  |
| `ai` | AI | `.ai` | 읽기 전용 |
| `emf` | EMF | `.emf` | 읽기 전용 |
| `wmf` | WMF | `.wmf` | 읽기 전용 |
| `cdr` | CDR | `.cdr` | 읽기 전용 |
| `cgm` | CGM | `.cgm` | 읽기 전용 |
| `vsd` | VSD | `.vsd`, `.vsdx` | 읽기 전용 |
| `odg` | ODG | `.odg` |  |

## Cad

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `dwg` | DWG | `.dwg` |  |
| `dxf` | DXF | `.dxf` |  |

## Font

| id | 이름 | 확장자 | 비고 |
| --- | --- | --- | --- |
| `ttf` | TTF | `.ttf` |  |
| `otf` | OTF | `.otf` |  |
| `woff` | WOFF | `.woff` |  |
| `woff2` | WOFF2 | `.woff2` |  |
| `eot` | EOT | `.eot` |  |
