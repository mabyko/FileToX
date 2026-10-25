# macOS 앱·변환 엔진 배포 설계

## 현재 Swift helper 패키징 (2026-10-25)

현재 빌드 입력은 `Package.swift`, `project.yml`, `Tools/stage-bundled-engines.sh`다.
엔진·helper 실행 파일·테스트·네이티브 라이브러리(LibRaw, PDFium, libjpeg-turbo, libwebp, libjxl, OpenJPEG, Skia SVG)는 `Package.swift` 한 곳에만 정의한다.
앱이 helper와 통신하는 `Sources/Core`(`FileToXCore`)도 패키지 제품이며 앱 타깃은 `import FileToXCore`로 쓴다(그래서 Core의 API는 `public`이다). `project.yml`은 그 패키지를 로컬 패키지로 참조하고, SwiftPM이 만들 수 없는 것만 더한다: 앱 번들 두 개(앱, helper), 서명, PDFium dylib 포함, rhwp·7-Zip 스테이징, 앱 테스트 번들. 엔진 리소스는 패키지의 리소스 번들(`FileToX_FileToXEngineKit.bundle`)로 helper와 테스트 번들에 복사된다.
변환 helper는 Swift 실행 파일이며 .NET runtime·NuGet DLL·JIT entitlement를 포함하지 않는다.
**Apple Silicon M1 이상(arm64), macOS 15 이상만 지원한다.** 최소 OS는 유지한다. `project.yml`의 공통 `ARCHS: arm64`가 앱·helper·테스트에 적용되고 `Tools/stage-bundled-engines.sh`는 arm64 외의 입력을 거부한다. Intel Mac·Rosetta 실행과 그 검증은 현재 지원 범위에 포함하지 않는다.
아래의 기존 .NET 설계는 전환 전 조사 기록이며 현재 빌드·서명 지침으로 적용하지 않는다.

```text
FileToX.app/Contents/Helpers/FileToXEngine.app/Contents/
  MacOS/FileToXEngine                  # Swift helper, host-wire-v1 NDJSON
  MacOS/engines/{rhwp,7zip}/...         # osx-arm64 pinned 실행 파일
  Frameworks/libpdfium.dylib           # arm64 추출 후 서명한 배포 사본
  Resources/FileToX_FileToXEngineKit.bundle/... # 엔진 카탈로그·번역·템플릿·Skia 고지
  Resources/Notices/...                # Filee, rhwp/7-Zip, LibRaw, PDFium 고지
```

PDF → 래스터는 C# PDFtoImage 5.2.1과 같은 PDFium을 사용한다. PDFium의 macOS universal
prebuilt dylib·공개 헤더·버전·빌드 설정을 `Vendor/PDFium`에 체크인했다. 원본 release asset의
SHA-256을 GitHub release digest와 대조했으며, arm64 실행 코드는 설치된 C# helper와 같다.
출처·해시·갱신 절차·실제 렌더 플래그는 [Vendor README](../../Vendor/PDFium/README.md)에 있다.
PDFium·Skia의 업스트림 버전·원본 해시·headers·고지는 보존한다. PDFium은 검증된 universal 소스 사본을 유지하고 배포 시 arm64만 추출한다. Skia bridge의 현재 정적 라이브러리와 재빌드는 arm64 전용이며 이전 universal 출력에서 추출한 경위를 provenance에 기록했다. 원본 고지나 C/C++ 소스를 줄이지 않는다.
PDFium을 받기 위한 빌드 중 네트워크 요청은 없다. PDFium은 BSD-3, 배포 패키징은 MIT이며,
번들 third-party 고지를 포함한 `docs/upstream/PDFium.*`를 staging script가 `Resources/Notices`에 넣는다.

XcodeGen이 dylib를 helper의 `Contents/Frameworks`에 복사하고 **Code Sign on Copy**로 서명한다.
install name은 `@rpath/libpdfium.dylib`, helper rpath는 `@executable_path/../Frameworks`와
`@loader_path/../Frameworks`다. PDFium 로딩은 소스 트리의 라이브러리 경로에 의존하지 않는다.
Debug 빌드에는 Xcode가 패키지 산출물 rpath도 추가하지만 PDFium은 번들의 상대 경로에서 로드한다.
이전 검증에서는 helper를 `/tmp`로 복사해 PDFium 로드·실제 렌더링·서명을 다시 검증했다. 동일 dylib를 엔진 XCTest 번들에도 포함한다. 서명 순서는 dylib·외부 엔진 → helper → 부모 앱이다.
Developer ID 배포에서는 모든 내부 Mach-O에 같은 Team ID를 사용하고 hardened runtime·타임스탬프·
공증·staple을 별도로 검증해야 한다. 로컬 ad-hoc 검증은 공증 검증을 대신하지 않는다.

SwiftPM은 `CPDFium` C 모듈과 체크인 dylib에 직접 링크한다. `swift build`/`swift test` 산출물은
소스 트리의 `Vendor/PDFium/lib`를 rpath로 사용하므로 checkout에서 바로 실행할 수 있다.
이 command-line 실행 파일만 별도 폴더로 옮길 때는 라이브러리/rpath도 함께 구성해야 한다.
배포에는 Xcode의 helper 번들을 사용한다. 기존 libwebp/libjxl 패키지는 첫 의존성 해석이 필요하고,
rhwp/7-Zip은 pinned archive 캐시가 없을 때 staging script가 내려받는다. 캐시가 있으면 재사용한다.

상위 작업에서 실행할 검증 명령은 `swift build --build-tests`, `swift test`,
`xcodegen generate`, `xcodebuild test -project FileToX.xcodeproj -scheme FileToX -destination 'platform=macOS,arch=arm64' ARCHS=arm64`다.
Swift package 의존성 빌드에도 적용되도록 Xcode 명령에 destination의 `arch=arm64`와 `ARCHS=arm64`를 함께 지정한다.
PDFium의 43건 비교 수치와 검증 결과는 [differential triage](engine-differential-triage.md#pdfkit-versus-pdfiumskia-rasterization)에 있다.
앱 내부는 서명 후 읽기 전용으로 유지한다. 설정·선택 엔진·임시/결과 경로의 기존 경계를 바꾸지 않는다.

Intel 정리 후 staging은 PDFium·번들 도구의 arm64만 추출하고 다시 서명한다. Skia 정적 bridge·재빌드도 arm64 전용이다. 검증된 PDFium·도구 원본과 고지는 그대로 두며 배포 앱의 Mach-O 5개는 모두 arm64임을 확인했다. [후속 검증](engine-differential-triage.md#intel-support-cleanup-2026-10-25)을 따른다.

## 현재 서명·데이터 경계와 검증 상태

Debug·Release의 기본 서명은 로컬 ad-hoc이며 hardened runtime을 켜고 App Sandbox는 끈다. Swift helper에는 JIT entitlement가 없다. `Tools/prepare-engine-entitlements.py`는 ad-hoc helper에만 PDFium 로딩을 위한 `disable-library-validation`을 만들며, 인증서 서명에서는 빈 entitlement를 만든다. 이 값은 Release helper 서명에 전달된다. 개발 예외를 Developer ID 검증 결과로 취급하지 않는다.

앱은 `~/Library/Application Support/FileToX/{core,engines,tmp}`를 쓰고 helper는 명시한 core·engines 경로와 격리한 TMPDIR을 사용한다. 최종 출력은 선택한 저장 규칙을 따른다. 출력별 staging·원본 보호·부분 실패 보고·시작 시 잔여 staging 정리는 [현재 아키텍처](../architecture.md#데이터-경계와-출력-안전)에 설명한다. 서명 후 앱 번들을 사용자 데이터나 엔진 설치 위치로 수정하지 않는다.

이전 [최종 통합 검증](engine-differential-triage.md#final-native-quality-integration-2026-10-24)에서는 기존 팀의 **개발 인증서로 실제 Xcode Release 빌드**, 내부 코드의 같은 Team ID, library-validation 예외 없는 helper, deep/strict 서명 검사와 재배치한 앱의 22개 검사를 확인했다. 이는 Developer ID 배포 서명·공증 검증이 아니다. 당시 x86_64 Release 교차 컴파일·링크는 통과했고 Intel 실행은 `Bad CPU type in executable`로 불가능했다. Rosetta를 설치하지 않았으며 이 과거 기록이 현재 Intel/Rosetta 검증 의무를 만들지는 않는다.

실행 소스 `70fff7d`에서 arm64 SDK 접근 차단 clean build와 엔진 테스트(581개, 57개 skip, 실패 0), 별도 clean 환경 앱 테스트 74개, 기존 팀 개발 인증서의 실제 Release 빌드·서명 검사, 저장소·SDK 접근을 차단한 재배치 실행 22개 검사를 통과했다. 실행 환경은 M2 Max/macOS 27이며 물리 M1 또는 macOS 15 실행을 주장하지 않는다. Developer ID 서명·공증은 미검증이다. 실제 변환 비교와 남은 차이는 [이전 arm64 검증 기록](engine-differential-triage.md#apple-silicon-only-final-verification-2026-10-25)을 따른다.

최신 소스 `5f9486a`에서도 SDK 접근 차단 clean build·엔진 644개(57개 skip), 별도 clean 환경 앱 74개, 개발 인증서 Release와 재배치 22개 검사가 통과했다. 번들의 Mach-O 5개는 arm64이며 .NET 파일·Homebrew 동적 의존성이 없다. 앱의 파일 크기 합계는 69,561,342바이트다. [최신 검증 기록](engine-differential-triage.md#cmyk-bmp-and-inspection-corrections-2026-10-25)에 명령과 실행 파일 해시를 보존한다. Developer ID·공증·물리 M1/macOS 15 검증은 완료하지 않았다.

배포 전에는 다음을 확인한다.

1. macOS 15 이상 Apple Silicon에서 앱·helper·테스트 및 native linkage가 arm64인지 확인한다. universal vendor 원본의 보존과 앱 링크 아키텍처를 구분한다.
2. Swift/Xcode 빌드·관련 테스트, 번들 rhwp·7-Zip과 이미지·PDF·문서 등 대표 변환, 진행·취소·원본 보존·충돌·다중 출력·부분 실패를 검증한다.
3. SDK·저장소·Homebrew 경로에 의존하지 않는 재배치한 helper 실행과 고지·리소스 포함, 설정·이력 호환성과 staging 정리를 확인한다. 별도 SDK 없는 OS/깨끗한 머신의 실행은 별도 미검증 항목이다.
4. Developer ID hardened runtime 서명·타임스탬프·공증·staple·Gatekeeper와 배포 archive 왕복 후 서명·native 로딩을 검증한다. 이 배포 경로는 아직 검증하지 않았다.
5. Desktop·Documents·Downloads 및 외장 exFAT·SMB, TCC 재실행, 실제 로그아웃/로그인 후 자동 실행·알림 동작을 확인한다. 이 항목들을 기존 로컬 검증으로 통과 처리하지 않는다.

## 현재 네이티브 구성 요소 고지

Filee MIT와 실제 포함한 엔진·라이브러리의 고지를 보존한다. MIT는 다른 구성 요소의 라이선스를 대체하지 않는다. PDFium 고지는 helper의 `Resources/Notices`, Skia 고지는 패키지 리소스 번들에 포함한다. OpenJPEG·libwebp·libjxl 등 나머지 native 구성 요소도 실제 산출물과 고지를 대조해야 한다.

- Swift helper에 정적 링크하는 LibRaw 0.22.2는 CDDL-1.0으로 사용한다. `docs/upstream/LibRaw.LICENSE`와 `LibRaw.THIRD-PARTY-NOTICES.md`(LibRaw COPYRIGHT, DCB/FBDD BSD, X3F BSD, Adobe DNG SDK MIT, 소스 위치)를 `Tools/stage-bundled-engines.sh`가 helper의 `Resources/Notices`에 넣는다.
- Swift helper에 정적 링크하는 libjpeg-turbo 3.2.0(libjpeg API 라이브러리, SIMD 없음)은 IJG 라이선스로 사용한다. 바이너리 배포 문서에 "this software is based in part on the work of the Independent JPEG Group"을 밝혀야 하므로 README 세 언어와 `docs/upstream/libjpeg-turbo.THIRD-PARTY-NOTICES.md`(IJG 라이선스 전문, 소스 위치)에 적고, 이 파일과 `libjpeg-turbo.LICENSE`(upstream `LICENSE.md`)를 `Tools/stage-bundled-engines.sh`가 helper의 `Resources/Notices`에 넣는다. 원본에서 뺀 파일은 `Vendor/libjpeg-turbo/README.FileToX.md`에 적는다(IJG 조건 1).

## 전환 전 .NET 패키징 조사 기록 (2026-10-11)

**이 절의 하위 항목은 전환 전 설계·실행 기록이다.** 조사 당시 `.reference/Filee`의 파일 링크는 고정한 업스트림 커밋의 원문 링크로 바꿨다. .NET SDK·NuGet·JIT 설정, 두 RID 배포 계획과 Intel 검증 항목은 당시 사실과 계획을 보존한 것이며 현재 Swift 빌드·서명 지침이나 완료 의무로 적용하지 않는다. 현재 지원 범위와 검증 상태는 위 절을 따른다. Swift 전환 후 추가된 LibRaw·libjpeg-turbo 고지는 위의 현재 고지 절로 옮겼다.

작성·공식 문서 확인일: 2026-10-11. SDK 10.0.401을 `~/.dotnet`에 설치했고 arm64 self-contained helper의 로컬 게시·ad-hoc hardened runtime 서명을 실행했다. Developer ID 서명·공증과 Intel 검증은 아직 수행하지 않았다.

### 배포 단위와 최소 OS

SwiftUI 앱 안에 변환 작업을 처리하는 self-contained .NET helper를 포함한다. 사용자에게 .NET 설치를 요구하지 않는다. 변환·형식·프리셋·프로필은 helper가 담당하고, Avalonia 앱·SharpHook·Windows 통합 코드는 포함하지 않는다.

**앱의 최소 지원 OS는 macOS 15로 정한다.** Xcode·Swift Package 타깃도 15로 맞췄다. 원본 README는 14 이상을 안내하지만, Microsoft의 .NET 10 지원표는 2026-09-28 갱신본에서 다음과 같이 분류한다.

| 항목 | 공식 지원표 값 |
| --- | --- |
| macOS 아키텍처 | `Arm64`, `x64` |
| 지원 OS | `27`, `26`, `15` |
| 미지원 OS | `14` |

이는 macOS 14에서 반드시 실행이 실패한다는 뜻이 아니다. 실행 가능성과 제조사의 지원 범위는 다르다. macOS 14 호환성을 별도로 시험할 수 있으나 제품 지원으로 약속하지 않는다. 근거: [Microsoft .NET 10 supported-os.json](https://github.com/dotnet/core/blob/main/release-notes/10.0/supported-os.json), [원본 README](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/README.md).

Apple silicon용 `osx-arm64`, Intel용 `osx-x64` 앱을 따로 배포한다. helper·.NET 런타임·native 라이브러리·외부 엔진이 모두 해당 RID에 맞아야 한다. 첫 배포에서는 두 게시 폴더를 합치거나 apphost만 `lipo`로 합치지 않는다. 동일 버전의 앱을 아키텍처별로 내보낸다. 참고: [Filee portable CI](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/.github/workflows/portable.yml).

### 원본을 고정하는 방법

참조 기준은 Filee `21fdd05ef7181b032ed83ec895cc9bbc4b198985`다. 버전 표시는 1.8.1이며, `global.json`은 SDK 10.0.100에 `latestFeature` roll-forward를 지정하고 공통 타깃은 `net10.0`이다. 근거: [global.json](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/global.json), [Directory.Build.props](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/Directory.Build.props).

구현할 때 다음 방식으로 빌드 입력을 고정한다.

- 해당 커밋의 소스와 고지를 `Vendor/Filee`에 보관한다. `.reference/Filee`는 조사용이며 release 빌드 입력으로 사용하지 않는다. 전체 소스 중 helper가 참조하는 프로젝트는 Core·Engines뿐이다.
- upstream URL·커밋·파일 SHA-256·적용한 패치를 manifest에 기록한다. 변경은 helper 프로젝트나 별도 패치에 두고 upstream 파일과 섞지 않는다.
- [Directory.Packages.props](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/Directory.Packages.props)의 직접 NuGet 버전뿐 아니라 transitive 의존성도 lock 파일에 고정한다. CI는 잠긴 복원 결과를 사용한다.
- release CI의 SDK 정확한 버전, Xcode 버전, RID, runtime 버전, NuGet lock 해시를 산출물 manifest에 남긴다. upstream의 `latestFeature`만으로 재현성을 주장하지 않는다.
- 외부 엔진은 [engines.json](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Infrastructure/engines.json)의 RID별 URL·버전·SHA-256을 함께 고정한다. URL의 이름이 같더라도 해시가 달라지면 실패한다.

서명·타임스탬프 때문에 최종 앱의 바이트 해시가 매번 같다는 목표와, 같은 소스·패키지·런타임으로 다시 빌드할 수 있다는 목표를 구분한다. 여기서 목표는 후자다.

### 앱 번들과 파일 위치

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

helper의 최종 assembly 이름은 [engine-host 설계](engine-host.md)와 맞춘다. 위 이름은 패키징 경계와 위치를 정하기 위한 것이다. `AppContext.BaseDirectory/engines/<id>`를 사용하는 [EngineEnvironment](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Infrastructure/EngineEnvironment.cs)의 탐색 경로에 맞춰 엔진을 배치한다. 참고: [build-portable.ps1](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/build/build-portable.ps1)은 게시 폴더 전체를 별도 앱의 `Contents/MacOS`에 보존한다.

**managed DLL·JSON이 code 디렉터리에 함께 있는 구조에는 배포 검증 조건이 있다.** 참고 스크립트는 managed 파일까지 개별 서명하며, 비-Mach-O 서명은 extended attribute에 저장된다. Apple은 코드·리소스 위치를 분리하고 비-Mach-O 파일의 extended attribute 서명에 의존하지 않는 구성을 권장한다. 따라서 위 구조는 apphost의 로딩 경로에 맞춘 시작점이며 공증 완료를 가정한 완성안이 아니다. 실제 SDK의 apphost 로딩 경로를 검증한 뒤 managed 데이터의 Resources 분리가 필요하면 수행한다. 검증 전에 DLL만 임의로 옮기거나 symlink로 해결하지 않는다. 근거: [Apple TN2206의 Nested Code](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

번들·카탈로그·고지는 읽기 전용이다. 서명 후 엔진 설치나 설정 기록으로 앱 내부를 바꾸지 않는다. 쓰기 위치는 다음으로 분리한다.

| 내용 | 위치·설정 |
| --- | --- |
| 설정·프리셋·프로필·이력·LibreOffice 프로필 | `~/Library/Application Support/FileToX/core`를 `UserDataStore`와 `EngineEnvironment`에 전달 |
| 선택 설치한 엔진 | `~/Library/Application Support/FileToX/engines`; `EngineEnvironment.DownloadRoot`도 명시적으로 설정 |
| 로그 | `~/Library/Application Support/FileToX/core/logs` |
| 임시 변환 | host 시작 전에 `TMPDIR=~/Library/Application Support/FileToX/tmp` 지정; 하위 작업 경로 `Filee/<jobId>`를 사용하고 종료 시 정리 |
| 최종 출력 | 프리셋의 저장 규칙; 앱 번들이 아님 |

`UserDataStore`의 경로만 바꾸면 다운로드 경로는 여전히 Filee 기본값이므로 두 경로를 모두 지정해야 한다. 근거: [UserDataStore](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Core/Settings/UserDataStore.cs), [EngineEnvironment](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Infrastructure/EngineEnvironment.cs).

### .NET·native 자산과 외부 엔진

self-contained 게시에는 apphost뿐 아니라 런타임·deps/runtimeconfig·모든 의존 파일이 필요하다. RID별 `--self-contained true`, `PublishReadyToRun=false`를 사용한다. 첫 구현에서 trimming·Native AOT·single-file을 추가하지 않는다. 앱 UI를 제외하는 최적화와 변환 엔진 의존성을 지우는 최적화를 혼동하지 않는다. 현재 Microsoft 문서의 self-contained 게시 방법도 확인했다. 근거: [Microsoft .NET 배포 문서](https://github.com/dotnet/docs/blob/main/docs/core/deploying/index.md).

Xcode build phase는 `TARGETNAME=FileToX`를 export한다. MSBuild가 이를 `TargetName`으로 읽으면 Core·Engines의 파일명이 모두 `FileToX.dll`이 되어 host 참조가 깨진다. `Tools/build-engine-host.sh`는 .NET 실행 전에 이 변수만 제거한다. host assembly 이름은 csproj에만 두며 전역 `-p:AssemblyName`도 사용하지 않는다. `bin/obj`를 비운 뒤 `TARGETNAME=FileToX` 환경에서 전체 restore·publish가 성공하는 것으로 확인했다. 환경 변수의 property 수입과 대소문자 무시는 [Microsoft MSBuild 문서](https://learn.microsoft.com/en-us/visualstudio/msbuild/how-to-use-environment-variables-in-a-build?view=vs-2022) 및 설치한 SDK의 targets로 확인했다.

[Filee.Engines.csproj](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Filee.Engines.csproj)의 Magick.NET, PDFtoImage/PDFium, SkiaSharp·Svg.Skia 등에는 native 자산이 따라온다. arm64에서 PDFium·HarfBuzz·Magick·Skia·Unhwp native 자산 약 57MB를 확인했으며, 이들 참조는 Apple 시스템 라이브러리만 사용하고 최소 OS는 14 이하이다. 전체 게시 폴더를 보존하며 Intel 결과는 별도로 검사한다. managed-only 빌드 성공은 PDF·이미지 엔진 실행 성공의 증거가 아니다.

| 엔진 범위 | macOS 패키징 |
| --- | --- |
| Core·내장 NuGet 엔진 | helper와 함께 게시; 실제 형식별 실행 검증 필요 |
| `rhwp` 0.8.6 | arm64/x64 각각 pinned archive를 검증하고 기본 번들에 포함 |
| `7zip` 26.03 | pinned mac archive에서 `7zz`와 고지를 보존하고 기본 번들에 포함 |
| Pandoc·LibreOffice·calibre | macOS RID별 다운로드 정의 있음; 사용자 선택 설치 또는 기존 경로 사용 |
| FFmpeg·Ghostscript | 현재 macOS 다운로드 정의 없음; 시스템 탐지·사용자 지정 경로 사용 |

기본 번들은 `rhwp`·`7zip`을 포함한다. 참고: [fetch-portable-engines.ps1](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/build/fetch-portable-engines.ps1). 선택 다운로드는 [EngineDownloads](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Infrastructure/EngineDownloads.cs)의 `CanDownload`로 판단한다. Windows용 H2Orestart·JRE·VC++ runtime을 macOS 패키지에 끌고 오지 않는다.

엔진 탐색은 사용자 지정→번들/다운로드→시스템 순서를 유지한다. macOS 앱은 터미널과 PATH가 다를 수 있으므로 `/opt/homebrew/bin`, `/usr/local/bin`, `/Applications/...app`에서도 엔진을 찾는다. 설치 작업의 SHA-256 검증·staging 교체·DMG 정리·취소는 [EngineInstaller](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/src/Filee.Engines/Infrastructure/EngineInstaller.cs)가 처리한다. 다운로드 성공과 Gatekeeper 실행 허용은 별도 검증하며 quarantine을 자동 제거하지 않는다.

### 서명과 entitlement 경계

첫 배포는 Developer ID로 직접 배포하는 앱으로 설계한다. App Sandbox·Mac App Store 배포를 이 설계에 섞지 않는다. 개인/조직 team ID, 인증서 이름, 공증 자격증명은 저장소에 넣지 않고 release 환경에서 전달한다.

SwiftUI 앱과 .NET helper는 실행 파일마다 별도로 서명한다. **부모 SwiftUI 앱에 `allow-jit`를 넣었다고 helper가 JIT 권한을 얻는 것으로 취급하지 않는다.** non-AOT .NET apphost 자체에 `com.apple.security.cs.allow-jit=true`를 부여한다. Microsoft가 이 요구사항을 명시한다. 근거: [Publish .NET apps for macOS](https://github.com/dotnet/docs/blob/main/docs/core/deploying/macos.md), [Apple allow-jit](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-jit).

`com.apple.security.inherit`는 App Sandbox 상속용이다. JIT/hardened runtime 설정을 자식 실행 파일에 복사하는 대체 수단이 아니다. 현재 direct-distribution 설계에는 넣지 않는다. 향후 sandbox를 채택하면 파일 접근·동적 권한 전달·선택 설치 엔진을 별도 설계해야 한다. 근거: [Apple App Sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).

서명 순서는 내부 Mach-O·native 라이브러리 → 외부 엔진 실행 파일 → .NET apphost/helper 앱 → SwiftUI 앱 순서다. 같은 release 서명 주체를 사용하고 `--options runtime`·타임스탬프를 적용한다. `--deep`로 일괄 서명하지 않으며 entitlement를 모두에게 뿌리지 않는다. `codesign --verify --deep --strict`는 마지막 검증에 사용한다. 원본 entitlement의 Apple Events 권한은 Filee의 다른 앱 통합에 해당하므로 helper에 자동 복사하지 않는다.

현재 `Tools/build-engine-host.sh`의 Debug·Release는 모두 로컬 ad-hoc 산출물이다. Team ID가 없는 ad-hoc dylib는 hardened runtime library validation 때문에 `libhostfxr` 로딩에 실패하므로, 이 경로만 `Config/EngineHost.AdHoc.entitlements`의 `allow-jit`와 `disable-library-validation`을 사용한다. apphost와 마지막 helper 앱 서명 모두에 명시한다. 배포용 Developer ID 경로는 내부 dylib까지 같은 Team ID로 서명하고 `Config/EngineHost.entitlements`의 `allow-jit`만 사용해야 한다. 개발 서명 파일을 배포 설정으로 복사하지 않는다. Apple의 기본 검증은 Apple 서명 또는 실행 파일과 동일 Team ID를 요구한다. 근거: [Apple Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation), 확인일 2026-10-11.

비-Mach-O 파일 서명을 보존해야 하는 후보 구조에서는 복사·압축·해제 과정의 extended attribute 보존이 release 조건이다. 실제 배포 아카이브를 새 디렉터리에 풀어 검증한다. ad-hoc 개발 서명 통과와 Developer ID hardened runtime·공증 통과를 서로 다른 결과로 기록한다. 근거: [원본 entitlement](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/installer/macos/entitlements.plist), [원본 서명 스크립트](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/build/build-portable.ps1), [Apple TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).

### 포함 범위에 맞는 고지

Filee MIT 고지와 외부 구성요소 고지를 번들에 포함한다. MIT는 변환 엔진 전체의 라이선스를 바꾸지 않는다. [원본 LICENSE](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/LICENSE)와 [THIRD-PARTY-NOTICES.md](https://github.com/KnifeLemon/Filee/blob/21fdd05ef7181b032ed83ec895cc9bbc4b198985/THIRD-PARTY-NOTICES.md)를 보존하고, 게시 결과의 실제 구성과 대조한 앱 고지를 만든다.

- .NET runtime, Magick.NET/ImageMagick와 delegate libraries, PDFium/PDFtoImage, Skia/HarfBuzz, PDFsharp 및 managed 의존성은 각 패키지의 고지를 보존한다. ImageMagick delegate에는 LGPL 구성요소도 있다.
- 기본 `rhwp`는 MIT, `7zz`는 LGPL 및 실제 mac archive에 포함된 기타 고지를 보존한다. 원본의 Windows `7z.dll` 설명을 macOS 바이너리의 검증된 고지처럼 복사하지 않는다.
- 선택 설치하는 Pandoc·calibre·LibreOffice 등은 설치 화면과 설치된 엔진 폴더에 해당 고지를 보존한다. FFmpeg는 선택한 배포 빌드에 따라 라이선스가 달라지므로 Windows GPL 빌드 설명을 macOS 시스템 FFmpeg에 그대로 적용하지 않는다.
- Avalonia·SharpHook·Windows Explorer DLL·Inno Setup·테스트 전용 Open XML SDK는 helper에 포함하지 않는다. Noto·Material Design Icons 등은 SwiftUI UI에 실제로 포함한 경우에만 해당 자산 고지를 추가한다.

release manifest에는 NuGet·native·번들 엔진 목록과 고지 경로를 기록한다. 선택 설치되지 않은 외부 실행 파일을 앱에 포함했다고 표시하거나, 분리된 프로세스라는 이유로 고지를 생략하지 않는다.

### 구현 후 완료 조건

아래 항목은 배포 전 완료 조건이다. 로컬 arm64 게시·개발 서명은 실행했으며, 깨끗한 머신·Intel·Developer ID·공증 조건은 남아 있다.

1. 지정 SDK·잠긴 NuGet으로 두 RID를 각각 publish하고 runtime/native 자산·업스트림 manifest·고지를 보존한다.
2. SDK·Homebrew 엔진 없는 macOS 15 이상 머신에서 앱을 시작하고 helper catalog 요청이 실제 응답하는지 확인한다.
3. 각 아키텍처에서 ImageMagick 이미지 변환, PDFium PDF 렌더링, 한글 TXT→HWPX, rhwp HWP↔HWPX, 7zz 압축·해제를 실제 실행한다. 결과 디코딩·원본 보존·경로 충돌·취소도 확인한다.
4. helper가 자기 RID와 다른 외부 엔진을 실행하지 않는지 확인한다. 누락/미지원 native 자산은 사용 불가 사유로 응답하게 한다.
5. 모든 쓰기가 데이터/임시/출력 경로에만 발생하는지 확인한다. 앱 업데이트 뒤 설정·선택 엔진이 유지되고 서명된 번들은 변하지 않아야 한다.
6. archive 왕복 후 코드 서명·entitlement·native 로딩·Gatekeeper 실행을 확인한다. Developer ID hardened runtime 서명·공증·staple 후 동일 검증을 반복한다.
7. 서명된 Swift 앱 → helper로 Desktop·Documents·Downloads·외장 볼륨을 읽고 쓴다. 파일 선택·CustomFolder·감시 폴더에서 권한 요청 주체와 재실행 시 유지 여부를 확인한다. TCC 동작은 아직 검증하지 않았다.
8. upstream CI가 검사하는 CLI 시작·rhwp 시작·7zz 시작·한글 HWPX 생성에 더해 위 native smoke를 실행한다. macOS 14는 별도의 참고 호환성 결과로만 기록한다.

### 문서 조회 기록

- Context7: `library '.NET'` 성공; High 출처 `/dotnet/docs`, `/dotnet/core` 선택. docs 조회 두 번 모두 성공. self-contained 게시와 non-AOT apphost 서명 근거는 제공했으나 macOS 지원표의 값은 검색 결과에 없었다.
- 부족한 값은 공식 원문으로 확인했다: [supported-os.json 원문](https://raw.githubusercontent.com/dotnet/core/main/release-notes/10.0/supported-os.json), [macOS 게시 문서 원문](https://raw.githubusercontent.com/dotnet/docs/main/docs/core/deploying/macos.md). 확인일 2026-10-11.
- Apple allow-jit Markdown 원문을 읽었다. inheritance의 추정 Markdown 경로는 404였으며 위의 공식 App Sandbox 문서로 대체했다. Apple TN2206도 확인했다. 확인일 2026-10-11.
- Apple Context7 `library 'Apple Developer'`와 `/websites/developer_apple_de` docs 조회에 성공했다. 결과가 library validation entitlement 자체를 설명하지 않아 위 공식 Markdown 원문으로 보완했다. 확인일 2026-10-11.
- MSBuild 환경 변수 충돌은 기존 `/dotnet/docs`의 Context7 조회에 성공했으나 관련 설명이 부족했다. 공식 MSBuild 원문과 exact SDK의 property 평가로 보완했다. 확인일 2026-10-11.
- SDK 설치·arm64 .NET publish·native dylib 조사·ad-hoc 서명을 실행했다. Developer ID 서명·공증은 하지 않았다. 기존 SwiftUI 앱의 빌드 성공을 helper 배포의 성공으로 사용하지 않는다.
