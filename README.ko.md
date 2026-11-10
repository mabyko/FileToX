# FileToX

[English](README.md) | [한국어](README.ko.md) | [日本語](README.jp.md)

FileToX는 [Filee](https://github.com/KnifeLemon/Filee)에서 영감을 받아 만든 Mac 전용 파일 변환 앱이다. 파일을 놓고 원하는 형식을 고르면 변환할 수 있다.

SwiftUI와 AppKit으로 만들었으며 Apple Silicon M1 이상(arm64), macOS 15 이상을 지원한다. Intel Mac·Rosetta 실행과 그 검증은 지원 범위에 포함하지 않는다. 기본 언어는 영어이고 한국어와 일본어도 지원한다.

## 20초로 보는 FileToX

[![Finder에서 Option 키로 PNG를 드래그하고 JPG에 드롭하는 FileToX 시연](docs/media/filetox-demo.gif)](docs/media/filetox-demo.mp4)

[20초 소개 영상 보기](docs/media/filetox-demo.mp4) · Finder Option 드래그를 실제로 촬영한 영어 자막의 무음 영상이다.

FileToX를 메뉴 막대에서 실행해 둔 채, Finder에서 파일을 드래그한 뒤 Control(⌃)을 누른다. 원형 메뉴의 변환 형식에 드롭하면 된다. 앱의 메인 창은 닫아둬도 된다. **설정 → 호출 키**에서 Control·Option·Shift·Command를 조합하고 문자·숫자·기능 키·방향 키·스페이스를 추가할 수 있다. **저장**을 누르면 이 Mac에 유지된다. 활성화된 macOS 시스템 단축키와 Finder 드래그 동작이 겹치면 경고를 표시하며, 다른 앱이 등록한 단축키는 검사 범위에 포함되지 않는다.

## 기능

- Finder에서 파일을 드래그하며 설정한 호출 키(기본값 Control)를 누르거나, 앱의 홈에서 파일·폴더와 프리셋을 선택해 실행하거나 원형 변환 메뉴를 연다.
- 171개 형식과 23개 엔진으로 이미지·문서·영상·음성·압축 파일을 다룬다.
- 프리셋과 원형 툴바를 편집하고, 변환한 파일의 저장 위치를 지정한다.
- 진행 상황을 확인하고 작업을 취소하거나 실패한 변환을 재시도한다. 최근 변환도 다시 볼 수 있다.
- 영어·한국어·일본어를 선택하고, macOS 색상 선택기로 강조색을 바꾼다.
- 원본 파일을 보호하고, 이름 충돌과 여러 결과를 처리한다.

## 앱 화면

![파일 선택과 최근 변환을 보여주는 FileToX 홈 화면](docs/images/filetox-home.png)

<table>
<tr><th>원형 변환 메뉴</th><th>테마와 강조색</th></tr>
<tr><td width="40%" align="center"><img src="docs/images/filetox-radial.png" width="340" alt="원형 변환 메뉴"></td><td width="60%"><img src="docs/images/filetox-theme.png" width="620" alt="테마와 강조색"></td></tr>
</table>

홈·원형 메뉴는 격리된 엔진 데이터 폴더로 실행한 네이티브 SwiftUI 화면이다. 테마 화면은 이전 영어 Release 빌드에서 촬영했다.

## 사용 방법

1. 홈 화면에 파일을 놓거나 파일·폴더를 선택한다.
2. 홈에서 프리셋·파일 도구를 골라 실행하거나 원형 메뉴를 연다. **모든 출력 형식**에서 원하는 형식을 선택할 수도 있다.
3. 원본 폴더 또는 지정한 출력 폴더에서 결과를 확인한다.

첫 실행에는 Finder 드래그 호출에 쓰는 손쉬운 사용 권한 안내가 뜨고, 시스템 설정에서 돌아오면 허용 여부를 확인한다. **나중에**를 선택하면 홈에서 바로 변환할 수 있고, **호출 키 → 설정 방법 보기**에서 안내를 다시 열 수 있다. 앱에 네이티브 변환 구성 요소를 포함하며 .NET 런타임을 사용하지 않는다.

**설정 → 일반**에서 로그인 시 자동 실행, 메뉴 막대 아이콘 표시, 로그인 시 메인 창 열기, 완료·실패 알림을 각각 설정할 수 있다. 이 옵션은 즉시 적용된다. 자동 실행과 알림은 기본으로 꺼져 있고 메뉴 막대 아이콘은 켜져 있다. 아이콘을 숨겨도 드래그 호출은 유지되며, FileToX를 다시 실행하면 설정에 접근할 수 있다. 직접 실행하면 항상 메인 창이 열린다. 알림을 클릭하면 Finder에서 결과를 표시하고 결과가 없으면 앱을 연다. 일부 실패는 실패 알림 설정을 따르며 취소한 작업은 알리지 않는다. **설정 → 호출 키 → 드래그 호출 제외 앱**에서 앱을 추가·제거하면 즉시 적용되며, 해당 앱에서 시작한 드래그에는 원형 메뉴가 나타나지 않는다. 자동 실행 승인과 알림 권한이 필요하면 시스템 설정으로 이동할 수 있다.

등록된 모든 형식 사이의 변환을 보장하지는 않는다. 변환 경로 탐색기가 입력·엔진 상태에 따라 사용 가능한 프리셋과 출력 형식을 판단한다. 읽기 전용 형식 58개는 출력에 나타나지 않는다. 설치되지 않은 엔진과 macOS에서 불가능한 경로는 이유를 표시한다.

기본 번들에는 내장 라이브러리와 rhwp·7-Zip·FFmpeg를 포함한다. **변환 엔진 → 관리형 엔진**에서 고정 버전의 arm64 Pandoc·LibreOffice·Calibre를 FileToX 전용으로 내려받을 수 있다. 설치 전에 크기와 SHA-256을 확인하며 진행률과 취소를 제공한다. 기존 엔진 폴더는 보존하고 **외부 엔진 실행 파일**에서 지정한 사본을 우선 사용한다. FFmpeg는 지정한 사본이 번들보다 우선하며, Ghostscript는 시스템 설치나 지정한 사본을 사용한다. 앱 종료는 진행 중 다운로드를 취소하고 정리를 기다린다. 중단된 다운로드 이어받기는 지원하지 않는다.

변환 전에 선택한 FFmpeg의 필수 인코더와 출력 형식을 검사한다. 기능이 빠졌으면 해당 기능을 오류에 표시하고 기존 출력은 보존한다. 아래의 고정 소스 빌드 방법으로 Apple Silicon용 FFmpeg를 만들 수 있으며, 관리형 다운로드에는 아직 포함하지 않는다.

PDF를 EPUB·FB2·HTMLZ·TXTZ·ODT로 변환하면 텍스트와 스캔 이미지를 페이지 순서대로 보존한다. 텍스트·스캔이 섞인 문서와 기존 OCR 텍스트도 처리한다. 투명한 OCR 글자만 있는 페이지는 전체 페이지 그림도 함께 담는다. 텍스트만 있는 PDF는 텍스트 경로를 유지하고 빈 페이지 때문에 이미지 경로로 바꾸지 않는다. 이 형식들은 스캔 페이지를 그림으로 담고 인식한 글자를 더하지 않는다. TXT는 스캔·그림처럼 글자가 없는 페이지를 macOS 글자 인식(Vision)으로 읽는다. 인식 언어는 Mac 언어 순서의 첫 한국어·일본어·중국어와 영어이며, 읽을 글자가 없을 때만 실패한다.

출력은 각 최종 저장 폴더의 숨김 작업 폴더에 쓴 뒤 결과별로 게시한다. 원본 파일은 Overwrite에서도 보호하고, 기본 충돌 정책은 새 이름이다. 여러 결과의 게시 중 실패하면 이미 게시한 결과를 정확히 보고한다. 전체 묶음을 한 번에 되돌리는 원자성을 약속하지 않는다. 데이터는 `~/Library/Application Support/FileToX/{core,engines,tmp}`로 분리한다.

<details>
<summary>개발·빌드 방법과 검증 기록</summary>

## 빌드와 실행

Xcode 27 / Swift 6.4, XcodeGen 2.46 이상을 사용한다. 빌드 스크립트는 Python 3 표준 라이브러리를 쓰며, 번들 FFmpeg 빌드에는 CMake와 pkg-config도 필요하다. 앱과 변환 helper는 Swift·네이티브 라이브러리로 빌드하며 .NET SDK·런타임·NuGet 복원이 필요 없다.

현재 앱 버전은 **0.0.1 (빌드 2)**이며, 아직 출시하지 않은 내부 개발 버전이다. 버전은 `project.yml`의 `MARKETING_VERSION`과 `CURRENT_PROJECT_VERSION`에서 관리하고, 생성된 Info.plist와 두 정보 화면이 이 값을 사용한다. 같은 버전의 새 빌드는 빌드 번호를 올리고, 버전을 바꾸면 빌드 번호는 1부터 시작한다. 버전을 수정한 뒤 `xcodegen generate`를 실행한다. Git 태그(`v0.0.1`)와 GitHub Release는 배포할 때 별도로 만든다. 내장 엔진 호스트는 자체 버전을 유지한다.

첫 앱 빌드 전에 FFmpeg를 새 작업 폴더에서 한 번 빌드하고 이후에는 검증된 번들을 재사용한다.

```sh
python3 Tools/build-ffmpeg.py --work "$PWD/build/ffmpeg" --jobs 6
xcodegen generate
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Debug/FileToX Dev.app'
```

Xcode는 루트 `Package.swift`의 엔진·Core 제품을 사용하고 Swift helper·PDFium·번들 도구를 서명해 포함한다. 앱·helper·테스트는 arm64를 대상으로 하며 다운로드 도구는 x64를 거부한다. 첫 패키지 해석에서 고정 버전 libwebp·libjxl 소스를 받고, rhwp·7-Zip은 검증된 캐시가 없을 때만 받는다. LibRaw·libjpeg-turbo·OpenJPEG 소스, 원본 universal PDFium dylib와 arm64 전용 Skia SVG 정적 라이브러리를 보관한다. staging은 PDFium·번들 도구의 arm64만 추출한 뒤 서명하며 검증된 원본은 바꾸지 않는다. Skia는 제한된 기본 도형에 사용하고 나머지 SVG 기능·벡터 PDF는 CoreSVG를 유지한다. 출처와 라이선스 고지는 보존한다. 고정된 libavif 1.4.2·libaom 3.14.1 정적 라이브러리를 사용하는 arm64 `FileToXAvifEncoder` 도구와 고지도 함께 포함한다.

```sh
swift build -c release --product FileToXAvifEncoder
swift build -c release --product FileToXEngine
python3 Tools/fetch-optional-engines.py --help
```

staging은 번들 최상위·`bin`의 허용 목록 밖 파일과 번들 안의 심볼릭 링크를 거부하고 `ffmpeg`·`ffprobe` 두 실행 파일과 라이선스 고지·`BUILDING.txt`만 포함한다. 로컬 빌드 경로를 포함한 전체 출처 기록은 로컬 빌드 산출물에 남긴다.

FFmpeg 레시피는 새 작업 폴더에 고정 소스로 앱 필수 코덱과 AV1 소프트웨어 디코더를 빌드하고 `ffmpeg/bin/{ffmpeg,ffprobe}`, 실행 파일·소스 ZIP과 출처 기록을 만든다. 앱 staging의 기본 경로는 `build/ffmpeg/ffmpeg`이며 선언된 버전·플랫폼, 고정 소스 목록, 번들 자체 출처 기록에 적힌 실행 파일 해시, 고지 파일의 존재를 확인한 뒤 포함한다. 이는 내부 일치 검사이며 소스 ZIP이나 레시피 해시를 검사하거나 번들 출처를 인증하지 않는다. 다른 위치의 검증된 빌드를 재사용하려면 Xcode 실행 시 `FILETOX_FFMPEG_BUNDLE`을 해당 `ffmpeg` 폴더로 지정한다. 시스템 설치나 관리형 다운로드 설정은 바꾸지 않는다.

```sh
FILETOX_FFMPEG_BUNDLE="$PWD/build/ffmpeg-new/ffmpeg" xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData build
```

개발 식별자는 `forked.filetox.local.dev`, Release는 `forked.filetox.local`이다. 개인 설정은 Git에서 제외하는 `Config/Local.xcconfig`에 둔다. Debug·Release의 기본 서명은 로컬 ad-hoc용이다. arm64 Release는 기존 팀 개발 인증서의 실제 Xcode 빌드·deep/strict 서명 검사와 저장소·.NET SDK 접근을 차단한 재배치 실행 23개 검사를 통과했다. Developer ID 서명·공증은 미검증이다. 검증 환경은 M2 Max/macOS 27이며 물리 M1 또는 macOS 15 실행 결과는 아니다. 범위와 남은 차이는 [최신 검증 기록](docs/design/engine-differential-triage.md#remaining-work-integration-2026-10-26)을 따른다.

## 지원하지 않는 변환

아래 대상은 목록에 나오지 않거나, 파일 내용 때문에 오류로 끝난다. 원본 앱(Filee)에서도 실패하던 경우이며 PDB 저장만 FileToX에서 뺐다.

| 변환 | 동작 | 이유 |
| --- | --- | --- |
| 그림·PDF·SVG·CAD·문서 → 오디오 형식 | 선택할 수 없음 | 원본에 소리가 없다. 오디오는 영상·오디오에서만 만든다. |
| PDB(PalmDoc)로 저장 | 선택할 수 없음 | Windows-1252 글자만 담아 한글·일본어·이모지가 깨진다. PDB 읽기는 된다. |
| 영상·오디오 → TXT 외 문서(DOCX·MD 등)로 받아쓰기 | 지원하지 않음 | 받아쓰기는 TXT로만 만든다. 영상 → 문서·그림은 정지 프레임 그림이다. |
| 영상·오디오 → TXT (macOS 15) | 선택할 수 없음 | 음성 받아쓰기는 macOS 26 이상의 기기 내 음성 인식을 쓴다. |
| 말소리가 없는 영상·오디오 → TXT | "No speech was recognised" 오류 | 음악·효과음·무음은 글자가 되지 않는다. 자막 트랙은 읽지 않는다. |
| 글자가 없는 그림·스캔 PDF → TXT | "The PDF contains no text" 오류 | 글자 층도 인식할 글자도 없다. 글자가 있는 그림·스캔은 OCR로 읽는다. |

받아쓰기와 OCR의 한계: 받아쓰기는 macOS 첫 번째 언어 하나로만 듣는다(한국어 Mac에서 영어 녹음은 틀리게 나온다). 화자 구분·시간 표시는 없다. OCR은 세로쓰기, 비스듬히 기울어진 페이지, 손글씨, 첫 언어와 다른 한중일 문자를 보장하지 않고 표를 표로 복원하지 않는다.

## 검증

```sh
swift test
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS,arch=arm64' ARCHS=arm64 -derivedDataPath build/DerivedData test
python3 -I Tools/engine-compare/test_harness.py
python3 -I Tools/test-engine-entitlements.py
```

실제 helper 통합 테스트는 먼저 helper를 빌드해야 한다. 없으면 해당 테스트만 skip한다. 별도 helper 경로는 `FILETOX_TEST_HOST`로 지정할 수 있다. 실제 엔진 표본은 아래 스크립트로 재현한다. 작업 폴더는 새 절대 경로를 사용한다.

```sh
FILETOX_SMOKE_HOST="$PWD/build/DerivedData/Build/Products/Debug/FileToX Dev.app/Contents/Helpers/FileToXEngine.app/Contents/MacOS/FileToXEngine"
python3 Tools/engine-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/smoke-new"
python3 Tools/engine-optional-smoke.py "$FILETOX_SMOKE_HOST" "$PWD/build/optional-smoke-new"
```

이전 앱 검증에서는 Apple silicon에서 Xcode 테스트 32개, Swift Package 테스트 12개, 내장 엔진 검증 22개(실제 변환 20개·선택 판단 2개), 추가 엔진·영상·음성·실행 중 취소·첨부 이미지 충돌 표본 11개를 통과했다. Swift 통신에서도 실제 PNG→JPG, PDF 병합→여러 PNG, unknown 파일·폴더 ZIP→압축 해제와 이력을 확인했다. 실제 앱의 도넛 JPG 클릭→결과 생성→최근 이력도 통과했다. 실제 Finder Option 드래그에서도 느린 움직임, 원본 보존과 드롭 후 Finder 포커스 유지를 확인했다. 한글 HWP·DOCX에서 만든 PDF의 텍스트 추출과 PNG 렌더링도 확인했다. 영어·한국어·일본어 변경은 실행 중인 앱과 helper에 바로 반영된다. 기본 색상 선택기로 고른 색의 재실행 후 유지, 기본 프리셋 이름 번역과 사용자 이름 보존도 확인했다.

**설정 → 자동 변환 폴더**에서 입력 폴더와 프리셋을 지정하고 규칙을 켠 뒤 저장한다. **감시 중** 상태가 된 뒤 파일을 넣는다. 시작할 때 이미 있던 파일은 그대로 두고, 앱이 실행 중일 때 새 파일과 변경된 파일을 처리한다. 기본 출력은 `converted`이며 원본은 유지한다. 선택하면 변환에 성공하고 변경되지 않은 원본을 `originals`로 이동한다. 패키지 내부와 임시 다운로드 폴더는 제외한다. 3초 안정화 대기는 휴리스틱이므로 쓰기 중 오래 멈출 수 있는 프로그램은 완료한 파일을 원자적 rename으로 전달해야 한다. 스캔은 10,000개 항목, 작업은 입력 128개로 제한한다.

모든 형식 조합·코덱을 검사하지 않았다. Ghostscript는 이 머신에 없다. 시스템 FFmpeg에는 일부 인코더가 없지만, 별도의 고정 소스 빌드로 기존 AMR·OGG·OGV 실패 21건과 미디어 테스트 35개, AV1 입력 변환을 통과했다. [미디어·스캔 PDF 검증 기록](docs/design/engine-differential-triage.md#media-codecs-and-original-scanned-pdf-fallback-2026-10-27). 실제 로그아웃·로그인 후 자동 실행과 알림 전달은 검증하지 않았다. 외장 exFAT·SMB, 배포 공증·TCC 재실행 검증도 남아 있다.

2026-10-27~28 후속 작업에서 혼합 PDF 내용, 위치 정보가 빠진 슬라이드 표·병합 셀 위치·그룹 확대율과 FB2 텍스트 상자를 보완했다. PML은 한글·일본어 등 BMP 문자를 이스케이프로 보존하고 PNG의 축소·팔레트 변환을 끄며 비 BMP 문자는 명시적으로 거부한다. SVG의 제한된 가로 글자는 기존 윤곽선을 유지하며 PDF 검색·선택과 TXT 추출을 지원한다. 복잡하거나 display·visibility·opacity 설정으로 숨기거나 잘린 글자 등은 윤곽선만 유지하고, 그림 문서 경로는 편집 가능한 SVG 글자 대신 페이지 그림을 담는다. AVIF는 ImageIO의 색·알파 표본 오차가 모두 0이면 추가 인코딩을 생략한다. 짧은 TS/M2TS의 빠른 탐색 결과가 비었을 때 처음부터 한 번 재시도하는 동작도 유지한다.

SVG 글자 뒤에 그린 것이 그 글자를 전부 또는 일부라도 덮을 수 있으면, 불투명하든 반투명하든 검색용 글자를 넣지 않는다. 영역을 측정하지 않는 그림(참조·CoreSVG가 배치하는 글자·중첩 viewport·filter·marker·CSS 변환)이 뒤에 올 때도 같다. 덮인 윤곽선은 PDF의 벡터 내용에 남으므로 도형으로 가리는 작업은 여전히 글자 삭제가 아니다. PML 그림 참조는 실제 파일이 있어야 하며, ASCII 영문·숫자·밑줄·하이픈·마침표 이름에 소문자 `.png` 확장자를 사용하고 이름이 마침표로 시작하지 않아야 한다.

영상 길이 수정 전인 2026-10-29 PDF·SVG 검토 시점의 전체 검사는 **엔진 793개(15 skip)·Core 18개, 실패 0개**다. 새 정상 Release 빌드로 host와 AVIF helper를 만들었다. 그 시점의 새 Debug 앱과 별도로 컴파일한 실제 AppModel 흐름으로 파일 선택·옵션 저장·번들 AMR 변환·취소·OGG 재시도·이력·원본 보존을 확인했다. 앱의 Mach-O는 모두 arm64이고 ad-hoc 서명 검증을 통과했으며 Homebrew 동적 링크가 없다. 실제 마우스·대화상자 조작과 Xcode 호스트 XCTest 실행은 다시 검증하지 않았다.

그 PDF·SVG 검토 시점 host의 849건은 **829건 완료·20건 실패**다. 남은 실패는 오디오 트랙 없음 14건·추출 가능한 글자 없음 6건이며, 모든 사례가 직전 최종 상태를 유지했다. 이전 회차 전부터 성공한 786건과 그 회차에 복구한 43건도 계속 완료한다. harness·검사 오류는 0이다. 같은 임계값·판독 정책으로 실행한 엄격 C# 비교는 **484 PASS / 260 WARN / 105 FAIL**다. C#에서 실패했으나 현재 성공하는 43건도 상태 불일치로 FAIL에 포함하며 면제하지 않았다. 위임 구현의 검증과 달리 PDB→RB는 내장 그림 유사도로 다시 FAIL이 됐고, LRF→HTMLZ는 WARN에서 PASS가 됐다. 두 경로는 이번 리뷰에서 바꾸지 않았으므로 수정 성과로 세지 않는다. 105개 FAIL의 사례 ID는 2026-10-28 최종 비교와 모두 같다. 비교 자료의 PDF·SVG 사례는 새 그림층이나 가림 규칙을 거치지 않는다. 변환 완료와 출력 동등성은 별개 결과다.

그 PDF·SVG 검토 시점 host 변환 44건이 출력 텍스트·순서·이미지 참조·디코딩 검사에 통과했다. 기존 혼합 PDF·기존 OCR·빈 페이지·SVG 26건에, 벡터 차트·인라인 이미지·폼 글자가 있는 텍스트 페이지의 DOCX·HWPX·EPUB·FB2·HTMLZ·TXTZ·ODT·TXT, 스텐실 마스크 페이지의 DOCX·EPUB, 가려진 SVG 글자의 PDF·TXT와 루트 선 상속·상대 이미지 좌표의 PDF·TXT 6건을 더했다. 보이는 글자가 있는 PDF 페이지가 벡터 그림·셰이딩·인라인 이미지·스텐실 마스크를 그리면, 글자를 뺀 페이지 렌더링 한 장으로 이를 담아 종이 위 원래 위치의 글자 뒤에 둔다. 다시 흐르는 형식에서는 그 페이지 글자의 앞에 놓인다. 글자는 텍스트로 한 번만 남고 TXT는 글자만 담으며, 흰 종이만 남기는 칠하기는 그림을 더하지 않는다. 이런 페이지의 다른 그림은 원래 바이트가 아닌 150dpi 렌더링의 일부가 되고, 당시 구현은 그림층에서 모든 글자 객체를 지웠다. 아래 PDF 보존 수정은 추출에서 빠진 글리프를 다루며, 세로쓰기 전체를 읽지 못한다는 앞선 설명은 부정확했다. 페이지 그림은 렌더링한 내용이며 원래 이미지 바이트·색 프로필·투명도 보존을 뜻하지 않는다. 전체 SVG/C# 동등성·새 OCR·모든 형식과 코덱 조합을 검증한 것은 아니다. 근거와 남은 차이는 [최종 후속 검증](docs/design/engine-differential-triage.md#remaining-work-final-verification-2026-10-28)과 [텍스트 페이지 그림·가려진 SVG 글자](docs/design/engine-differential-triage.md#priority-one-integration-review-2026-10-29)를 따른다. 그 시점의 PDF 텍스트 검사는 기존 출력 바이트를 유지하며 순차 5회 모두 0.84초 목표를 충족했다(0.673~0.772초, 중앙값 0.701초). 그 밖의 이전 개발 인증서·재배치·성능 측정 결과는 과거 기록으로 유지하며 물리 M1/macOS 15·외장 파일시스템·TCC·로그인/알림·공증은 미검증이다.

2026-10-29 영상 길이 수정은 저속 입력의 TS·M2TS·MPG·MXF 마지막 프레임 표시 시간을 채우고, 평균보다 짧은 간격의 색 변화에는 입력의 명목 프레임률도 반영한다. 원래 ICNS의 M2TS·MPG·MXF 세 출력은 파일 길이와 디코딩 표시 시간이 모두 0.1초다. 당시 영상 수정 소스의 집중 검사 **56개**, 실제 변환 **33건**이 통과했고, 849건은 **829건 완료·20건 실패**, harness·검사 오류 0이다. 같은 기준의 엄격 C# 비교는 **482 PASS / 241 WARN / 126 FAIL**이며 프레임률 항목 차이로 새 FAIL 22건이 추가됐다. 변경하지 않은 전자책 경로의 판정 변동 2건도 있으며 수정 성과로 세지 않았다. 변환 완료와 동등성은 구분한다. 프레임 단위로 맞출 수 없는 0.13초 입력은 약 0.1668초로 올림되며, 초소형 MPG의 파일 길이 추정값은 실제 표시 시간보다 짧을 수 있다. 전체 검사·앱/AppModel·PDF 성능은 앞선 PDF·SVG 검토 시점의 결과이며 이번 소스로 반복하지 않았다. [영상 길이 검증](docs/design/engine-differential-triage.md#slow-media-duration-verification-2026-10-29).

PalmDoc(`.pdb`)은 2026-11-06부터 읽기만 지원한다. Windows-1252 글자만 담을 수 있어 한글·일본어·이모지를 저장할 수 없었고, 이전 출력은 글자를 `?`로 바꾸는 대신 저장을 거부했다. PDB를 대상으로 저장해 둔 프리셋은 목록에 남고 사용할 수 없음으로 표시된다. DWG 출력은 R2010 이후 버전에 맞는 내부 여유 공간 구조를 쓰고 페이지 수에 페이지 맵 자체도 포함한다. [기존 품질 차이·내용 손실 검토](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

2026-10-29 DWG·PDB 수정 소스는 **엔진 800개(15 skip)·Core 18개, 실패 0개**다. 849건 재변환은 **822건 완료·27건 실패**이며 기존 20건에 문자 손실을 막은 PDB 7건이 더해졌다. 다른 경로의 완료 상태는 그대로이고 harness·검사 오류는 0이다. 같은 기준의 엄격 C# 비교는 **474 PASS / 241 WARN / 134 FAIL**이다. 새 FAIL 8건은 위 PDB 거부 7건과 변경하지 않은 PDB→SNB 생성 그림의 판정 변동 1건이다. DWG 독립 판독과 새 Debug 앱의 서명·arm64 구성·AppModel 변환·취소·재시도·이력도 통과했다. 실제 GUI·Xcode 호스트 XCTest 실행, 물리 M1/macOS 15와 배포 검증은 남아 있다. [현재 검증과 한계](docs/design/engine-differential-triage.md#legacy-quality-loss-verification-2026-10-29).

2026-11-02 PDF 보존 수정은 추출하지 못한 글리프를 페이지 그림으로 남기고, 합자·문자 묶음 뒤에서 버려지던 글자를 복구하며 큰 좌표로 인한 엔진 종료를 막는다. 중첩 폼·일부만 추출한 글자 객체도 검사했다. 최종 소스는 **엔진 812개(15 skip)·Core 18개, 실패 0개**, **리치 변환 94건·경계 변환 8건 통과**다. 849건의 사례별 상태는 모두 **822건 완료·27건 실패**를 유지했고, 엄격 비교도 **474 PASS / 241 WARN / 134 FAIL**, 사례별 판정 변화 0개다. 새 Debug 앱의 서명·arm64 구성과 AppModel 흐름도 통과했다. 그림은 150dpi이며 기울임·겹침의 글리프 판별, 원본 그림 해상도와 합자 뒤 배치에는 한계가 남는다. [2026-11-02 PDF 검증과 한계](docs/design/engine-differential-triage.md#pdf-text-preservation-integration-2026-11-02).

2026-11-06 PDF 후속 수정은 추출한 단어와 글리프의 글자를 대조해 기울임·겹침에서 빠지던 글자를 보존하며, 한글 음절·말줄임표의 호환 분해도 모두 계산한다. 추출 못한 글자 때문에 그림층을 만드는 페이지에서는, 회전하지 않은 별도 사진이 합성이 필요하지 않을 때 원본 바이트와 해상도를 유지한다. 마스크·그래픽 상태·클리핑·폼·이미지 변형·겹침·페이지 밖 그림이나 회전 페이지는 합성 그림에 남기는 보수적인 경로를 따른다. 보존 글자는 150dpi 픽셀이며 겹친 획의 작은 조각·합자 배치·기존 180도 페이지의 글자와 그림 좌표 차이는 남는다. 그림층을 추가하지 않는 일반 그림 추출 경로의 기존 마스크·잘림 한계는 별도다.

최종 소스의 **엔진 821개(15 skip)·Core 18개 검사는 실패 0개**이며, **리치/TXT 변환 142건·경계 사례 25건·검토 재현 변환 36건**이 통과했다. 849건은 사례별 상태 변화 없이 **822건 완료·27건 실패**, 엄격 비교는 같은 FAIL 집합의 **474 PASS / 241 WARN / 134 FAIL**다. 새 Debug 앱의 서명·arm64 구성과 AppModel 흐름도 통과했으며, DOCX·EPUB에서 원본 400×400 사진과 누락 글자 그림을 확인했다. [최신 PDF 검증과 한계](docs/design/engine-differential-triage.md#pdf-geometry-integration-2026-11-06).

2026-11-06 엄격 FAIL 134건을 재분류한 결과 C#보다 나빠진 사례는 찾지 못했다. C# 실패를 Swift가 완료한 43건, 영상 마지막 프레임 표시 시간 수정 30건, PDB 한글 거부 7건, 슬라이드 글자 보존 6건, 기존 48건이다. 그림·PDF·SVG·CAD에 표시되던 오디오 출력 18종과 영상의 TXT 출력은 결과가 나올 수 없어 경로 계획에서 제외했고, 목록·원형 메뉴에서 비활성화된다. PDF→TXT는 글자가 없는 스캔·그림 페이지를 macOS Vision으로 읽어 그림·만화의 TXT도 다시 허용했다. 300dpi로 만든 한영 혼합 6쪽 스캔에서 단어 재현율 96.5%, 글자 유사도 97.6%, 쪽당 약 0.33초였다. 전체 검사는 **엔진 827개·Core 18개, 실패 0개**, 849건은 **822건 완료·27건 실패**(경로 없음 15·PDB 7·글자 없는 그림/스캔 TXT 5)이며 다른 834건의 상태는 그대로다. 엄격 비교는 시작 전 거부로 오류 키가 바뀐 15건 때문에 **460 PASS / 240 WARN / 149 FAIL**이다. 한글 PDB는 지원하지 않는다. [재분류·대상 제외·OCR](docs/design/engine-differential-triage.md#unreachable-targets-2026-11-06).

모든 Calibre 변환은 심볼릭 링크를 해석한 `ebook-convert` 옆에 `calibre-debug`가 있는 완전한 설치본이 필요하다. 자식 프로세스의 내부 API 보완은 고정 Calibre 9.15.0에서 목차 서식·TCR·PML 보존을 검증했으며 다른 버전은 재검증이 필요하다. 별도 Python 설치는 필요 없다.

## 소스와 설계

개발 참고 기준은 [KnifeLemon/Filee](https://github.com/KnifeLemon/Filee) 커밋 `21fdd05ef7181b032ed83ec895cc9bbc4b198985`다. 현재 Core·host·엔진 구현은 `Sources/Engine`, 앱에서 사용하는 Core 패키지는 `Sources/Core`에 있다. 원본 라이선스와 고지는 `docs/upstream`에 보존하며 현재 빌드는 Filee C# 프로젝트를 참조하지 않는다.

- [전체 형식 목록](docs/formats.md), [전체 설계](docs/architecture.md)
- [통신 계약](docs/design/host-wire-v1.md), [host 구현](Sources/Engine/Host/Host.swift)
- [UI 설계](docs/design/swiftui-port.md), [패키징·서명](docs/design/macos-packaging.md)
- [Claude 설계 검토](docs/design/review.md), [엔진 구현·검증 현황](docs/design/engine-differential-triage.md)

이전 대화의 시안은 `docs/archive/pre-filetox/`에 보존한다. 노치 선반·파일 보관·이동·복사는 현재 범위에 포함하지 않는다.

</details>

## 감사의 말

FileToX는 [Filee](https://github.com/KnifeLemon/Filee)에서 영감을 받아 만든 Mac 전용 파일 변환 앱이다. SwiftUI와 AppKit으로 macOS에 맞게 만들었으며, Filee의 공식 배포판이 아닌 독립 프로젝트다.

FileToX는 [MIT 라이선스](LICENSE)로 배포한다. Filee의 [MIT 라이선스](docs/upstream/Filee.LICENSE)와 [외부 구성요소 고지](docs/upstream/Filee.THIRD-PARTY-NOTICES.md)를 보존한다. MIT는 각 외부 엔진의 라이선스를 대신하지 않는다. 카메라 RAW는 [LibRaw](https://www.libraw.org) 0.22.2로 읽으며, LibRaw는 [CDDL-1.0](docs/upstream/LibRaw.LICENSE)([고지](docs/upstream/LibRaw.THIRD-PARTY-NOTICES.md))으로 사용한다. 수정하지 않은 소스는 `Vendor/LibRaw`에 있다. JPEG 쓰기와 손실 압축 DNG 읽기에는 [libjpeg-turbo](https://libjpeg-turbo.org) 3.2.0을 IJG 라이선스([라이선스](docs/upstream/libjpeg-turbo.LICENSE), [고지](docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md))로 사용한다. 이 소프트웨어는 일부 Independent JPEG Group의 작업에 기반한다. 수정하지 않은 소스는 `Vendor/libjpeg-turbo`에 있다. 실제 번들 고지는 helper의 `Contents/Resources/Notices`에 포함한다. PDF 래스터 출력은 기존 C#와 같은 [번들 PDFium](Vendor/PDFium/README.md) 147.0.7690.0(arm64 배포 사본)을 쓴다. [BSD-3 라이선스](docs/upstream/PDFium.LICENSE)와 [번들 구성요소 고지](docs/upstream/PDFium.THIRD-PARTY-NOTICES.md)를 helper에 포함한다.
