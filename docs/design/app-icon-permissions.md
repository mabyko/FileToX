# 앱 아이콘과 첫 실행 권한 안내 설계

FileToX를 처음 실행하면 메인 창 위에 권한 안내 시트를 띄운다. 사용자가 시스템 설정에서 손쉬운 사용 권한을 허용하고 돌아오면 같은 시트에서 실제 허용 여부를 확인한다. ‘나중에’를 선택하면 홈에서 파일을 선택하거나 놓아 변환을 시작할 수 있다. 앱 아이콘은 Option 드래그로 여는 원형 변환 메뉴를 단순화한 도넛으로 만든다.

상태: 아이콘과 안내 시트 구현 완료. [화면과 동작 미리보기](app-icon-permissions.html). 이번 확인창의 범위는 권한 허용 여부이며, 변환 실행·삭제·덮어쓰기 확인은 별도다. 실제 시스템 설정에서 허용·철회하는 TCC 전환은 수동 검증이 남아 있다.

## 현재 구조

- `Resources/Assets.xcassets`에 AppIcon·AppIcon-Dev·MenuBarIcon을 등록했다. 실제 빌드 식별자는 Release `forked.filetox.local`, Debug `forked.filetox.local.dev`이며 표시 이름은 각각 FileToX와 FileToX Dev다. `project.yml`에서 구성별 AppIcon을 선택한다.
- `AppModel`이 `AXIsProcessTrusted()`로 상태를 읽고 `requestAccessibilityPermission()`에서 시스템 안내를 요청한다. `AppDelegate.applicationDidBecomeActive`와 `ConverterView.onAppear`에서 상태를 갱신한다.
- `PermissionOnboardingView`가 첫 실행 안내·설정 대기·완료 화면을 제공한다. `SettingsViews`의 호출 키 페이지에서 같은 안내를 다시 열 수 있다.
- `GlobalDragMonitor`는 앱 시작 때 등록되고 권한이 미허용에서 허용으로 바뀌면 다시 등록된다. 마우스 버튼을 누르고 있으면 드래그 종료 후 등록한다.
- 기본 언어는 영어이고 한국어·일본어를 지원한다. 아래 한국어 문구는 세 언어 리소스로 함께 추가한다.

## 앱 아이콘

추천안은 Option 드래그로 뜨는 원형 메뉴의 도넛 모양이다. 실제 메뉴와 같은 8개 부채꼴, 중앙의 빈 공간, 우상단의 파란 선택 영역을 남긴다. 확장자와 중앙 파일 수 문구를 덜어내 작은 크기에서도 형태를 읽을 수 있게 한다. 부채꼴의 위치와 중앙 구멍 비율은 기존 `DonutWedge`와 기본 원형 메뉴를 따른다. 설치 아이콘에서는 영역 수와 선택 위치를 고정한다.

밝은 중성색 바탕에 짙은 회색 도넛을 놓고, 한 영역에 기본 강조색 `#3478F6`을 사용한다. 가운데 공간에는 바탕색이 보이게 한다. 사용자 테마 색을 바꿔도 설치 아이콘은 유지한다. 메뉴 막대에는 같은 도넛을 단색 template 이미지로 사용하되, 작은 크기에 맞춰 구분선을 4개로 줄인다. 앱 아이콘과 메뉴 막대 아이콘은 서로 다른 자산으로 관리한다. 권한 안내창에도 같은 앱 아이콘을 표시해 사용자가 시스템 설정 목록에서 쉽게 찾도록 한다.

편집 가능한 벡터 소스는 `Tools/generate-app-icons.swift`다. `swift Tools/generate-app-icons.swift`로 1024×1024 Release·Debug 원본과 카탈로그의 작은 크기들을 함께 생성한다. 원본 PNG는 `docs/design/assets/AppIcon.png`, `AppIcon-Dev.png`에 저장한다. Debug는 같은 원본에 주황색 모서리 표시를 더해 구분한다. 두 앱을 함께 설치하는 현재 구성에 맞춘 자산이다.

자산 경로는 `Resources/Assets.xcassets/AppIcon.appiconset`, `AppIcon-Dev.appiconset`, `MenuBarIcon.imageset`이다. macOS 15에서도 쓸 수 있는 기존 asset catalog 방식으로 연결했다. 설치 아이콘은 둥근 모서리와 투명 여백을 포함한 PNG이며, 메뉴 막대는 18pt 벡터 PDF template 이미지다. 최신 OS용 Icon Composer 레이어를 추가한다면 별도로 마스크 없는 원본을 만들고 호환성을 검증한다. 제작 원칙은 [Apple App icons](https://developer.apple.com/design/human-interface-guidelines/app-icons/), [asset catalog 설정](https://developer.apple.com/documentation/xcode/configuring-your-app-icon), [macOS 카탈로그 슬롯](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/AppIconType.html)을 따른다.

## 첫 실행 흐름

1. 메인 창을 연 뒤, 최초 안내를 아직 마치지 않았다면 약 500pt 폭의 시트를 표시한다. 현재 앱 언어와 실제 번들 표시 이름을 사용한다. 언어 설정을 읽는 기존 연결 흐름 뒤에 붙이되 엔진 연결 실패가 권한 안내를 막지 않게 한다.
2. 처음부터 권한이 있으면 시트의 완료 화면을 표시한다. 없으면 목적·설정 방법·나중에 선택할 수 있다는 안내를 표시한다. 시스템 요청은 사용자가 버튼을 누를 때 실행한다.
3. ‘시스템 설정 열기’를 누르면 시스템 권한 요청을 실행하고 시트는 대기 화면으로 바뀐다. 손쉬운 사용 설정 화면으로 직접 이동하는 링크는 가능한 경우 사용하되, 열기 실패나 OS 차이에 대비해 ‘시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용’ 경로를 항상 제공한다. 요청을 성공적으로 호출했다는 사실과 권한 허용은 별개다.
4. 앱이 다시 활성화되거나 사용자가 ‘허용 여부 확인’을 누르면 실제 권한을 동기로 다시 읽는다. 아직 허용되지 않았다면 같은 화면에서 안내한다. 짧은 동기 조회이므로 별도 로딩 상태는 추가하지 않는다.
5. 허용되면 같은 시트가 완료 화면으로 바뀐다. ‘시작하기’를 누르면 홈으로 돌아간다. 성공 사실을 별도의 모달로 다시 확인하지 않는다.
6. ‘나중에’, Escape, 시트 닫기는 모두 건너뛰기로 처리하고 홈으로 돌아간다. 다음 실행에서는 자동으로 띄우지 않고, 호출 키 설정의 ‘설정 방법 보기’로 다시 열 수 있다.
7. 파일 열기로 앱이 시작된 경우 파일을 먼저 선택·판단하고 자동 안내는 보류한다. 파일 변환 흐름이 끝난 뒤 안내를 제시하며, 최초 안내 완료 여부는 보류만으로 기록하지 않는다.

‘시작하기’ 또는 건너뛰기를 선택할 때만 Swift 앱의 `UserDefaults`에 `hasCompletedPermissionOnboarding`을 기록한다. 앱을 강제로 종료했거나 안내를 마치기 전에 종료했다면 다음 실행에 다시 나타난다. 이 값은 앱 UI의 안내 이력이며 host 설정을 복제하지 않는다. 허용 상태는 저장하지 않고 매번 macOS에서 읽는다. Debug와 Release의 안내 이력은 각 번들에 속한다.

## 화면 문구

### 처음 안내

제목: **Finder에서 바로 변환해 보세요**

본문: Finder에서 Option(⌥) 키를 누르고 파일을 드래그하면 원형 변환 메뉴를 열 수 있어요. 키와 드래그 동작을 감지하는 데 손쉬운 사용 권한을 사용합니다.

보조 문구: 권한 설정은 나중에 해도 됩니다. 홈에서 파일을 선택하거나 놓아 변환할 수 있어요.

버튼: **나중에** / **시스템 설정 열기**

단계 안내:

1. 시스템 설정에서 **개인정보 보호 및 보안 → 손쉬운 사용**을 엽니다.
2. 목록에서 **FileToX**를 켭니다. Debug에서는 실제 표시 이름인 **FileToX Dev**를 보여줍니다.
3. FileToX로 돌아오면 허용 여부를 확인합니다.

앱이 목록에 없다면 더하기 버튼으로 현재 실행 중인 앱을 추가하도록 보조 도움말에 안내한다. 앱 경로와 표시 이름은 번들에서 얻는다. 설정 경로는 [Apple 손쉬운 사용 권한 안내](https://support.apple.com/guide/mac-help/mh43185/mac)를 기준으로 한다.

### 시스템 설정 대기

제목: **손쉬운 사용에서 FileToX를 켜주세요**

본문: 시스템 설정에서 허용한 뒤 이 창으로 돌아오세요. 돌아오면 허용 여부를 다시 확인합니다.

상태: **아직 허용이 확인되지 않았어요**

버튼: **나중에** / **허용 여부 확인**

보조 동작: **시스템 설정 다시 열기**

수동 확인 후 여전히 미허용: 아직 허용이 확인되지 않았어요. 현재 실행 중인 FileToX가 켜져 있는지 확인해 주세요.

설정 열기 실패: 시스템 설정을 열지 못했어요. ‘개인정보 보호 및 보안 → 손쉬운 사용’에서 FileToX를 켜주세요.

### 허용 확인

제목: **권한을 확인했어요**

상태: **손쉬운 사용 권한 허용됨**

본문: Finder에서 Option(⌥) 키를 누르고 파일을 드래그해 보세요. 원형 메뉴에서 원하는 형식에 놓으면 변환을 시작합니다.

버튼: **시작하기**

이 화면은 권한 조회 성공을 뜻한다. 외부 드래그의 전체 동작을 검증했다고 표시하지 않는다. 동작이 여전히 반응하지 않을 경우 설정 도움말에서 앱 재실행을 안내한다.

## 상태와 책임

실제 권한은 `AppModel.hasAccessibilityPermission`, 시트 화면은 `PermissionOnboarding.Step`의 `intro / waiting / success`로 구분한다. step이 nil이면 안내창이 닫혀 있다. `waiting`은 설정 요청을 실행한 UI 상태이며 거절 상태가 아니다. AX 조회가 false라고 사용자가 거절했다고 단정하지 않는다. `hasCompletedPermissionOnboarding`도 권한 상태와 별개다.

`AppModel`의 기존 조회·요청 함수를 활용한다. `AppDelegate.applicationDidBecomeActive`에서 갱신한 결과를 시트가 관찰하고, `ConverterView`가 시트를 표시한다. `PermissionOnboarding`은 파일 열기 처리·변환·원형 메뉴가 끝날 때까지 최초 안내를 보류한다. 안내창이 닫혔으면 자동 조회 결과가 새로운 창을 띄우지 않는다. 재실행·권한 철회 시에는 호출 키 설정에 실제 상태를 표시한다.

권한이 false→true로 바뀌면 기존 `stop()`→`start()`로 외부 이벤트 모니터를 다시 등록하되 활성 드래그가 끝난 다음 수행한다. 이 과정에서 변환 작업이나 파일 선택을 초기화하지 않는다.

[AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)의 시스템 안내는 비동기이며 함수 반환값은 당시의 신뢰 상태다. 반환값을 요청 완료·거절 판단에 사용하지 않는다. 앱 활성화 시 조회와 수동 확인을 기본으로 하며 상시 폴링은 추가하지 않는다.

[NSEvent 공식 문서](https://developer.apple.com/documentation/appkit/nsevent/addglobalmonitorforevents(matching:handler:))는 외부 키 이벤트 감시에 손쉬운 사용 권한 조건을 명시한다. 현재 모니터는 마우스 이벤트와 `flagsChanged`를 함께 사용하므로 macOS 15와 실제 배포 서명에서 권한 전후의 Option 드래그를 검증한다. 권한이 없다는 이유만으로 모든 마우스 드래그나 앱 내 변환을 일괄 차단하지 않는다. 손쉬운 사용 외의 권한 요청은 실제로 필요한 API가 확인될 때 별도로 설계한다.

## 접근성과 표시

기존 시스템 글꼴, `model.accentColor`, `themeColorScheme`, `Motion`과 카드 스타일을 사용한다. 제목은 약 22pt, 본문은 13–14pt, 외곽 여백은 24pt로 시작하고 번역 길이에 맞춰 높이를 늘린다. 완료 아이콘은 색과 텍스트를 함께 표시한다. Tab 이동, Escape로 건너뛰기, VoiceOver의 제목·상태 읽기를 지원한다. 설정에서 돌아와 상태가 갱신돼도 버튼 포커스를 임의로 옮기지 않는다. Reduce Motion에서는 화면 전환 애니메이션을 줄인다.

## 검증

Debug·Release 빌드와 `codesign --verify --deep --strict` 검증을 통과했다. 자산 카탈로그 경고는 없으며 Info.plist의 CFBundleIconName·CFBundleIconFile이 각각 AppIcon-Dev·AppIcon을 가리킨다. AppIntents 미사용에 따른 기존 메타데이터 추출 경고는 있다.

앱 테스트 40개와 Core 테스트 12개를 통과했다. 추가한 `PermissionOnboardingTests` 6개는 최초 미허용·기허용, 요청 후 실제 허용 확인, 철회, 완료 후 재실행, 파일 열기 지연·동시 열기, 늦은 파일 열기로 안내를 숨기는 경우를 검증한다. 번역 키 일치와 리소스 문법도 확인했다. 실제 SwiftUI 렌더링으로 영어·한국어·일본어의 안내·대기·완료 화면 배치를 확인했다.

실제 TCC 설정에서 허용·철회하고 앱으로 돌아오는 동작과 권한 변경 후 Finder Option 드래그는 Debug·Release를 구분해 수동으로 확인해야 한다. 테스트에서는 사용자의 권한이나 기존 TCC 기록을 변경하지 않았다. HTML 목업은 디자인 검토용이며 실제 화면은 SwiftUI 시트다.
