# macOS 앱·변환 엔진 배포 설계

작성·공식 문서 확인일: 2026-10-11. SDK 10.0.401을 `~/.dotnet`에 설치했고 arm64 self-contained helper의 로컬 게시·ad-hoc hardened runtime 서명을 실행했다. Developer ID 서명·공증과 Intel 검증은 아직 수행하지 않았다.

## 배포 단위와 최소 OS

SwiftUI 앱 안에 변환 작업을 처리하는 self-contained .NET helper를 포함한다. 사용자에게 .NET 설치를 요구하지 않는다. 변환·형식·프리셋·프로필은 helper가 담당하고, Avalonia 앱·SharpHook·Windows 통합 코드는 포함하지 않는다.

**앱의 최소 지원 OS는 macOS 15로 정한다.** Xcode·Swift Package 타깃도 15로 맞췄다. 원본 README는 14 이상을 안내하지만, Microsoft의 .NET 10 지원표는 2026-09-28 갱신본에서 다음과 같이 분류한다.

| 항목 | 공식 지원표 값 |
| --- | --- |
| macOS 아키텍처 | `Arm64`, `x64` |
| 지원 OS | `27`, `26`, `15` |
| 미지원 OS | `14` |

이는 macOS 14에서 반드시 실행이 실패한다는 뜻이 아니다. 실행 가능성과 제조사의 지원 범위는 다르다. macOS 14 호환성을 별도로 시험할 수 있으나 제품 지원으로 약속하지 않는다. 근거: [Microsoft .NET 10 supported-os.json](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.json), [원본 README](../../.reference/Filee/README.md).

Apple silicon용 `osx-arm64`, Intel용 `osx-x64` 앱을 따로 배포한다. helper·.NET 런타임·native 라이브러리·외부 엔진이 모두 해당 RID에 맞아야 한다. 첫 배포에서는 두 게시 폴더를 합치거나 apphost만 `lipo`로 합치지 않는다. 동일 버전의 앱을 아키텍처별로 내보낸다. 참고: [Filee portable CI](../../.reference/Filee/.github/workflows/portable.yml).

## 원본을 고정하는 방법

참조 기준은 Filee `21fdd05ef7181b032ed83ec895cc9bbc4b198985`다. 버전 표시는 1.8.1이며, `global.json`은 SDK 10.0.100에 `latestFeature` roll-forward를 지정하고 공통 타깃은 `net10.0`이다. 근거: [global.json](../../.reference/Filee/global.json), [Directory.Build.props](../../.reference/Filee/Directory.Build.props).

구현할 때 다음 방식으로 빌드 입력을 고정한다.

- 해당 커밋의 소스와 고지를 `Vendor/Filee`에 보관한다. `.reference/Filee`는 조사용이며 release 빌드 입력으로 사용하지 않는다. 전체 소스 중 helper가 참조하는 프로젝트는 Core·Engines뿐이다.
- upstream URL·커밋·파일 SHA-256·적용한 패치를 manifest에 기록한다. 변경은 helper 프로젝트나 별도 패치에 두고 upstream 파일과 섞지 않는다.
- [Directory.Packages.props](../../.reference/Filee/Directory.Packages.props)의 직접 NuGet 버전뿐 아니라 transitive 의존성도 lock 파일에 고정한다. CI는 잠긴 복원 결과를 사용한다.
- release CI의 SDK 정확한 버전, Xcode 버전, RID, runtime 버전, NuGet lock 해시를 산출물 manifest에 남긴다. upstream의 `latestFeature`만으로 재현성을 주장하지 않는다.
- 외부 엔진은 [engines.json](../../.reference/Filee/src/Filee.Engines/Infrastructure/engines.json)의 RID별 URL·버전·SHA-256을 함께 고정한다. URL의 이름이 같더라도 해시가 달라지면 실패한다.

서명·타임스탬프 때문에 최종 앱의 바이트 해시가 매번 같다는 목표와, 같은 소스·패키지·런타임으로 다시 빌드할 수 있다는 목표를 구분한다. 여기서 목표는 후자다.

## 앱 번들과 파일 위치

패키징은 .NET 게시 폴더 전체를 포함하는 별도 helper 앱으로 구성한다.

```text
FileToX.app/Contents/
  MacOS/FileToX                         # SwiftUI 실행 파일
  Helpers/FileToXEngine.app/Contents/
    Info.plist                         # UI 없이 실행하는 helper 정보
    MacOS/
      FileToXEngine                    # .NET apphost
      FileToXEngine.dll
      FileToXEngine.deps.json
      FileToXEngine.runtimeconfig.json
      <.NET runtime / NuGet DLL / native dylib 전체 게시 결과>
      engines/rhwp/...                 # RID별 실행 파일·고지
      engines/7zip/...
    Resources/Notices/...
  Resources/
    FileeFormats.json
    Notices/...
    upstream-manifest.json
```

helper의 최종 assembly 이름은 [engine-host 설계](engine-host.md)와 맞춘다. 위 이름은 패키징 경계와 위치를 정하기 위한 것이다. `AppContext.BaseDirectory/engines/<id>`를 사용하는 [EngineEnvironment](../../.reference/Filee/src/Filee.Engines/Infrastructure/EngineEnvironment.cs)의 탐색 경로에 맞춰 엔진을 배치한다. 참고: [build-portable.ps1](../../.reference/Filee/build/build-portable.ps1)은 게시 폴더 전체를 별도 앱의 `Contents/MacOS`에 보존한다.

**managed DLL·JSON이 code 디렉터리에 함께 있는 구조에는 배포 검증 조건이 있다.** 참고 스크립트는 managed 파일까지 개별 서명하며, 비-Mach-O 서명은 extended attribute에 저장된다. Apple은 코드·리소스 위치를 분리하고 비-Mach-O 파일의 extended attribute 서명에 의존하지 않는 구성을 권장한다. 따라서 위 구조는 apphost의 로딩 경로에 맞춘 시작점이며 공증 완료를 가정한 완성안이 아니다. 실제 SDK의 apphost 로딩 경로를 검증한 뒤 managed 데이터의 Resources 분리가 필요하면 수행한다. 검증 전에 DLL만 임의로 옮기거나 symlink로 해결하지 않는다. 근거: [Apple TN2206의 Nested Code](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

번들·카탈로그·고지는 읽기 전용이다. 서명 후 엔진 설치나 설정 기록으로 앱 내부를 바꾸지 않는다. 쓰기 위치는 다음으로 분리한다.

| 내용 | 위치·설정 |
| --- | --- |
| 설정·프리셋·프로필·이력·LibreOffice 프로필 | `~/Library/Application Support/FileToX/core`를 `UserDataStore`와 `EngineEnvironment`에 전달 |
| 선택 설치한 엔진 | `~/Library/Application Support/FileToX/engines`; `EngineEnvironment.DownloadRoot`도 명시적으로 설정 |
| 로그 | `~/Library/Application Support/FileToX/core/logs` |
| 임시 변환 | host 시작 전에 `TMPDIR=~/Library/Application Support/FileToX/tmp` 지정; 하위 작업 경로 `Filee/<jobId>`를 사용하고 종료 시 정리 |
| 최종 출력 | 프리셋의 저장 규칙; 앱 번들이 아님 |

`UserDataStore`의 경로만 바꾸면 다운로드 경로는 여전히 Filee 기본값이므로 두 경로를 모두 지정해야 한다. 근거: [UserDataStore](../../.reference/Filee/src/Filee.Core/Settings/UserDataStore.cs), [EngineEnvironment](../../.reference/Filee/src/Filee.Engines/Infrastructure/EngineEnvironment.cs).

## .NET·native 자산과 외부 엔진

self-contained 게시에는 apphost뿐 아니라 런타임·deps/runtimeconfig·모든 의존 파일이 필요하다. RID별 `--self-contained true`, `PublishReadyToRun=false`를 사용한다. 첫 구현에서 trimming·Native AOT·single-file을 추가하지 않는다. 앱 UI를 제외하는 최적화와 변환 엔진 의존성을 지우는 최적화를 혼동하지 않는다. 현재 Microsoft 문서의 self-contained 게시 방법도 확인했다. 근거: [Microsoft .NET 배포 문서](https://github.com/dotnet/docs/blob/main/docs/core/deploying/index.md).

Xcode build phase는 `TARGETNAME=FileToX`를 export한다. MSBuild가 이를 `TargetName`으로 읽으면 Core·Engines의 파일명이 모두 `FileToX.dll`이 되어 host 참조가 깨진다. `Tools/build-engine-host.sh`는 .NET 실행 전에 이 변수만 제거한다. host assembly 이름은 csproj에만 두며 전역 `-p:AssemblyName`도 사용하지 않는다. `bin/obj`를 비운 뒤 `TARGETNAME=FileToX` 환경에서 전체 restore·publish가 성공하는 것으로 확인했다. 환경 변수의 property 수입과 대소문자 무시는 [Microsoft MSBuild 문서](https://learn.microsoft.com/en-us/visualstudio/msbuild/how-to-use-environment-variables-in-a-build?view=vs-2022) 및 설치한 SDK의 targets로 확인했다.

[Filee.Engines.csproj](../../.reference/Filee/src/Filee.Engines/Filee.Engines.csproj)의 Magick.NET, PDFtoImage/PDFium, SkiaSharp·Svg.Skia 등에는 native 자산이 따라온다. arm64에서 PDFium·HarfBuzz·Magick·Skia·Unhwp native 자산 약 57MB를 확인했으며, 이들 참조는 Apple 시스템 라이브러리만 사용하고 최소 OS는 14 이하이다. 전체 게시 폴더를 보존하며 Intel 결과는 별도로 검사한다. managed-only 빌드 성공은 PDF·이미지 엔진 실행 성공의 증거가 아니다.

| 엔진 범위 | macOS 패키징 |
| --- | --- |
| Core·내장 NuGet 엔진 | helper와 함께 게시; 실제 형식별 실행 검증 필요 |
| `rhwp` 0.8.6 | arm64/x64 각각 pinned archive를 검증하고 기본 번들에 포함 |
| `7zip` 26.03 | pinned mac archive에서 `7zz`와 고지를 보존하고 기본 번들에 포함 |
| Pandoc·LibreOffice·calibre | macOS RID별 다운로드 정의 있음; 사용자 선택 설치 또는 기존 경로 사용 |
| FFmpeg·Ghostscript | 현재 macOS 다운로드 정의 없음; 시스템 탐지·사용자 지정 경로 사용 |

기본 번들은 `rhwp`·`7zip`을 포함한다. 참고: [fetch-portable-engines.ps1](../../.reference/Filee/build/fetch-portable-engines.ps1). 선택 다운로드는 [EngineDownloads](../../.reference/Filee/src/Filee.Engines/Infrastructure/EngineDownloads.cs)의 `CanDownload`로 판단한다. Windows용 H2Orestart·JRE·VC++ runtime을 macOS 패키지에 끌고 오지 않는다.

엔진 탐색은 사용자 지정→번들/다운로드→시스템 순서를 유지한다. macOS 앱은 터미널과 PATH가 다를 수 있으므로 `/opt/homebrew/bin`, `/usr/local/bin`, `/Applications/...app`에서도 엔진을 찾는다. 설치 작업의 SHA-256 검증·staging 교체·DMG 정리·취소는 [EngineInstaller](../../.reference/Filee/src/Filee.Engines/Infrastructure/EngineInstaller.cs)가 처리한다. 다운로드 성공과 Gatekeeper 실행 허용은 별도 검증하며 quarantine을 자동 제거하지 않는다.

## 서명과 entitlement 경계

첫 배포는 Developer ID로 직접 배포하는 앱으로 설계한다. App Sandbox·Mac App Store 배포를 이 설계에 섞지 않는다. 개인/조직 team ID, 인증서 이름, 공증 자격증명은 저장소에 넣지 않고 release 환경에서 전달한다.

SwiftUI 앱과 .NET helper는 실행 파일마다 별도로 서명한다. **부모 SwiftUI 앱에 `allow-jit`를 넣었다고 helper가 JIT 권한을 얻는 것으로 취급하지 않는다.** non-AOT .NET apphost 자체에 `com.apple.security.cs.allow-jit=true`를 부여한다. Microsoft가 이 요구사항을 명시한다. 근거: [Publish .NET apps for macOS](https://github.com/dotnet/docs/blob/main/docs/core/deploying/macos.md), [Apple allow-jit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit).

`com.apple.security.inherit`는 App Sandbox 상속용이다. JIT/hardened runtime 설정을 자식 실행 파일에 복사하는 대체 수단이 아니다. 현재 direct-distribution 설계에는 넣지 않는다. 향후 sandbox를 채택하면 파일 접근·동적 권한 전달·선택 설치 엔진을 별도 설계해야 한다. 근거: [Apple App Sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

서명 순서는 내부 Mach-O·native 라이브러리 → 외부 엔진 실행 파일 → .NET apphost/helper 앱 → SwiftUI 앱 순서다. 같은 release 서명 주체를 사용하고 `--options runtime`·타임스탬프를 적용한다. `--deep`로 일괄 서명하지 않으며 entitlement를 모두에게 뿌리지 않는다. `codesign --verify --deep --strict`는 마지막 검증에 사용한다. 원본 entitlement의 Apple Events 권한은 Filee의 다른 앱 통합에 해당하므로 helper에 자동 복사하지 않는다.

현재 `Tools/build-engine-host.sh`의 Debug·Release는 모두 로컬 ad-hoc 산출물이다. Team ID가 없는 ad-hoc dylib는 hardened runtime library validation 때문에 `libhostfxr` 로딩에 실패하므로, 이 경로만 `Config/EngineHost.AdHoc.entitlements`의 `allow-jit`와 `disable-library-validation`을 사용한다. apphost와 마지막 helper 앱 서명 모두에 명시한다. 배포용 Developer ID 경로는 내부 dylib까지 같은 Team ID로 서명하고 `Config/EngineHost.entitlements`의 `allow-jit`만 사용해야 한다. 개발 서명 파일을 배포 설정으로 복사하지 않는다. Apple의 기본 검증은 Apple 서명 또는 실행 파일과 동일 Team ID를 요구한다. 근거: [Apple Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation), 확인일 2026-10-11.

비-Mach-O 파일 서명을 보존해야 하는 후보 구조에서는 복사·압축·해제 과정의 extended attribute 보존이 release 조건이다. 실제 배포 아카이브를 새 디렉터리에 풀어 검증한다. ad-hoc 개발 서명 통과와 Developer ID hardened runtime·공증 통과를 서로 다른 결과로 기록한다. 근거: [원본 entitlement](../../.reference/Filee/installer/macos/entitlements.plist), [원본 서명 스크립트](../../.reference/Filee/build/build-portable.ps1), [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

## 포함 범위에 맞는 고지

Filee MIT 고지와 외부 구성요소 고지를 번들에 포함한다. MIT는 변환 엔진 전체의 라이선스를 바꾸지 않는다. [원본 LICENSE](../../.reference/Filee/LICENSE)와 [THIRD-PARTY-NOTICES.md](../../.reference/Filee/THIRD-PARTY-NOTICES.md)를 보존하고, 게시 결과의 실제 구성과 대조한 앱 고지를 만든다.

- .NET runtime, Magick.NET/ImageMagick와 delegate libraries, PDFium/PDFtoImage, Skia/HarfBuzz, PDFsharp 및 managed 의존성은 각 패키지의 고지를 보존한다. ImageMagick delegate에는 LGPL 구성요소도 있다.
- 기본 `rhwp`는 MIT, `7zz`는 LGPL 및 실제 mac archive에 포함된 기타 고지를 보존한다. 원본의 Windows `7z.dll` 설명을 macOS 바이너리의 검증된 고지처럼 복사하지 않는다.
- 선택 설치하는 Pandoc·calibre·LibreOffice 등은 설치 화면과 설치된 엔진 폴더에 해당 고지를 보존한다. FFmpeg는 선택한 배포 빌드에 따라 라이선스가 달라지므로 Windows GPL 빌드 설명을 macOS 시스템 FFmpeg에 그대로 적용하지 않는다.
- Avalonia·SharpHook·Windows Explorer DLL·Inno Setup·테스트 전용 Open XML SDK는 helper에 포함하지 않는다. Noto·Material Design Icons 등은 SwiftUI UI에 실제로 포함한 경우에만 해당 자산 고지를 추가한다.

release manifest에는 NuGet·native·번들 엔진 목록과 고지 경로를 기록한다. 선택 설치되지 않은 외부 실행 파일을 앱에 포함했다고 표시하거나, 분리된 프로세스라는 이유로 고지를 생략하지 않는다.

## 구현 후 완료 조건

아래 항목은 배포 전 완료 조건이다. 로컬 arm64 게시·개발 서명은 실행했으며, 깨끗한 머신·Intel·Developer ID·공증 조건은 남아 있다.

1. 지정 SDK·잠긴 NuGet으로 두 RID를 각각 publish하고 runtime/native 자산·업스트림 manifest·고지를 보존한다.
2. SDK·Homebrew 엔진 없는 macOS 15 이상 머신에서 앱을 시작하고 helper catalog 요청이 실제 응답하는지 확인한다.
3. 각 아키텍처에서 ImageMagick 이미지 변환, PDFium PDF 렌더링, 한글 TXT→HWPX, rhwp HWP↔HWPX, 7zz 압축·해제를 실제 실행한다. 결과 디코딩·원본 보존·경로 충돌·취소도 확인한다.
4. helper가 자기 RID와 다른 외부 엔진을 실행하지 않는지 확인한다. 누락/미지원 native 자산은 사용 불가 사유로 응답하게 한다.
5. 모든 쓰기가 데이터/임시/출력 경로에만 발생하는지 확인한다. 앱 업데이트 뒤 설정·선택 엔진이 유지되고 서명된 번들은 변하지 않아야 한다.
6. archive 왕복 후 코드 서명·entitlement·native 로딩·Gatekeeper 실행을 확인한다. Developer ID hardened runtime 서명·공증·staple 후 동일 검증을 반복한다.
7. 서명된 Swift 앱 → helper로 Desktop·Documents·Downloads·외장 볼륨을 읽고 쓴다. 파일 선택·CustomFolder·감시 폴더에서 권한 요청 주체와 재실행 시 유지 여부를 확인한다. TCC 동작은 아직 검증하지 않았다.
8. upstream CI가 검사하는 CLI 시작·rhwp 시작·7zz 시작·한글 HWPX 생성에 더해 위 native smoke를 실행한다. macOS 14는 별도의 참고 호환성 결과로만 기록한다.

## 문서 조회 기록

- Context7: `library '.NET'` 성공; High 출처 `/dotnet/docs`, `/dotnet/core` 선택. docs 조회 두 번 모두 성공. self-contained 게시와 non-AOT apphost 서명 근거는 제공했으나 macOS 지원표의 값은 검색 결과에 없었다.
- 부족한 값은 공식 원문으로 확인했다: [supported-os.json 원문](https://raw.githubusercontent.com/dotnet/core/main/release-notes/10.0/supported-os.json), [macOS 게시 문서 원문](https://raw.githubusercontent.com/dotnet/docs/main/docs/core/deploying/macos.md). 확인일 2026-10-11.
- Apple allow-jit Markdown 원문을 읽었다. inheritance의 추정 Markdown 경로는 404였으며 위의 공식 App Sandbox 문서로 대체했다. Apple TN2206도 확인했다. 확인일 2026-10-11.
- Apple Context7 `library 'Apple Developer'`와 `/websites/developer_apple_de` docs 조회에 성공했다. 결과가 library validation entitlement 자체를 설명하지 않아 위 공식 Markdown 원문으로 보완했다. 확인일 2026-10-11.
- MSBuild 환경 변수 충돌은 기존 `/dotnet/docs`의 Context7 조회에 성공했으나 관련 설명이 부족했다. 공식 MSBuild 원문과 exact SDK의 property 평가로 보완했다. 확인일 2026-10-11.
- SDK 설치·arm64 .NET publish·native dylib 조사·ad-hoc 서명을 실행했다. Developer ID 서명·공증은 하지 않았다. 기존 SwiftUI 앱의 빌드 성공을 helper 배포의 성공으로 사용하지 않는다.
