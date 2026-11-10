# C# 변환 엔진의 Swift 전환 기록

## 현재 상태 (2026-11-06)

앱은 SwiftUI·AppKit, host는 `Sources/EngineMain`에서 시작하는 Swift 실행 파일이다. 앱 통신·모델은 `Sources/Core`(`FileToXCore`), host·변환 코어·엔진은 `Sources/Engine`(`FileToXEngineKit`)에 있다. `Package.swift`가 공통 빌드 정의이며 `project.yml`과 staging 도구가 앱·helper 번들, AVIF 보조 실행 파일, 서명·고지를 구성한다. 현재 빌드·실행에는 .NET SDK·런타임·NuGet 복원이나 과거 C# host가 필요 없다.

지원 범위는 **Apple Silicon M1 이상(arm64), macOS 15 이상**이다. 앱·helper·테스트는 `ARCHS: arm64`이고 staging도 다른 아키텍처를 거부한다. Xcode 명령에는 `-destination 'platform=macOS,arch=arm64' ARCHS=arm64`를 함께 지정한다. Intel·Rosetta 실행은 지원·검증 범위 밖이다. 구체적인 명령과 데이터·취소·출력 안전은 [README](../../README.md), [아키텍처](../architecture.md), [패키징](macos-packaging.md)을 따른다.

내장 엔진은 Swift 코드·macOS 프레임워크·네이티브 라이브러리를 사용하며 rhwp·7-Zip·FFmpeg는 번들 실행 파일이다. Pandoc·LibreOffice·Calibre는 검증된 고정 arm64 패키지의 관리형 설치 또는 사용자 지정·시스템 사본을 사용한다. 사용자 지정 FFmpeg 사본은 번들보다 우선하며 Ghostscript는 사용자 지정·시스템 사본을 사용한다. 감시 폴더 실행·설정 UI와 64 MiB까지의 분할 host 응답도 연결돼 있다. 현재 버전의 경계를 아래 과거 계획의 미구현 설명으로 대체하지 않는다.

JPEG 2000 쓰기는 OpenJPEG, PDF 래스터는 PDFium, 제한된 SVG 기본 도형은 Skia bridge를 사용한다. 나머지 SVG 기능·벡터 PDF는 CoreSVG를 유지하며 상대 font shorthand·세로쓰기·방향·상속 정규화를 보완했다. textPath의 CoreText 경로 배치도 추가해 보존된 63개 중 두 사례를 개선하고 61개는 유지했다. 두 실제 앱 출력은 흰 배경 보충 검사 기준에는 아직 못 미친다. 지원하지 않는 양방향 선언 등의 전체 텍스트 fallback은 CoreSVG의 기존 경로 텍스트 문제를 해결하지 않는다. PDFium universal 원본과 Skia의 출처·고지는 보존하고 배포 사본은 arm64로 한정한다.

이미지 메타데이터는 출력 크기·방향·DPI에 맞춘 EXIF, PSD/PSB의 허용된 EXIF·XMP·IPTC·문서 리소스, PNG 주석, 추가 입력 형식의 ICC 추적과 페이지별 TIFF 정보를 보완했다. 비-sRGB TGA는 sRGB로 변환한 뒤 프로필 없이 쓴다. 제한된 BMP V5 내장 ICC를 지원하며 링크된 프로필은 읽지 않는다. 모든 형식·태그·색 공간의 무손실 보존을 보장하지는 않는다.

AVIF는 libavif 1.4.2·libaom 3.14.1을 사용한 별도 arm64 인코더를 추가했다. ImageIO 결과와 후보를 비교해 정해진 색·알파 표본 오차와 메타데이터 조건을 통과할 때만 후보를 쓴다. 긴 EXIF 손실 때 ImageIO 결과를 유지하며, Aux 렌즈 태그와 중첩 배열·구조·한정자 보존도 보완했다. 한정자의 namespace·이름 비교 누락을 수정한 뒤 독립 재검토를 통과했다. 비교 대상은 ImageIO가 병합해 읽은 메타데이터이므로 raw Exif/XMP 전체의 동등성을 뜻하지 않는다. 인코더는 2~8스레드를 사용하지만 후보 생성·디코딩의 추가 시간·메모리와 Q8 차이는 남아 있다. 입력 대비 개선 때문에 C# 기준선과의 비교가 FAIL이 되는 영상 프레임 사례도 별도 근거와 함께 보존한다.

Markdown 최적화는 기존 AST와 출력 의미를 유지하며 중복 탐색·중간 할당을 줄였다. PDF 주석·액션·폼과 지원하는 바이너리 형식의 독립 의미 검사를 추가했고, UUID·메타데이터·리소스 순서·자동 표지 등 새로 드러난 엄격 차이는 그대로 기록한다. 본문과 메타데이터 텍스트의 실패 이유를 구분하며 판정 기준은 유지한다. Calibre의 읽기 순서 밖 HTML에도 CSS 처리를 적용해 LIT→AZW3 목차 서식을 복구했고 최종 출력의 본문·링크를 독립 readback으로 확인했다. libmobi C 라이브러리는 진단에만 사용하며 앱 의존성에 추가하지 않았다.

2026-10-27~28 후속 작업은 혼합 PDF의 텍스트·스캔 이미지·기존 OCR 층을 EPUB·FB2·HTMLZ·TXTZ·ODT에서 페이지 순서대로 보존하고, 실제 빈 페이지는 텍스트 경로에 남긴다. 투명 OCR 글자만 있는 페이지는 전체 페이지 그림을 담아 마스크·벡터 윤곽을 보존한다. 보이는 글자가 있는 페이지의 벡터 그림·셰이딩·인라인 이미지·스텐실 마스크는 글자를 뺀 PDFium 렌더링 한 장으로 종이 위 원래 위치의 글자 뒤에 담고 글자는 한 번만 텍스트로 남기며, PDFKit 병렬 읽기의 글꼴 예외를 공유 잠금으로 막는다. 새 OCR은 수행하지 않으며 TXT는 추출 가능한 글자만 담는다. 위치·grid 정보가 빠진 PPTX 표, 그룹 확대율과 병합 셀 위치, FB2 텍스트 상자, 생성 PDF를 통한 그림 문서 경로와 짧은 TS/M2TS 포스터 추출도 보완했다. PML은 한글·일본어 등 BMP 문자를 보존하고 비 BMP 문자는 출력 전에 거부한다. 동반 PNG 폴더 게시와 대괄호 작업 경로를 처리하고 이미지 축소·팔레트 변환을 끈다. SVG의 제한된 가로 글자는 기존 윤곽선을 유지하며 PDF 검색·선택과 TXT 추출을 지원한다. 세로쓰기·textPath·숨김·clip/mask 등과, 나중에 그린 것이 일부라도 덮을 수 있거나 영역을 측정하지 않는 그림이 뒤에 오는 글자는 검색 글자를 더하지 않으며 문서의 편집 가능한 텍스트 복원은 범위 밖이다. AVIF는 ImageIO의 색·알파 표본 오차가 모두 0이면 추가 인코딩을 생략하고 기존 품질·메타데이터 가드는 유지한다. 고정 소스 arm64 FFmpeg를 앱에 번들하고 필수 인코더·muxer 사전 검사를 적용한다. staging은 `FILETOX_FFMPEG_BUNDLE` 또는 기본 `build/ffmpeg/ffmpeg`의 선언된 버전·플랫폼·고정 소스 목록, 번들 자체 출처 기록의 실행 파일 해시, 고지의 존재를 확인한다. 소스 ZIP·레시피 해시 검증과 번들 출처 인증은 하지 않는다. 관리형 FFmpeg 다운로드는 제공하지 않는다. 실행 근거와 한계는 [최종 후속 검증](engine-differential-triage.md#remaining-work-final-verification-2026-10-28)과 [텍스트 페이지 그림·가려진 SVG 글자](engine-differential-triage.md#priority-one-integration-review-2026-10-29)를 따른다.

영상 길이 수정 전인 2026-10-29 PDF·SVG 검토 시점의 849건은 **829건 완료·20건 실패**, harness·검사 오류 0이며 모든 사례가 2026-10-28 최종 상태를 유지했다(기존 성공 786건 유지, 그 회차에 복구한 43건 완료). 같은 판독 정책의 엄격 C# 비교는 **484 PASS / 260 WARN / 105 FAIL**이며 성공으로 바뀐 43건도 상태 차이로 FAIL에 포함한다. 위임 구현 검증과 달리 PDB→RB는 다시 FAIL, LRF→HTMLZ는 WARN에서 PASS가 됐다. 두 경로는 리뷰에서 바꾸지 않았으므로 수정 성과로 세지 않으며, 105개 FAIL의 사례 ID는 2026-10-28 최종 비교와 모두 같다. 단일 프레임 GIF→WebM은 실제 평균 프레임률을 명시하고, 가변 GIF의 다섯 영상 형식에서 색 변화 시점·0.6초 길이 보존을 확인했다. 그 시점의 소스로 새 Debug 앱을 빌드하고 AppModel의 파일 선택·옵션 저장·AMR 변환·취소·OGG 재시도·이력·원본 보존, 서명·arm64 구성을 확인했다. 실제 GUI 조작과 Xcode 호스트 XCTest 실행을 검증한 것은 아니다. 그 시점 host의 rich 변환 44건(기존 26건, 그림 텍스트 페이지·스텐실 마스크·가려진 SVG 글자 12건, 루트 선·상대 이미지 좌표 6건)이 통과했고, 그 시점의 전체 Swift 검사는 엔진 793개(15 skip)·Core 18개, 실패 0개다. 그 시점의 PDF 텍스트 검사는 기존 출력 바이트를 유지하며 순차 5회 모두 0.84초 목표를 충족했다(0.673~0.772초, 중앙값 0.701초). 자세한 결과와 한계는 [PDF·SVG 검토 검증](engine-differential-triage.md#priority-one-integration-review-2026-10-29)을 따른다.

2026-10-29 영상 길이 수정은 저속 입력의 TS·M2TS·MPG·MXF 마지막 프레임 표시 시간을 채우고, 평균보다 짧은 간격의 색 변화에는 입력의 명목 프레임률도 반영한다. 원래 ICNS의 M2TS·MPG·MXF 세 출력은 파일 길이와 디코딩 표시 시간이 모두 0.1초다. 당시 영상 수정 소스의 집중 검사 **56개**, 실제 변환 **33건**이 통과했고, 849건은 **829건 완료·20건 실패**, harness·검사 오류 0이다. 같은 기준의 엄격 C# 비교는 **482 PASS / 241 WARN / 126 FAIL**이며 프레임률 항목 차이로 새 FAIL 22건이 추가됐다. 변경하지 않은 전자책 경로의 판정 변동 2건도 있으며 수정 성과로 세지 않았다. 변환 완료와 동등성은 구분한다. 프레임 단위로 맞출 수 없는 0.13초 입력은 약 0.1668초로 올림되며, 초소형 MPG의 파일 길이 추정값은 실제 표시 시간보다 짧을 수 있다. 전체 검사·앱/AppModel·PDF 성능은 앞선 PDF·SVG 검토 시점의 결과이며 이번 소스로 반복하지 않았다. [영상 길이 검증](engine-differential-triage.md#slow-media-duration-verification-2026-10-29).

2026-10-29 기존 품질 차이 검토에서 DWG 출력의 R2010+ 여유 공간 구조와 페이지 맵 개수를 수정했다. PalmDoc(`.pdb`) 출력은 Windows-1252를 유지하며 한글·일본어·이모지 등 표현할 수 없는 본문 글자가 있으면 출력 할당 전에 명시적으로 실패하고 EPUB 사용을 안내한다. 서유럽 문자는 여러 레코드에 걸친 긴 본문에서도 보존한다. 기존 48건은 생성값 35건·앞선 보존 개선 9건·공백/리소스 순서 각 1건·DWG 구조 2건으로 분류했으며, 엄격 비교의 판정과 임계값은 바꾸지 않는다. [기존 품질 차이·내용 손실 검토](engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

2026-10-29 DWG·PDB 수정 소스의 전체 검사는 **엔진 800개(15 skip)·Core 18개, 실패 0개**다. 849건은 **822건 완료·27건 실패**, harness·검사 오류 0이며, 직전과의 상태 변화는 문자 손실을 막기 위해 거부한 PDB 7건뿐이다. 같은 정책의 엄격 비교는 **474 PASS / 241 WARN / 134 FAIL**이고 PDB 거부 7건과 변경하지 않은 PDB→SNB의 생성 그림 판정 변동 1건이 새 FAIL이다. DWG 실제 출력 두 건의 독립 판독, 새 Debug 앱 빌드·서명·arm64 구성과 AppModel 변환·취소·재시도·이력·원본 보존도 확인했다. 실제 GUI·Xcode 호스트 XCTest 실행·실기기·배포 검증과 앞서 기술한 영상·PDF·SVG 한계는 남아 있다. [현재 검증](engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

2026-11-02 PDF 보존 수정은 추출하지 못한 글리프를 그림층에 남기고 합자·문자 묶음 뒤의 글자 누락과 큰 좌표로 인한 종료를 보완한다. 최종 소스의 전체 검사는 **엔진 812개(15 skip)·Core 18개, 실패 0개**이며 실제 리치 변환 94건과 추가 경계 사례 8건이 통과했다. 849건은 사례별 상태 변화 없이 **822건 완료·27건 실패**이고, 같은 현재 검사 환경의 엄격 비교는 이전 출력 재판독과 새 출력 모두 **474 PASS / 241 WARN / 134 FAIL**다. 새 Debug 앱 빌드·서명·arm64 구성·AppModel 흐름과 200쪽 TXT의 0.84초 성능 목표도 확인했다. 150dpi 그림·기울임/겹침 판별·원본 그림 해상도·합자 뒤 배치와 실사용/배포 검증 한계는 [2026-11-02 PDF 검증](engine-differential-triage.md#pdf-text-preservation-integration-2026-11-02)을 따른다.

2026-11-06 PDF 후속 수정은 추출한 단어와 글리프의 글자를 대조해 기울임·겹침에서 빠지던 글자를 보존하며, 한글 음절·말줄임표의 호환 분해도 모두 계산한다. 추출 못한 글자 때문에 그림층을 만드는 페이지에서는, 회전하지 않은 별도 사진이 합성이 필요하지 않을 때 원본 바이트와 해상도를 유지한다. 마스크·그래픽 상태·클리핑·폼·이미지 변형·겹침·페이지 밖 그림이나 회전 페이지는 합성 그림에 남기는 보수적인 경로를 따른다. 보존 글자는 150dpi 픽셀이며 겹친 획의 작은 조각·합자 배치·기존 180도 페이지의 글자와 그림 좌표 차이는 남는다. 그림층을 추가하지 않는 일반 그림 추출 경로의 기존 마스크·잘림 한계는 별도다. 최종 소스의 **엔진 821개(15 skip)·Core 18개 검사는 실패 0개**이며, **리치/TXT 변환 142건·경계 사례 25건·검토 재현 변환 36건**이 통과했다. 849건은 사례별 상태 변화 없이 **822건 완료·27건 실패**, 엄격 비교는 같은 FAIL 집합의 **474 PASS / 241 WARN / 134 FAIL**다. 새 Debug 앱의 서명·arm64 구성과 AppModel 흐름도 통과했으며, DOCX·EPUB에서 원본 400×400 사진과 누락 글자 그림을 확인했다. [최신 PDF 검증과 한계](engine-differential-triage.md#pdf-geometry-integration-2026-11-06).

2026-11-06 엄격 FAIL 134건을 재분류한 결과 C#보다 나빠진 사례는 찾지 못했다. C# 실패를 Swift가 완료한 43건, 영상 마지막 프레임 표시 시간 수정 30건, PDB 한글 거부 7건, 슬라이드 글자 보존 6건, 기존 48건이다. 그림·PDF·SVG·CAD의 오디오 출력과 영상의 TXT 출력은 결과가 나올 수 없어 경로 계획에서 제외했다. PDF→TXT는 글자가 없는 페이지를 macOS Vision으로 읽어 그림·만화의 TXT를 다시 허용한다. 전체 검사는 **엔진 827개·Core 18개, 실패 0개**, 849건은 **822건 완료·27건 실패**(경로 없음 15·PDB 7·글자 없는 그림/스캔 TXT 5)이며 다른 834건의 상태는 그대로다. 엄격 비교는 오류 키가 바뀐 15건 때문에 **460 PASS / 240 WARN / 149 FAIL**이다. [재분류·대상 제외·OCR](engine-differential-triage.md#unreachable-targets-2026-11-06).

이전 통합 실행 소스 `6c150981`에서 SDK 접근 차단 Swift 엔진 750개(14개 skip)·Core 18개, 별도 프로세스 트리 검사, Xcode 클린 빌드·엔진 750개(59개 skip)·앱 81개와 개발 인증서 Release·재배치 23개 검사를 완료했다. 격리 HOME에서의 서명 사전 검사 실패는 기존 인증서·키체인을 명시한 서명으로 복구했고 원래 기록도 보존했다. 아래 849건·성능·Xcode·서명 검증은 이 이전 소스의 결과이며 후속 수정의 전체 재검증 수치가 아니다.

당시 849건은 786건 완료·기존과 같은 63건 실패이며 harness·검사 오류는 0이다. 확장 의미 검사의 C# 비교는 **598 PASS / 203 WARN / 48 FAIL**이다. 같은 현재 판독기에서 엄격 FAIL 집합은 그대로이고 생성 표지 한 건만 PASS→WARN이다. 순차 Markdown TXT·PDF TXT 중앙값은 각각 **0.542초·0.631초**이며 0.60초·0.84초 목표를 각각 5회 모두 충족했다.

상세 근거와 C/C++·resvg 대안, AVIF 전체 비용은 [최신 품질 후속 검증](engine-differential-triage.md#quality-follow-up-and-alternatives-2026-10-26)을 따른다. 실행 환경은 M2 Max/macOS 27.0.1이며 물리 M1/macOS 15 증거가 아니다. Developer ID 서명·공증, SMB/exFAT/TCC·실제 로그인/알림 검증은 남아 있다.

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
| `magick` | Magick.NET(ImageMagick) | ImageIO·CoreGraphics, JPEG 쓰기와 8비트 RGB/회색조/CMYK·YCCK 읽기는 libjpeg-turbo, 크기 조정은 ImageMagick 방식 Swift 이식. 고정밀·미지원 색 모델과 네이티브 디코딩 실패는 ImageIO로 읽는다. ImageIO가 쓰지 못하는 형식(PSB 읽기·쓰기, XCF 읽기, PPM 계열 세부 형식, ICO 크기 지정, TIFF 압축 방식)은 Swift 코덱으로 보완. 카메라 RAW는 LibRaw(4절) | 중 — **WebP·JPEG XL 쓰기는 4절** |
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
| `pandoc`, `ghostscript`, `calibre`, `libreoffice` | 외부 프로그램 | 기존 프로그램 유지. Calibre는 아래 목차 스타일 보존·TCR 압축 손상 우회 적용 | 하 |

Calibre의 TCR 쓰기는 기존 문서 해석·텍스트 작성기를 유지하면서 압축 직전 바이트를 확보하고 Swift TCR
압축기로 저장한다. Calibre 9.15.0 압축기의 내용 손상을 피하기 위한 변경이다. 모든 Calibre 변환에서는
읽기 순서 밖의 목차 등 HTML 문서도 기존 CSS 처리기에 전달해 스타일시트 교체 때 서식이 사라지는 것을
막는다. 실제 읽기 순서와 본문의 글꼴 기준 크기는 유지하며, LIT → EPUB → AZW3처럼 여러 단계를 거치는
경우에도 매 단계 적용한다.

선택한 `ebook-convert`의 심볼릭 링크를 해석한 디렉터리에 `calibre-debug`가 함께 있어야 한다. 없으면
완전한 Calibre 설치본을 선택하라는 오류를 내고 출력을 확정하지 않는다. 별도 시스템 Python은 필요 없다.
CSS 보완은 자식 프로세스에서만 적용하는 Calibre 내부 API 패치이며, 검증한 버전은 번들의 9.15.0이다.
사용자가 선택하는 다른 버전까지 호환성을 보장하지 않으므로 Calibre 갱신 시 다시 검증해야 한다.

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
