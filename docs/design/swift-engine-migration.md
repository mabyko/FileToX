# C# 변환 엔진의 Swift 전환 계획

작성 2026-10-23. FileToX의 C# helper(`EngineHost` + Filee `Core`·`Engines` + NuGet)를 Swift helper로 바꿔 개발·빌드·배포·실행에서 .NET을 없앤다. 이식 규칙은 [swift-engine-port.md](swift-engine-port.md)에 있다.

## 1. 현재 구조와 .NET 의존

- 앱(SwiftUI·AppKit)은 `Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine`을 실행하고 stdio NDJSON([host-wire-v1](host-wire-v1.md))으로 통신한다.
- helper는 C# `EngineHost/*.cs`(약 2,000줄)가 Filee `Core`(3,566줄)·`Engines`(33,000줄)와 NuGet 패키지를 참조하는 self-contained .NET 10 앱이다. 배포 helper는 약 190 MB이며 .NET 런타임·NuGet DLL·native dylib(ImageMagick, PDFium, Skia, HarfBuzz, Unhwp)를 포함한다.
- Xcode 빌드 단계가 매번 `Tools/build-engine-host.sh`를 호출하고, 이 스크립트가 엔진 변경과 관계없이 `~/.dotnet` SDK를 먼저 확인한다.

## 2. 실제로 지원·검증된 변환 기능

엔진 23개가 Filee `FormatRegistry`의 171개 형식을 다룬다. 실제 가능한 조합은 엔진 상태와 `RoutePlanner`(최대 3단계)가 정한다. 기존 기록(`EngineHost/IMPLEMENTATION.md`, README)으로 확인된 범위는 다음과 같다.

| 구분 | 내용 |
| --- | --- |
| 내장 엔진 실변환 20건 | png→jpg, heic→png, png→pdf, PDF 합치기, 2쪽 pdf→png, 다중 페이지 TIFF, ZIP 묶기(형식 모름·폴더 포함), zip→폴더, md→docx, docx→html/pdf/epub, txt→hwpx(한글·공백 경로), hwpx→hwp(rhwp), hwp→pdf, csv↔xlsx, svg→png, dxf→svg, ttf→woff2 |
| 선택 판정 2건 | mp4→mp3 사용 가능 여부와 FFmpeg 설치 안내, EPS의 Ghostscript 안내 |
| 추가 엔진 표본 11건 | Pandoc·LibreOffice·Calibre·FFmpeg 변환, 처리 중 취소(FFmpeg·LibreOffice), host 프로세스 그룹 종료, Pandoc 첨부 이미지 충돌 |
| Filee 테스트 | Core 164건 통과(패치 포함), Engines 445건 통과·3건 실패(이 Mac의 FFmpeg에 없는 인코더) |
| 앱 연동 | 홈·도넛 선택, 진행·취소, 최근 변환 이력, 프리셋·프로필·설정 저장, 언어 전환 |

전체 형식 조합은 위 표본 밖에 있다. 전환에서는 C# helper를 기준선으로 실행해 **모든 형식의 선택 결과(사용 가능한 출력 형식·프리셋)와 형식별 대표 변환 결과**를 기록하고 Swift helper와 비교한다(5절).

## 3. 엔진별 C# 의존과 대체 방법

| 엔진 id | C# 의존 | Swift 대체 | 난이도 |
| --- | --- | --- | --- |
| `magick` | Magick.NET(ImageMagick) | ImageIO·CoreGraphics·vImage. ImageIO가 쓰지 못하는 형식(PSB 읽기·쓰기, XCF 읽기, PPM 계열 세부 형식, ICO 크기 지정, TIFF 압축 방식)은 Swift 코덱으로 보완. 카메라 RAW는 LibRaw(4절) | 중 — **WebP·JPEG XL 쓰기는 4절** |
| `pdfsharp` | PDFsharp | CoreGraphics PDF context·PDFKit(이미지→PDF, PDF 쪽 범위·분할, 합치기) | 중 |
| `pdfium` | PDFtoImage(PDFium)·SkiaSharp | 번들 PDFium 147.0.7690.0 + 이미지 인코더 (`Vendor/PDFium`) | 중 |
| `pdf-text` | PdfPig | PDFKit 문자·위치 정보 | 중 |
| `rhwp` | 외부 rhwp | 같은 실행 파일을 같은 인자로 실행 | 하 |
| `unhwp` | Unhwp(Rust native) + Markdig | **4절** | 상 |
| `markdown` | Markdig | CommonMark 파서(+표·작업 목록·각주·정의 목록·수식 등 Filee가 쓰는 확장)를 Swift로 구현 | 중상 |
| `spreadsheet` | ExcelDataReader, ExcelNumberFormat + 자체 코드 | XLS(BIFF8·OLE2) 읽기와 Excel 숫자 서식을 Swift로 구현, 나머지 자체 코드 이식 | 중 |
| `ooxml` | 자체 코드 | 이식 | 하 |
| `hwpx-writer`, `docx-writer` | 자체 코드 + AngleSharp(HTML)·Markdig·PdfPig·ImageMagick | 자체 코드 이식, HTML은 libxml2 HTML 파서, 그 밖은 위 대체 사용 | 상(분량 1.3만 줄) |
| `archive` | System.IO.Compression·SharpCompress + 외부 7-Zip | ZIP·TAR·GZ는 Swift(zlib), 나머지는 같은 7-Zip, ALZ·EGG·LZIP·bzip2 자체 코드 이식 | 중 |
| `vector` | Svg.Skia·SkiaSharp·HarfBuzz | macOS SVG 렌더러(CoreSVG, `NSImage`)와 CoreGraphics. **텍스트 서식 일부는 4절** | 중 |
| `icns` | 자체 코드 + ImageMagick | 이식 + ImageIO | 하 |
| `font` | 자체 코드 + Brotli | 이식 + Apple Compression(Brotli) | 중 |
| `email` | MimeKitLite | MIME 파서(다중 파트·인코딩·RFC 2047·문자 집합)를 Swift로 구현 | 중 |
| `ffmpeg` | 외부 FFmpeg | 같은 실행 파일 | 하 |
| `cad` | ACadSharp·SkiaSharp | DXF 읽기·쓰기와 장면·렌더링을 Swift·CoreGraphics로 이식. **DWG는 4절** | 상 |
| `ebook` | 자체 코드 + ImageMagick·PdfSharp·PDFtoImage·SharpCompress | 이식 + ImageIO·PDFKit(쪽 편집)·PDFium(래스터)·7-Zip | 중 |
| `pandoc`, `ghostscript`, `calibre`, `libreoffice` | 외부 프로그램 | 같은 실행 파일·인자 | 하 |

코어와 host도 Swift로 옮긴다: 형식 레지스트리, 프리셋·출력 규칙·이름 바꾸기, 프로필 선택, 경로 탐색(`RoutePlanner`·`ConverterCatalog`), 작업 큐와 출력 staging·확정(패치 0001), 설정·프리셋·프로필·이력 저장소(`UserDataStore`의 JSON 형식과 스키마 이전 그대로), 지역화, NDJSON 프로토콜·잠금·journal 정리.

## 4. 동등한 대체가 어려운 기능

다음은 그대로 옮기기 어렵거나 결과가 달라질 수 있다. 결정 전에는 제거하지 않는다.

| 기능 | 어려운 이유 | 선택지 |
| --- | --- | --- |
| DWG 읽기·쓰기(dwg→dxf/pdf/svg/이미지, dxf→dwg) | ACadSharp가 9.8만 줄이며 DWG 입출력만 2.8만 줄이다. macOS에 DWG를 읽는 기능이 없다. | ① 필요한 ACadSharp 범위를 Swift로 이식(가장 큼) ② DWG 읽기만 이식하고 dxf→dwg 쓰기는 사용 불가로 표시 ③ 외부 변환기(LibreDWG 등)를 선택 설치 엔진으로 추가 |
| WebP·JPEG XL 쓰기 | ImageIO가 두 형식을 읽기만 한다. ImageMagick은 libwebp·libjxl을 쓴다. | ① libwebp(BSD)·libjxl(BSD) 소스를 포함해 빌드 ② WebP는 libwebp, JPEG XL은 Swift 무손실 인코더(품질 옵션 무시) ③ 둘 다 Swift 무손실 인코더 |
| HWP/HWPX → TXT·MD·HTML(Unhwp) | Rust 라이브러리의 HWP 파서·Markdown 출력과 같은 결과를 내려면 그 파서를 옮겨야 한다. | ① 번들 rhwp로 HWP→HWPX 후 Filee의 HWPX 읽기·Markdown/텍스트/XHTML 작성기 사용(출력 서식이 다소 다름) ② Unhwp 파서를 Swift로 이식 |
| SVG 텍스트 서식 | macOS SVG 렌더러가 `tspan`별 스타일과 CSS `font` 단축 속성을 반영하지 않는다(그라데이션·마스크·필터·패턴은 처리). | ① 렌더링 전에 SVG 텍스트·CSS를 정규화해 보완 ② Swift SVG 렌더러를 별도 구현 |

**결정(2026-10-23):**

- DWG: 읽기와 쓰기 모두 Swift로 이식한다. 생성한 DWG는 Swift 읽기로 되읽고, 기존 C# helper(ACadSharp 읽기)로도 읽혀 비교한다. AutoCAD·ODA에서 여는 확인은 이 환경에서 할 수 없으므로 남은 위험으로 둔다.
- WebP·JPEG XL 쓰기: SwiftPM으로 Google libwebp 1.6.0과 libjxl 0.10.4를 소스 빌드해 쓴다(`SDWebImage/libwebp-Xcode`, `SDWebImage/libjxl-Xcode`, 버전 고정). 첫 빌드에서 패키지를 내려받는다.
- PDF → 래스터: **C#와 같은 PDFium을 번들한다.** PDFtoImage 5.2.1이 쓰던 bblanchon.PDFium.macOS 147.0.7690(실제 PDFium 147.0.7690.0)을 선택했다. PDFKit의 안티앨리어싱 차이로 실패하던 43건은 PDFium 전환 뒤 FAIL 0건(6 PASS, 37 WARN)이 됐다. 44쪽/그림 중 21개는 픽셀이 같고 나머지 PSNR 57.754–79.047 dB, SSIM ≥0.999432다. PDF 이미지·만화·스캔/그림 추출 fallback을 하나의 전역 잠금 renderer로 처리한다. arm64/x86_64 dylib와 공개 헤더를 `Vendor/PDFium`에 포함하며 PDFium 자체는 네트워크 없이 빌드한다. helper의 `Contents/Frameworks`에 넣고 서명하며 BSD-3·번들 구성요소 고지를 `Resources/Notices`에 포함한다. 버전·해시·렌더 옵션은 [Vendor README](../../Vendor/PDFium/README.md), 건별 수치는 [비교 기록](engine-differential-triage.md#pdfkit-versus-pdfiumskia-rasterization)에 있다.
- SVG: macOS 내장 렌더러에 CSS·`tspan` 전처리를 더한다.
- 카메라 RAW: C# 앱과 같은 색을 낸다. C# 앱은 ImageMagick 7.1.2-32 Q8의 DNG 코더로 LibRaw 0.22.2를 썼고, Apple CIRAWFilter는 가장 잘 맞춘 설정도 평균 ΔE00 2.7 차이가 났다. 그래서 LibRaw 0.22.2를 CDDL-1.0으로 소스 포함해 빌드하고(`Vendor/LibRaw`, libjpeg 없음), ImageMagick과 같은 호출 순서·설정으로 현상한다(`Vendor/LibRaw/FileToX/develop.c`). 공개 표본 10개 중 LibRaw가 여는 8개는 C# 출력과 픽셀이 같다. 손실 압축 DNG(libjpeg 필요)와 LibRaw가 모르는 카메라는 LibRaw처럼 맞춘 CIRAWFilter로 대신 현상하고 stderr에 남긴다(손실 DNG 2개: ΔE00 1.6). 고지는 `docs/upstream/LibRaw.*`이며 helper의 `Resources/Notices`에 들어간다.
- HWP/HWPX → TXT·MD·HTML: 공개 HWP 문서 20개로 Unhwp(A), rhwp 직접 내보내기(B), "rhwp로 HWPX 변환 + 이식한 Filee 읽기·작성기"(C)를 비교했다. C가 구조·그림·가독성에서 가장 낫고 HWP 3.x도 처리한다(A는 실패). 결정: C를 쓰고, 수식은 Unhwp의 수식→LaTeX 변환기(MIT)만 Swift로 옮겨 기존처럼 LaTeX로 낸다. 비교에서 나온 C의 문제(그림 실패, 목록 들여쓰기, 중첩 표·캡션·제목·머리말 누락, BMP 재압축, 셀 줄바꿈)를 수정하고 같은 표본으로 재검증했다. 결과·동작 변경·남은 차이는 [r3 구현·비교 보고서](swift-hwp-export-r3.md)에 있다.

- JPEG 2000 쓰기: ImageIO가 손실 품질 설정을 무시한다(q100 무손실은 정상). 결정: 수용하고 제한으로 기록한다.

그 밖에 PDF 텍스트 배치(PdfPig→PDFKit), HTML 파싱(AngleSharp→libxml2), Markdown 확장(Markdig→Swift 파서)은 결과가 미세하게 달라질 수 있어 비교 검증으로 확인한다. 앱에 연결되지 않은 Filee 기능(앱 내 엔진 다운로드 `EngineInstaller`, 감시 폴더 실행 `FolderWatcher`)은 설정 데이터만 보존하고 실행 코드는 옮기지 않는다.

## 5. 전환 순서와 검증

1. **기반**: 계약(형식·프리셋·변환기 프로토콜), ZIP·XML·인코딩·바이너리·이미지 정보·경로 도구, 외부 프로그램 실행기(프로세스 트리 종료·타임아웃·취소), 엔진 위치 탐색, 공유 문서·표 모델. — 완료(테스트 19건 통과).
2. **기준선**: 설치된 C# helper로 전체 선택 결과와 형식별 대표 변환을 기록하는 비교 도구(`Tools/engine-compare/`).
3. **코어·host**: 작업 큐·staging·저장소·프로토콜. 기존 사용자 데이터(`~/Library/Application Support/FileToX/core`)의 사본을 읽고 다시 저장해 C# 결과와 비교한다.
4. **엔진**(병렬): 이미지·PDF·벡터 → 문서(HWPX·DOCX·Office·전자책·Markdown·HTML·메일) → 글꼴·압축·미디어 → CAD.
5. **통합**: 엔진별로 C# 기준선과 같은 입력을 변환해 상태·출력 이름·형식별 특성(이미지 크기·유사도, PDF 쪽수·텍스트, 압축 목록, 미디어 코덱·길이)을 비교한다.
6. **정리**: C# 코드·NuGet·.NET 빌드 단계·문서를 지운다. Xcode는 Swift helper를 빌드해 같은 위치에 넣는다.
7. **격리 검증**: `~/.dotnet`·`~/.nuget`을 읽을 수 없는 sandbox와 정리된 환경 변수로 Xcode 클린 빌드·테스트를 실행하고, 앱 번들에 .NET 파일이 없음을 확인한다. 홈의 .NET 폴더는 지우지 않는다.
