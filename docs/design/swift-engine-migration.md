# C# 변환 엔진의 Swift 전환 기록

## 현재 상태 (2026-10-25)

앱은 SwiftUI·AppKit, helper는 `Sources/EngineMain`에서 시작하는 Swift 실행 파일이다. 앱 통신·모델은 `Sources/Core`(`FileToXCore`), host·변환 코어·엔진은 `Sources/Engine`(`FileToXEngineKit`)에 있다. 빌드 정의는 `Package.swift`, 앱·helper 번들·서명·도구 내장은 `project.yml`과 `Tools/stage-bundled-engines.sh`가 담당한다. 현재 빌드·실행에는 .NET SDK·런타임·NuGet 복원이나 과거 C# host가 필요 없다.

지원 범위는 **Apple Silicon M1 이상(arm64), macOS 15 이상**이다. 최소 OS는 유지하며 Intel·Rosetta 실행과 그 검증은 요구하지 않는다. 앱·helper·테스트는 `ARCHS: arm64`이고 staging도 다른 아키텍처를 거부한다. Xcode 명령에는 `-destination 'platform=macOS,arch=arm64' ARCHS=arm64`를 함께 지정해 Swift package 의존성 빌드도 제한한다. 구체적인 명령과 현재 데이터·취소·출력 안전은 [README](../../README.md), [아키텍처](../architecture.md), [패키징](macos-packaging.md)을 따른다.

내장 엔진은 Swift 코드·macOS 프레임워크·네이티브 라이브러리를 사용하고 rhwp·7-Zip은 번들 실행 파일을 사용한다. FFmpeg·Ghostscript·Pandoc·LibreOffice·Calibre는 시스템 설치나 사용자 지정 사본을 사용한다. 아래 초기 계획의 JPEG 2000 품질 제한 수용, SVG 렌더링 범위와 CMYK 처리 설명은 당시 결정이다. 이후 JPEG 2000 쓰기는 OpenJPEG를 사용하고, 제한된 SVG 기본 도형은 정적 Skia bridge로 처리하며 나머지 SVG 기능과 벡터 PDF는 CoreSVG를 유지한다. 현재 색상 처리·비교 한계는 [이전 단계 최종 통합 기록](engine-differential-triage.md#final-native-quality-integration-2026-10-24)에서 확인한다.

PDFium·Skia의 업스트림 버전·원본 해시·고지는 보존한다. 현재 Skia 정적 bridge·재빌드·다운로드는 arm64 전용이고 배포 staging은 PDFium·번들 도구에서도 arm64만 남겨 서명한다. 검증용 PDFium universal 원본은 변경하지 않는다. 이전 universal 출력의 경위와 과거 Intel 검증 기록은 보존하지만 현재 지원·추가 검증 의무는 아니다.

이전 단계에서 SDK 접근 차단 빌드·테스트, 기존 팀 개발 인증서의 실제 Release 빌드·서명 검사와 재배치한 앱의 변환 검증을 통과했다. 이는 Developer ID 서명·공증 검증이 아니다. 위 기록의 이전 최종 비교 결과와 WARN·FAIL 한계도 그대로 유지하며 새 검증 결과로 재사용하지 않는다.

후속 변경으로 감시 폴더 실행·설정 UI를 연결하고, JPEG·PNG의 ICC 추적과 BMP 안전 처리를 보완했다. PDF의 단일 텍스트 상태 검증과 Markdown 조회 캐시 최적화도 통합했다. 임의 색 공간·폼 기본 색 공간 등 확인할 수 없는 PDF는 기존 PDFKit 속성 경로를 유지한다. SVG 상대 font shorthand 변경은 비교 품질이 낮아진 표본 때문에 통합하지 않았다. 후속 소스 `34bc0ae`의 SDK 접근 차단 clean build·테스트·개발 인증서 Release와 재배치 실행, 실제 849개·이미지 검증·순차 성능 측정을 완료했다. PDF TXT 최선 0.630초로 목표를 충족했고 Markdown TXT는 0.667초로 미달이다. 엄격 비교의 기존 실패는 그대로 남겼으며 [후속 검증 기록](engine-differential-triage.md#integrated-watch-icc-and-native-cancellation-follow-up-2026-10-25)에 결과·한계를 구분했다. 아래 `70fff7d` 수치는 앞선 단계의 기록이다. 현재 감시·취소·색상 처리 경계는 [아키텍처](../architecture.md)를 따른다. 앱 내 관리형 엔진 다운로드는 여전히 미구현이며, 전환 전 Mac host에도 설치 요청 API가 없었다.

실행 소스 `70fff7d`에서 arm64 SDK 접근 차단 clean build와 엔진 테스트(581개, 57개 skip, 실패 0), 별도 clean 환경 앱 테스트 74개, 기존 팀 개발 인증서의 실제 Release 빌드·서명 검사, 저장소·SDK 접근을 차단한 재배치 실행 22개 검사를 통과했다. 실행 환경은 M2 Max/macOS 27이며 물리 M1 또는 macOS 15 실행을 주장하지 않는다. Developer ID 서명·공증은 미검증이다. 실제 변환 비교와 남은 차이는 [최신 검증 기록](engine-differential-triage.md#apple-silicon-only-final-verification-2026-10-25)을 따른다.

## 과거 전환 계획과 단계별 결정 (2026-10-23)

이하 본문은 전환 전 구조, 당시 선택지·구현 결정·비교 수치와 전환 순서를 보존한 기록이다. C#·NuGet·.NET 빌드 단계, 대체 전후 설명과 당시 남은 한계는 현재 빌드 지침이나 최신 상태로 적용하지 않는다. 현재 상태는 위 절과 연결된 최종 통합 기록을 따른다.

작성 2026-10-23. FileToX의 C# helper(`EngineHost` + Filee `Core`·`Engines` + NuGet)를 Swift helper로 바꿔 개발·빌드·배포·실행에서 .NET을 없앤다. 이식 규칙은 [swift-engine-port.md](swift-engine-port.md)에 있다.

### 1. 전환 전 구조와 .NET 의존 (당시 기록)

- 앱(SwiftUI·AppKit)은 `Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine`을 실행하고 stdio NDJSON([host-wire-v1](host-wire-v1.md))으로 통신한다.
- helper는 C# `EngineHost/*.cs`(약 2,000줄)가 Filee `Core`(3,566줄)·`Engines`(33,000줄)와 NuGet 패키지를 참조하는 self-contained .NET 10 앱이다. 배포 helper는 약 190 MB이며 .NET 런타임·NuGet DLL·native dylib(ImageMagick, PDFium, Skia, HarfBuzz, Unhwp)를 포함한다.
- Xcode 빌드 단계가 매번 `Tools/build-engine-host.sh`를 호출하고, 이 스크립트가 엔진 변경과 관계없이 `~/.dotnet` SDK를 먼저 확인한다.

### 2. 실제로 지원·검증된 변환 기능

엔진 23개가 Filee `FormatRegistry`의 171개 형식을 다룬다. 실제 가능한 조합은 엔진 상태와 `RoutePlanner`(최대 3단계)가 정한다. 기존 기록(`EngineHost/IMPLEMENTATION.md`, README)으로 확인된 범위는 다음과 같다.

| 구분 | 내용 |
| --- | --- |
| 내장 엔진 실변환 20건 | png→jpg, heic→png, png→pdf, PDF 합치기, 2쪽 pdf→png, 다중 페이지 TIFF, ZIP 묶기(형식 모름·폴더 포함), zip→폴더, md→docx, docx→html/pdf/epub, txt→hwpx(한글·공백 경로), hwpx→hwp(rhwp), hwp→pdf, csv↔xlsx, svg→png, dxf→svg, ttf→woff2 |
| 선택 판정 2건 | mp4→mp3 사용 가능 여부와 FFmpeg 설치 안내, EPS의 Ghostscript 안내 |
| 추가 엔진 표본 11건 | Pandoc·LibreOffice·Calibre·FFmpeg 변환, 처리 중 취소(FFmpeg·LibreOffice), host 프로세스 그룹 종료, Pandoc 첨부 이미지 충돌 |
| Filee 테스트 | Core 164건 통과(패치 포함), Engines 445건 통과·3건 실패(이 Mac의 FFmpeg에 없는 인코더) |
| 앱 연동 | 홈·도넛 선택, 진행·취소, 최근 변환 이력, 프리셋·프로필·설정 저장, 언어 전환 |

전체 형식 조합은 위 표본 밖에 있다. 전환에서는 C# helper를 기준선으로 실행해 **모든 형식의 선택 결과(사용 가능한 출력 형식·프리셋)와 형식별 대표 변환 결과**를 기록하고 Swift helper와 비교한다(5절).

### 3. 엔진별 C# 의존과 대체 방법

| 엔진 id | C# 의존 | Swift 대체 | 난이도 |
| --- | --- | --- | --- |
| `magick` | Magick.NET(ImageMagick) | ImageIO·CoreGraphics, JPEG 쓰기와 8비트 RGB/회색조 읽기는 libjpeg-turbo, 크기 조정은 ImageMagick 방식 Swift 이식. CMYK/YCCK JPEG 등은 ImageIO로 읽는다. ImageIO가 쓰지 못하는 형식(PSB 읽기·쓰기, XCF 읽기, PPM 계열 세부 형식, ICO 크기 지정, TIFF 압축 방식)은 Swift 코덱으로 보완. 카메라 RAW는 LibRaw(4절) | 중 — **WebP·JPEG XL 쓰기는 4절** |
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
| `font` | 자체 코드 + Brotli | 컨테이너·글리프·WOFF2 변환은 Swift 이식, WOFF2 압축은 Google Brotli C 라이브러리(기존 품질 11 유지) | 중 |
| `email` | MimeKitLite | MIME 파서(다중 파트·인코딩·RFC 2047·문자 집합)를 Swift로 구현 | 중 |
| `ffmpeg` | 외부 FFmpeg | 같은 실행 파일 | 하 |
| `cad` | ACadSharp·SkiaSharp | DXF 읽기·쓰기, DWG 읽기(AC1014–AC1032)·쓰기(AC1032), 장면·렌더링을 Swift·CoreGraphics로 이식 완료. 세부는 4절 | 상 |
| `ebook` | 자체 코드 + ImageMagick·PdfSharp·PDFtoImage·SharpCompress | 이식 + ImageIO·PDFKit(쪽 편집)·PDFium(래스터)·7-Zip | 중 |
| `pandoc`, `ghostscript`, `calibre`, `libreoffice` | 외부 프로그램 | 기존 프로그램 유지. Calibre TCR 쓰기는 아래 압축 손상 우회 적용 | 하 |

Calibre의 TCR 쓰기는 기존 문서 해석·텍스트 작성기를 유지하면서 압축 직전 바이트를 확보하고 Swift TCR
압축기로 저장한다. Calibre 9.15.0 압축기의 내용 손상을 피하기 위한 변경이다. 선택한 `ebook-convert`의
심볼릭 링크를 해석한 디렉터리에 `calibre-debug`가 함께 있어야 한다. 없으면 완전한 Calibre 설치본을
선택하라는 오류를 내고 출력을 확정하지 않는다. 별도 시스템 Python은 필요 없다.

코어와 host도 Swift로 옮긴다: 형식 레지스트리, 프리셋·출력 규칙·이름 바꾸기, 프로필 선택, 경로 탐색(`RoutePlanner`·`ConverterCatalog`), 작업 큐와 출력 staging·확정(패치 0001), 설정·프리셋·프로필·이력 저장소(`UserDataStore`의 JSON 형식과 스키마 이전 그대로), 지역화, NDJSON 프로토콜·잠금·journal 정리.

### 4. 동등한 대체가 어려운 기능

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
- 만화 페이지·PDF 스캔 JPEG: Filee가 Skia로 인코딩하던 두 경로는 같은 libjpeg-turbo를 SkJpegEncoder 설정(3성분, 4:2:0, 느린 정수 DCT, 최적화 허프만 표, 밀도 없는 JFIF)으로 쓴다. 설치된 C# helper의 libSkiaSharp 결과와 바이트 단위로 같고, 동영상→PDF→CBZ/HWPX 3건이 PASS로 바뀌었다.
- SVG: macOS 내장 렌더러에 CSS·`tspan` 전처리를 더한다.
- 카메라 RAW: C# 앱과 같은 색을 낸다. C# 앱은 ImageMagick 7.1.2-32 Q8의 DNG 코더로 LibRaw 0.22.2를 썼고, Apple CIRAWFilter는 가장 잘 맞춘 설정도 평균 ΔE00 2.7 차이가 났다. 그래서 LibRaw 0.22.2를 CDDL-1.0으로 소스 포함해 빌드하고(`Vendor/LibRaw`, 아래 libjpeg-turbo로 `USE_JPEG`), ImageMagick과 같은 호출 순서·설정으로 현상한다(`Vendor/LibRaw/FileToX/develop.c`). 공개 표본 10개(손실 압축 DNG 2개 포함)가 모두 C# 출력과 픽셀이 같다. LibRaw가 모르는 카메라만 LibRaw처럼 맞춘 CIRAWFilter로 대신 현상하고 stderr에 남긴다. 고지는 `docs/upstream/LibRaw.*`이며 helper의 `Resources/Notices`에 들어간다.
- HWP/HWPX → TXT·MD·HTML: 공개 HWP 문서 20개로 Unhwp(A), rhwp 직접 내보내기(B), "rhwp로 HWPX 변환 + 이식한 Filee 읽기·작성기"(C)를 비교했다. C가 구조·그림·가독성에서 가장 낫고 HWP 3.x도 처리한다(A는 실패). 결정: C를 쓰고, 수식은 Unhwp의 수식→LaTeX 변환기(MIT)만 Swift로 옮겨 기존처럼 LaTeX로 낸다. 비교에서 나온 C의 문제(그림 실패, 목록 들여쓰기, 중첩 표·캡션·제목·머리말 누락, BMP 재압축, 셀 줄바꿈)를 수정하고 같은 표본으로 재검증했다. 결과·동작 변경·남은 차이는 [r3 구현·비교 보고서](swift-hwp-export-r3.md)에 있다.

- JPEG 2000 쓰기: ImageIO가 손실 품질 설정을 무시한다(q100 무손실은 정상). 결정: 수용하고 제한으로 기록한다.

**결정(2026-10-23, JPEG 쓰기·크기 조정):** C# 출력과 같게 만든다.

- JPEG 쓰기: C# helper의 ImageMagick 7.1.2-32 Q8이 쓴 libjpeg-turbo 3.2.0(`Magick.Native` 문자열로 확인)을 소스 포함해 빌드한다(`Vendor/libjpeg-turbo`, IJG 라이선스, SIMD 없음 — C 경로로도 C# 파일과 같다). `Vendor/libjpeg-turbo/FileToX/encode.c`가 ImageMagick `coders/jpeg.c`의 `WriteJPEGImage`를 Filee 설정대로 따른다: `jpeg_set_quality`(품질 미지정 92), 품질 90 이상 4:4:4·미만 libjpeg 기본 4:2:0, 품질 90 이하 빠른 정수 DCT(`JDCT_IFAST`), 기준선(progressive 아님), Huffman 표 최적화, 모든 화소가 R=G=B면 1성분 회색, JPEG 원본의 샘플링 계수 유지(`jpeg:sampling-factor` 속성), ImageMagick이 읽은 해상도·단위를 JFIF에(EXIF/TIFF 태그 우선, PNG pHYs·BMP는 px/cm, JFIF 그대로), EXIF·ICC·XMP 순서의 APP 표지. ImageMagick으로 JPEG를 쓰던 곳(이미지 변환·PDF/SVG/CAD 래스터 출력, PDF에 넣는 JPEG, 전자책 그림 변환)이 이것을 쓴다. C#이 Skia로 JPEG를 쓰던 곳(만화 PDF 쪽, PDF 스캔 쪽)은 같은 libjpeg-turbo의 Skia 설정 모드로 인코딩한다. 같은 화소에서 ImageMagick(C# helper의 `Magick.Native`)과 바이트가 같다: 그림 6개 × 품질 15개, C# 동영상 프레임 JPEG 3개.
- 크기 조정: ImageMagick `ResizeImage`(Q8)를 Swift로 옮긴다(`MagickResize`): 필터 선택(Lanczos, 알파·팔레트·확대면 Mitchell, ICNS는 명시한 Lanczos), SincFast·CubicBC, 지지 폭·blur, 가로/세로 처리 순서, 정규화·알파 가중, 단계 사이와 결과의 8비트 반올림, 그리고 C# helper를 컴파일한 clang이 합친 곱셈-덧셈(FMA). 무작위 그림 84건·명시 Lanczos 16건·C# ICO 프레임에서 표본이 같다. 회색 PNG·팔레트 그림은 ImageMagick에서 PseudoClass라 Mitchell이 된다.
- JPEG 읽기 후속 수정: 기존 libjpeg-turbo 3.2.0으로 8비트 RGB/회색조 화소를 읽고 ImageIO의 ICC·EXIF 방향·해상도·메타데이터는 유지한다. RGB 샘플링·progressive·회색조·프로필·방향을 포함한 비-CMYK 래스터 24건과 JPEG 재인코딩 6건은 C#와 화소가 같다. CMYK/YCCK·고정밀도·지원하지 않는 색 공간은 ImageIO를 유지한다. CMYK는 여전히 C#와 색이 다르며, 원본 주석(COM)·IPTC 보존과 CMYK JPEG 출력도 미해결이다. Grayscale 옵션 뒤 정사각형 ICO 크기 조정은 Mitchell(ImageMagick은 Lanczos)이다.

그 밖에 PDF 텍스트 배치(PdfPig→PDFKit), HTML 파싱(AngleSharp→libxml2), Markdown 확장(Markdig→Swift 파서)은 결과가 미세하게 달라질 수 있어 비교 검증으로 확인한다. 앱에 연결되지 않은 Filee 기능(앱 내 엔진 다운로드 `EngineInstaller`, 감시 폴더 실행 `FolderWatcher`)은 설정 데이터만 보존하고 실행 코드는 옮기지 않는다.

### 5. 전환 순서와 검증

1. **기반**: 계약(형식·프리셋·변환기 프로토콜), ZIP·XML·인코딩·바이너리·이미지 정보·경로 도구, 외부 프로그램 실행기(프로세스 트리 종료·타임아웃·취소), 엔진 위치 탐색, 공유 문서·표 모델. — 완료(테스트 19건 통과).
2. **기준선**: 설치된 C# helper로 전체 선택 결과와 형식별 대표 변환을 기록하는 비교 도구(`Tools/engine-compare/`).
3. **코어·host**: 작업 큐·staging·저장소·프로토콜. 기존 사용자 데이터(`~/Library/Application Support/FileToX/core`)의 사본을 읽고 다시 저장해 C# 결과와 비교한다.
4. **엔진**(병렬): 이미지·PDF·벡터 → 문서(HWPX·DOCX·Office·전자책·Markdown·HTML·메일) → 글꼴·압축·미디어 → CAD.
5. **통합**: 엔진별로 C# 기준선과 같은 입력을 변환해 상태·출력 이름·형식별 특성(이미지 크기·유사도, PDF 쪽수·텍스트, 압축 목록, 미디어 코덱·길이)을 비교한다.
6. **정리**: C# 코드·NuGet·.NET 빌드 단계·문서를 지운다. Xcode는 Swift helper를 빌드해 같은 위치에 넣는다.
7. **격리 검증**: `~/.dotnet`·`~/.nuget`을 읽을 수 없는 sandbox와 정리된 환경 변수로 Xcode 클린 빌드·테스트를 실행하고, 앱 번들에 .NET 파일이 없음을 확인한다. 홈의 .NET 폴더는 지우지 않는다.
