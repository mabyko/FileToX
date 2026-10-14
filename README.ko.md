# FileToX

[English](README.md) | [한국어](README.ko.md) | [日本語](README.jp.md)

FileToX는 [Filee](https://github.com/KnifeLemon/Filee)에서 영감을 받아 만든 Mac 전용 파일 변환 앱이다. 파일을 놓고 원하는 형식을 고르면 변환할 수 있다.

SwiftUI와 AppKit으로 만들었으며 macOS 15 이상에서 실행한다. 기본 언어는 영어이고 한국어와 일본어도 지원한다.

## 20초로 보는 FileToX

[![Finder에서 Option 키로 PNG를 드래그하고 JPG에 드롭하는 FileToX 시연](docs/media/filetox-demo.gif)](docs/media/filetox-demo.mp4)

[20초 소개 영상 보기](docs/media/filetox-demo.mp4) · Finder Option 드래그를 실제로 촬영한 영어 자막의 무음 영상이다.

FileToX를 메뉴 막대에서 실행해 둔 채, Finder에서 파일을 드래그한 뒤 Control(⌃)을 누른다. 원형 메뉴의 변환 형식에 드롭하면 된다. 앱의 메인 창은 닫아둬도 된다. **설정 → 호출 키**에서 Control·Option·Shift·Command를 조합하고 문자·숫자·기능 키·방향 키·스페이스를 추가할 수 있다. **저장**을 누르면 이 Mac에 유지된다. 활성화된 macOS 시스템 단축키와 Finder 드래그 동작이 겹치면 경고를 표시하며, 다른 앱이 등록한 단축키는 검사 범위에 포함되지 않는다.

## 기능

- Finder에서 파일을 드래그하며 설정한 호출 키(기본값 Control)를 누르거나, 앱에서 파일·폴더를 선택해 원형 변환 메뉴를 연다.
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

macOS에서 실행한 영어 Release 버전의 실제 화면이다.

## 사용 방법

1. 홈 화면에 파일을 놓거나 파일·폴더를 선택한다.
2. 원형 메뉴에서 프리셋을 고르거나 **모든 출력 형식**에서 원하는 형식을 선택한다.
3. 원본 폴더 또는 지정한 출력 폴더에서 결과를 확인한다.

첫 실행에는 Finder 드래그 호출에 쓰는 손쉬운 사용 권한 안내가 뜨고, 시스템 설정에서 돌아오면 허용 여부를 확인한다. **나중에**를 선택하면 홈에서 바로 변환할 수 있고, **호출 키 → 설정 방법 보기**에서 안내를 다시 열 수 있다. 변환 런타임은 앱에 포함되어 있어 .NET을 따로 설치할 필요가 없다.

등록된 모든 형식 사이의 변환을 보장하지는 않는다. 변환 경로 탐색기가 입력·엔진 상태에 따라 사용 가능한 프리셋과 출력 형식을 판단한다. 읽기 전용 형식 58개는 출력에 나타나지 않는다. 설치되지 않은 엔진과 macOS에서 불가능한 경로는 이유를 표시한다.

기본 번들에는 내장 라이브러리와 rhwp·7-Zip을 포함한다. FFmpeg·Ghostscript·Pandoc·LibreOffice·Calibre는 시스템 설치 또는 **변환 엔진 → 외부 엔진 실행 파일**에서 지정한 사본을 사용한다. 개발용 다운로드 도구가 받은 사본은 자동으로 사용자의 설정에 등록하지 않는다.

출력은 원본 폴더의 숨김 작업 폴더에 쓴 뒤 결과별로 게시한다. 원본 파일은 Overwrite에서도 보호하고, 기본 충돌 정책은 새 이름이다. 여러 결과의 게시 중 실패하면 이미 게시한 결과를 정확히 보고한다. 전체 묶음을 한 번에 되돌리는 원자성을 약속하지 않는다. 데이터는 `~/Library/Application Support/FileToX/{core,engines,tmp}`로 분리한다.

<details>
<summary>개발·빌드 방법과 검증 기록</summary>

## 빌드와 실행

Xcode 27 / Swift 6.4, XcodeGen 2.46 이상을 사용한다. 빌드에 필요한 .NET SDK는 `Config/EngineHost.global.json`의 10.0.401이다. `~/.dotnet`의 SDK를 사용하거나 `DOTNET_ROOT`에 SDK 설치 폴더를 지정한다. SDK 설치는 [Microsoft 공식 다운로드](https://dotnet.microsoft.com/download/dotnet/10.0)를 따른다.

```sh
xcodegen generate
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open 'build/DerivedData/Build/Products/Debug/FileToX Dev.app'
```

Xcode 빌드 단계가 원본 해시를 검증하고 패치를 적용한 사본으로 helper를 게시·서명·포함한다. 첫 빌드는 NuGet과 고정 버전의 rhwp·7-Zip을 받는다. 이후 소스가 같으면 이전 빌드 결과를 캐시에서 읽는다.

```sh
Tools/build-engine-host.sh --rid osx-arm64 --configuration Debug
python3 Tools/fetch-optional-engines.py --help
```

개발 식별자는 `forked.filetox.local.dev`, Release는 `forked.filetox.local`이다. 개인 설정은 Git에서 제외하는 `Config/Local.xcconfig`에 둔다. 현재 Debug·Release 서명은 로컬 ad-hoc용이다. Developer ID 서명·공증은 완료하지 않았다. Intel 빌드 옵션은 있지만 실행은 확인하지 않았다.

## 검증

```sh
swift test
xcodebuild -project FileToX.xcodeproj -scheme FileToX -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test
python3 -I Tools/verify-filee-vendor.py --selftest
python3 -I Tools/verify-filee-vendor.py
python3 -I Tools/import-filee-formats.py --check
python3 -I -m unittest discover -s Tests/Tools -v
```

실제 helper 통합 테스트는 먼저 helper를 빌드해야 한다. 없으면 해당 테스트만 skip한다. 별도 helper 경로는 `FILETOX_TEST_HOST`로 지정할 수 있다. 실제 엔진 표본은 아래 스크립트로 재현한다. 작업 폴더는 새 절대 경로를 사용한다.

```sh
python3 EngineHost/smoke.py \
  "$PWD/build/engine-host/osx-arm64/Debug/FileToXEngine.app/Contents/MacOS/FileToXEngine" \
  "$PWD/build/smoke-new"
python3 EngineHost/optional-smoke.py --help
```

Apple silicon에서 Xcode 테스트 32개, Swift Package 테스트 12개, 내장 엔진 검증 22개(실제 변환 20개·선택 판단 2개), 추가 엔진·영상·음성·실행 중 취소·첨부 이미지 충돌 표본 11개를 통과했다. Swift 통신에서도 실제 PNG→JPG, PDF 병합→여러 PNG, unknown 파일·폴더 ZIP→압축 해제와 이력을 확인했다. 실제 앱의 도넛 JPG 클릭→결과 생성→최근 이력도 통과했다. 실제 Finder Option 드래그에서도 느린 움직임, 원본 보존과 드롭 후 Finder 포커스 유지를 확인했다. 한글 HWP·DOCX에서 만든 PDF의 텍스트 추출과 PNG 렌더링도 확인했다. 영어·한국어·일본어 변경은 실행 중인 앱과 helper에 바로 반영된다. 기본 색상 선택기로 고른 색의 재실행 후 유지, 기본 프리셋 이름 번역과 사용자 이름 보존도 확인했다.

원본 Core는 154 통과·2 skip, 패치한 Core는 164 통과·2 skip이다. Engines는 원본과 패치 모두 445 통과·3 실패이며, 이 3개 실패는 이 머신의 FFmpeg 인코더 부족이다. 추가한 실제 엔진 테스트 4개는 Pandoc·LibreOffice가 있을 때 통과한다.

모든 형식 조합·코덱을 검사하지 않았다. Ghostscript는 이 머신에 없고, 현재 FFmpeg에는 일부 인코더가 없다. 자동 변환 폴더, 앱 안에서 엔진 다운로드, 로그인 항목은 아직 연결하지 않았다. 외장 exFAT·SMB, Intel, 배포 공증·TCC 재실행 검증도 남아 있다.

## 소스와 설계

개발 참고 기준은 [KnifeLemon/Filee](https://github.com/KnifeLemon/Filee) 커밋 `21fdd05ef7181b032ed83ec895cc9bbc4b198985`다. 파일 정보와 SHA-256은 `Vendor/filee-manifest.json`에, 빌드 패치는 `Vendor/Filee.patches/`에 기록한다. `.reference/Filee`는 카탈로그 재생성에만 필요하다.

- [전체 형식 목록](docs/formats.md), [전체 설계](docs/architecture.md)
- [통신 계약](docs/design/host-wire-v1.md), [host 구현](EngineHost/README.md)
- [UI 설계](docs/design/swiftui-port.md), [패키징·서명](docs/design/macos-packaging.md)
- [Claude 설계 검토](docs/design/review.md), [엔진 구현·검증 현황](EngineHost/IMPLEMENTATION.md)

이전 대화의 시안은 `docs/archive/pre-filetox/`에 보존한다. 노치 선반·파일 보관·이동·복사는 현재 범위에 포함하지 않는다.

</details>

## 감사의 말

FileToX는 [Filee](https://github.com/KnifeLemon/Filee)에서 영감을 받아 만든 Mac 전용 파일 변환 앱이다. SwiftUI와 AppKit으로 macOS에 맞게 만들었으며, Filee의 공식 배포판이 아닌 독립 프로젝트다.

FileToX는 [MIT 라이선스](LICENSE)로 배포한다. Filee의 [MIT 라이선스](docs/upstream/Filee.LICENSE)와 [외부 구성요소 고지](docs/upstream/Filee.THIRD-PARTY-NOTICES.md)를 보존한다. MIT는 각 외부 엔진의 라이선스를 대신하지 않는다. 실제 번들 고지는 helper의 `Contents/Resources/Notices`에 포함한다.
