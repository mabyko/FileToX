# FileToX 설계

FileToX는 Filee에서 영감을 받아 만든 Mac 전용 파일 변환 앱이다. UI는 SwiftUI·AppKit으로 구성하고, 변환 작업은 C# 보조 실행 파일에서 처리한다. 지원 범위를 JPEG·PNG로 제한하지 않는다. 최소 OS는 macOS 15이며 Swift 앱과 host의 타깃도 동일하다. .NET 10의 공식 지원 범위를 따른다.

검토 기준은 Filee 커밋 `21fdd05ef7181b032ed83ec895cc9bbc4b198985`다. 이 설계를 바탕으로 전체 변환 host와 SwiftUI 앱을 연결했다. 구현 범위와 검증 결과는 마지막 절에 구분했다.

## 설계와 구현 구성

- [전체 형식 목록](formats.md): 실제 171개 형식·257개 확장자, 읽기 전용과 가상 폴더를 보존한 생성 문서.
- [변환 host](design/engine-host.md): 요청·진행·취소·작업 결과, 전체 프리셋·프로필·설정과 파일 안전.
- [SwiftUI 화면 설계](design/swiftui-port.md): 홈·도넛의 드롭·클릭 흐름, 입력별 활성 상태와 편집·접근성.
- [macOS 배포](design/macos-packaging.md): OS·아키텍처·런타임·네이티브 라이브러리·엔진·서명과 검증 조건.
- [Claude 검토 결과](design/review.md): 원본 대조 결과와 구현 후 확인할 항목.

`Vendor/Filee`의 버전은 위 커밋으로 고정한다. Core·Engines, 테스트, 지역화와 배포 참고 파일의 목록을 manifest로 관리한다. NuGet 의존성과 기본 rhwp·7-Zip을 helper에 포함했다. Pandoc·LibreOffice·Calibre의 고정 버전은 개발용 사본으로 받아 실제 실행을 확인했다.

`Vendor/filee-manifest.json`에 원본 경로와 236개 파일의 SHA-256을 보존했다. `Tools/verify-filee-vendor.py`가 파일 목록·해시를 확인한다. 라이선스는 원본과 함께 보존한다. 필요한 코어 수정은 이유·테스트와 함께 별도 패치로 기록하고, 검증한 원본의 빌드 작업 사본에 적용한다.

`Resources/FileeFormats.json`은 고정 소스에서 생성한 정적 카탈로그이며 `Sources/Core/FormatCatalog.swift`로 읽는다. 원본 `FormatRegistry`가 실행 시점의 기준이다. 이 JSON을 엔진 사용 가능 여부나 변환 경로 판단에 쓰지 않는다.

## 참고 소스와 담당 기능

| 참고 소스 | FileToX에서 처리할 방식 |
| --- | --- |
| `Filee.App/Views/MainWindow.axaml`, `Views/Pages/` | 사이드바와 페이지를 SwiftUI로 구성 |
| `Controls/DonutMenu.cs`, `DonutGeometry.cs`, `ViewModels/RadialViewModel.cs` | 원형 메뉴, 입력별 형식 필터, 드롭·클릭 선택, 진행·완료 표시를 SwiftUI·AppKit으로 구현 |
| `Filee.Core/Formats/FormatRegistry.cs` | 전체 형식·확장자·분류·쓰기 가능 여부 처리 |
| `Filee.Core/Conversion/ConverterCatalog.cs`, `RoutePlanner.cs`, `JobQueue.cs` | 엔진 상태, 다단계 변환 경로, 진행·오류·취소 처리 |
| `Filee.Core/Presets/`, `Profiles/`, `Settings/`, `History/`, `Watching/` | 프리셋·프로필·저장 규칙·이력·폴더 감시 처리 |
| `Filee.Engines/EngineRegistry.cs`와 개별 변환기 | C# 변환 처리 및 외부 실행 파일 연동 |
| `Filee.App/Services/Triggers/` | macOS 호출 동작을 AppKit으로 구현 |

화면과 상호작용은 SwiftUI·AppKit으로 구현한다. 변환 모듈은 별도의 host에서 실행하며, SwiftUI 타깃에는 Avalonia 의존성을 넣지 않는다.

## UI 범위

- **홈:** 큰 파일 드롭 영역과 작업 단위 최근 변환. 파일을 넣으면 해당 입력에 맞는 도넛을 열고 클릭으로 프리셋을 선택한다.
- **도넛:** Option 드래그로 커서 위치에 열고 프리셋별 부채꼴에 드롭한다. 중앙에는 파일 수·입력 형식 또는 선택 안내를 표시한다. 변환 후 진행 링·취소·성공·실패 상태로 바뀐다. 중심·Escape는 닫기, 프리셋 우클릭은 편집이다.
- **원형 툴바:** 프로필 목록, 도넛 배치·순서, 프리셋 팔레트와 입력별 표시 규칙을 편집한다.
- **프리셋:** 목록과 편집 화면. 형식·품질·크기 등 실제 엔진 옵션과 출력 위치·파일명·충돌 처리·날짜 유지 등을 연결한다. 도넛의 편집 팝업에도 같은 편집 화면을 쓴다.
- **자동 변환 폴더:** 원본 감시 규칙과 실행 상태를 보여준다.
- **설정:** 일반, 호출 키, 테마, 변환 엔진, 정보 페이지. 권한·로그인 항목·Finder 연동은 macOS에 맞게 구현한다.

Filee에서 영감을 받아 홈·원형 툴바·프리셋 편집 화면을 macOS에 맞게 구성한다. 창 장식과 기본 글꼴은 macOS를 따른다. 모든 메뉴를 빈 페이지로 먼저 추가하지 않고 실제 코어 기능과 함께 연결한다. 제품 이름과 업데이트·배포 경로는 FileToX에 맞춘다.

## 형식과 엔진

`FormatRegistry`의 전체 형식을 카탈로그에 담는다. 현재 가상 `folder`를 제외한 171개 형식이 14개 분류로 등록돼 있다. 읽기 전용 형식과 확장자 별칭도 보존한다. 이미지, 벡터, PDF, 문서, HWP, 표, 프레젠테이션, 텍스트, 전자책, 영상, 음성, 압축, 글꼴, CAD가 대상이다.

등록된 형식 수는 모든 형식 사이의 변환이 가능하다는 뜻이 아니다. `ConverterCatalog.StatusOf`와 `CreatePlanner`가 실제 사용 가능한 변환을 판단하고 `RoutePlanner`가 최대 3단계 경로를 탐색한다. `ProfileSelector`가 입력에 맞는 프로필을 고른다. UI가 이 규칙을 별도로 하드코딩하지 않는다.

내장 변환기와 NuGet 의존성은 helper에 포함한다. rhwp·7-Zip은 해당 실행 파일도 필요하다. 영상·음성은 FFmpeg, 일부 형식은 LibreOffice·Pandoc·Ghostscript·Calibre 등이 필요하다. 엔진이 없는 경우 설치 필요 상태와 이유를 표시한다. macOS에서는 EMF·WMF 등 Windows 전용 경로도 구분한다. 세부 지원은 원본 `docs/ENGINES.md`와 실제 macOS 검사 결과를 기준으로 한다.

## 실행 구조

```mermaid
flowchart LR
    A[SwiftUI 화면·도넛·프리셋] --> B[AppKit 드래그·창 / 앱 상태]
    B -->|구조화된 요청·진행·결과| C[FileToX 변환 보조 실행 파일]
    C --> D[Filee.Core]
    D --> E[Filee.Engines]
    E --> F[내장 라이브러리·추가 엔진]
```

Swift 앱은 UI와 macOS 연동을 소유한다. 보조 실행 파일은 변환 코어의 형식·프리셋·작업 큐·엔진을 사용한다. 변환 경로와 출력 규칙을 Swift와 C# 양쪽에 중복 구현하지 않는다.

`Filee.Cli`의 `convert --json`은 완료 결과를 제공하지만, `formats`·`presets`는 텍스트 출력이다. 실시간 진행·전체 프리셋 편집·독립 데이터 경로를 위한 공개 프로토콜도 없다. 따라서 CLI의 코어 사용 방식을 참고해 Core·Engines를 직접 참조하는 작은 FileToX 전용 host를 만든다. 전체 UI 연동에는 CLI 명령 외에 실시간 이벤트와 편집용 프로토콜이 필요하다.

첫 연결에는 카탈로그 조회, 선택 판단, 작업 시작·취소 요청과 진행·완료 이벤트가 필요하다. 정확한 메시지와 순서는 [host 설계](design/engine-host.md)를 따른다. 형식·엔진·프리셋·프로필·이력을 전달하고, 결과는 여러 출력 파일을 보존한다. 파일 경로는 셸 문자열로 합치지 않는다. `JobQueue.JobUpdated`를 진행 이벤트로 전달하고 취소 메시지는 `ConversionJob.Cancel`에 연결한다. 큐의 오류 처리와 입력 파일 보호를 유지한다.

홈 이력을 위해 작업 완료 시 `HistoryEntry.From(job)`을 취소·병합 실패에 맞게 보정한 뒤 `UserDataStore.AddHistory`에 연결한다. 기존 CLI는 이력을 저장하지 않으므로 홈의 작업 이력 표시를 위해 이 연결이 필요하다.

저장 경로는 `~/Library/Application Support/FileToX/` 아래 `core`·`engines`·`tmp`로 분리한다. `UserDataStore`의 디렉터리와 `EngineEnvironment.DownloadRoot`를 모두 FileToX 경로로 지정한다. 기존 Filee의 설정·이력·엔진 상태를 변경하지 않는다. 초기 출력은 원본 옆에 저장하고 이름 충돌은 별도 이름으로 처리한다.

## 병렬 작업과 순서

공통 메시지·데이터 구조를 먼저 고정한 뒤 세 갈래로 진행한다.

1. **변환:** 변환 host, 형식·사용 가능 경로·프리셋 노출, 작업·진행·취소 연결과 실제 변환 검증.
2. **UI:** 홈·도넛부터 SwiftUI로 구성하고 프리셋·프로필·설정·폴더 감시를 실제 host 기능과 연결.
3. **macOS·통합:** 비활성 팝업과 드롭 연동, host 실행·상태 경로, 런타임·네이티브 라이브러리 패키징, 서명·라이선스·전체 검증.

첫 통합은 도넛 UI와 변환 코어를 연결한다. 이후 프리셋·프로필·설정 페이지를 구현한다. 이 순서는 구현 순서이며 지원 형식을 이미지 두 가지로 줄이는 결정이 아니다.

## 완료 기준과 배포 확인

- 원본 형식 목록과 실제 사용 가능한 변환 조합을 코어에서 읽어 UI에 반영한다.
- 이미지 외에도 PDF·문서·표·압축·전자책 등 연결된 엔진의 대표 파일을 실제 변환해 확인한다.
- 도넛 드롭·홈 클릭 선택·프리셋 편집·진행·실패·취소·최근 변환을 처음부터 끝까지 확인한다.
- 원본 보호·이름 충돌 처리·사용자가 고른 Overwrite의 경로별 확정과 부분 실패 보고, 한글·공백 경로, 손상 입력, 다중 결과, 실패 후 임시 파일 정리와 취소를 검증한다.
- .NET SDK가 없는 Mac에서도 host가 실행되도록 런타임을 포함하고, arm64와 x86_64의 네이티브 의존성을 각각 검증한다.
- 기존 Filee 데이터가 변경되지 않는지 검사한다.

.NET 10의 현재 공식 macOS 지원 최저 버전은 15다. 원본 README의 macOS 14 안내와 구분한다. [Microsoft 지원표](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.json)를 기준으로 한다.

arm64 개발 번들에서 .NET 런타임·내장 엔진과 rhwp·7-Zip의 실행, ad-hoc hardened runtime 서명을 확인했다. 현재 앱은 약 197 MB, helper는 약 193 MB다. Developer ID 서명·공증은 별도 배포 검증 대상이다. Filee의 MIT 고지와 실제 포함한 각 의존성·외부 엔진의 고지를 함께 관리한다.

Swift 앱은 XcodeGen으로 생성하는 Xcode 프로젝트를 유지한다. 조직 서명 팀은 넣지 않고 `forked.filetox.local` 및 Debug의 `.dev` 식별자를 쓴다. 개인 설정은 Git에서 제외한 `Config/Local.xcconfig`에 둔다.

## 현재 구현 상태

2026-10-11 Apple silicon에서 엔진 23개·전체 카탈로그를 .NET host로 연결했고 SwiftUI 홈·도넛·프리셋·프로필·설정·엔진 페이지를 구현했다. 실제 앱에서 도넛 JPG 클릭, 결과 생성과 최근 이력 표시를 확인했다. 기존 JPEG·PNG 전용 ImageIO 경로는 실제 helper 통합 테스트를 통과한 뒤 삭제했다.

기본 엔진 22개 검증(변환 20개·선택 판단 2개)과 추가 엔진·영상·음성·취소·첨부 이미지 충돌 11개 표본이 통과했다. 원본 Core/Engines 테스트와 패치 테스트를 비교해 FFmpeg 인코더 부족의 기존 실패를 구분했다. 원본 236개 파일의 SHA-256은 유지한다. 실제 실행 명령과 제한은 [README](../README.md), 세부 결과는 [host 구현 현황](../EngineHost/IMPLEMENTATION.md)에 적었다.

자동 변환 폴더·앱 내 엔진 다운로드·로그인 항목은 후속 UI/host 연결 대상이다. 모든 형식 조합이나 Intel·외장 볼륨·공증 완료를 의미하지 않는다.
