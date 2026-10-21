# Tangerine 참고 조사: 디자인 자료와 REA 적용 조건

- 조사일: 2026-10-21 (Asia/Seoul)
- 대상: SwiftUI/AppKit 기반 macOS 파일 변환기 FileToX의 UI/UX 개선 가능성.
- 범위: 지정된 공개 디자인 자료와 morluto/rea 공식 README·가이드만 열람했다. 설치, 앱 실행, 바이너리 분석, Tangerine 코드 복사, 계정 설정 변경은 하지 않았다.
- REA 문서는 `main` 커밋 `3a0e91dd914145ecb9accbdeb68ecf7fe4d5133d` 열람 기준이다. 아래의 ‘지원’은 문서상의 범위이며 이 환경에서의 실행 검증이 아니다.

## 판단

**제안:** FileToX 개선은 작업 흐름과 상태 표현을 먼저 검토하고, Tangerine 내부 구현에 관한 구체적인 미해결 질문이 남을 때 REA를 검토한다. 디자인 자료는 비교·평가 기준으로 활용할 수 있다. 바이너리 분석이 시각적 완성도나 사용성을 자동으로 판정하지는 않는다.

**현재 미확인:** Tangerine 네이티브 앱의 버전·배포본·아키텍처, 실제 앱 화면과 동작, 내부 UI 기술. 별도 주 작업에서 공개 웹 데모를 관찰했으며, 아래 비교는 네이티브 바이너리 분석 결과가 아니다.

## FileToX와 공개 데모의 비교 — 주 작업에서 추가 확인

- **공개 웹에서 확인:** [Tangerine](https://tangerineformac.com/)의 예시 파일 `landscape.jpg`에서 Enter를 누르면 `Choose a conversion format` 메뉴가 열리고 `Convert to PNG` 항목에 포커스가 생겼다. 페이지는 방향키·Enter·Escape 조작을 안내하며 모든 작업이 시뮬레이션임을 명시한다. 네이티브 앱의 동일 동작은 미검증이다.
- **코드에서 확인:** FileToX의 [`GlobalDragMonitor`](../../Sources/Platform/GlobalDragMonitor.swift)는 파일 payload를 기다리는 동안 호출 키가 필요하지만, 메뉴 호출 완료 후 키 해제만으로 메뉴를 닫지 않는다. [`DragGestureState`](../../Sources/Platform/DragGestureState.swift)도 한 드래그에서 중복 호출을 막는다. ‘키를 떼어도 메뉴 유지’는 이미 있는 동작이며, 네이티브 실사용 재검증은 하지 않았다.
- **코드에서 확인:** [`FormatDropView`](../../Sources/UI/FormatDropView.swift)는 마우스 선택, 가운데 닫기, Escape를 제공한다. 방향키로 섹터를 이동하는 명시적 처리는 확인되지 않았다. 키보드 개선은 드래그 중 Finder 포커스를 보존하는 경로와 클릭 모드를 구분해 설계해야 한다.
- **코드에서 확인:** [`HomeView`](../../Sources/UI/HomeView.swift)는 큰 드롭 영역을 유지하고 선택 파일과 전체 출력 목록을 별도로 표시한다. [`AppModel.resolve`](../../Sources/App/AppModel.swift)는 기본적으로 커서 위치에 원형 메뉴를 연다. 홈 안에서 출력 형식을 고르는 흐름으로 바꾸려면 이 호출 경로도 함께 검토해야 한다. 이력의 Finder 표시·실패 상세·재시도는 이미 구현돼 있다.
- **제안 시안:** [파일 선택 후 홈 구성](../design/filetox-ux-direction.html). 기존 파란 강조색, 시스템 서체와 SF Symbols를 유지하고, 선택 파일·사용 가능 출력·저장 위치·변환 행동을 같은 화면에 묶는다. 예시 데이터만 사용하는 HTML이며 앱 소스를 변경하지 않았다.
- **후속 구현의 완료 기준:** (1) 홈에서 파일 선택 후 입력과 출력 형식이 함께 보임, (2) 사용 불가 형식에 이유가 제공됨, (3) 클릭 모드의 방향키·Enter·Escape와 포커스 복귀 검증, (4) Finder 드래그·취소·원본 보존 회귀 확인, (5) 영어·한국어·일본어 및 긴 파일명에서 레이아웃 확인, (6) 라이트·다크·Reduce Motion·VoiceOver 확인. 엔진의 실행 가능 여부와 충돌 정책을 UI에서 임의로 판단하지 않는다.
- **시안 검증:** 728px·360px 렌더와 다크 화면을 확인했다. Chrome for Testing에서 시작·선택·완료 전환, 포맷명 갱신, 저장 위치 반영, 포커스 이동, Finder 시뮬레이션 안내, 테마 전환의 7개 확인이 통과했다. 실제 앱 빌드·엔진 변환·네이티브 접근성 검증은 이번 범위에서 수행하지 않았다.

## 디자인 참고 자료의 역할

### Lucian UX/UI Prompt

- **확인:** 웹 인터페이스와 애니메이션 예시를 프롬프트·코드로 제공한다. 밝은/어두운 테마, 폼 검증, 설정 패널, 목록·상세 표시 등 다양한 예시가 있다. [공식 페이지](https://lucianlabs.dev/uxui-prompt/)
- **제안:** 파일 추가 → 출력 형식·위치 선택 → 변환 → 결과 확인의 정보 위계, 빈 상태, 진행·오류 피드백을 비교하는 아이디어 목록으로 쓴다.
- **네이티브 적용:** 필요한 행동과 상태를 SwiftUI/AppKit 컨트롤로 다시 설계한다. 웹의 CSS·스크롤 효과·장식 애니메이션을 그대로 이식할 필요는 없다.
- **미확인:** 제공 예제가 네이티브 macOS 접근성·키보드 탐색·창 크기 변경까지 검증했다는 근거는 이번 자료에서 확인하지 못했다.

### Lucian Icons

- **확인:** MIT로 공개된 움직이는 SVG 아이콘이며 HTML·React·SVG 형식과 상태 전환 예시를 제공한다. [공식 페이지](https://lucianlabs.dev/icons/)
- **제안:** 기본 작업 아이콘은 **SF Symbols를 우선**하고, Lucian은 의미 전달과 상태 전환의 참고로 쓴다. 고유 자산이 꼭 필요할 때만 별도로 검토한다. 이는 FileToX에 대한 제안이며 해당 사이트의 macOS 권고가 아니다.
- **네이티브 적용:** 변환 중·완료·실패를 텍스트와 함께 표현하고, 색·움직임만으로 구분하지 않는 방향을 제안한다.
- **미확인:** SwiftUI/AppKit용 네이티브 컴포넌트나 SVG 애니메이션의 직접 호환성은 확인하지 않았다. 웹 검색 도구의 페이지 접근 실패 후 공개 HTML을 직접 읽었으며, 애니메이션을 실행·평가하지 않았다.

### Taste Skill

- **확인:** 아트 디렉션 선택, 실제 제품 화면 참고, 브라우저 검사와 스크린샷 개선 반복을 제공하는 웹 중심 스킬이다. 앱 화면에도 별도 경로가 있으며 차분한 패널, 숫자 정렬, 데이터에 집중한 색 사용을 설명한다. [공식 README](https://github.com/Leonxlnx/taste-skill#how-v2-works)
- **확인:** 현재 README의 스크립트 요구사항은 Node 22+와 설치된 Chrome·Edge·Chromium이다. [요구사항](https://github.com/Leonxlnx/taste-skill#install)
- **제안:** ‘현재 화면 관찰 → 방향 하나 선택 → 주요 문제 세 개 수정 → 재비교’라는 평가 절차를 참고한다. 이 조사에서는 스킬을 설치하거나 실행하지 않았다.
- **미확인:** 브라우저 기반 검사 결과를 네이티브 창의 품질 보증으로 사용할 근거는 없다. FileToX에서는 실제 macOS 창·키보드·접근성 검증이 별도로 필요하다.

### Impeccable

- **확인:** `critique`, `audit`, `clarify`, `distill`, `polish`, `harden` 등 목적별 검토·개선 용어를 제공한다. [공식 명령 설명](https://impeccable.style/docs/)
- **확인:** 기존 디자인 개선 가이드는 문제와 유지할 조건을 먼저 명시하고, 집중 수정 후 주 작업과 좁은 화면을 확인하도록 안내한다. [공식 개선 절차](https://impeccable.style/docs/improve-design/)
- **확인:** 자동 훅은 웹 코드용이며 기본 확장자에 `.swift`가 없다. 공식 문서는 네이티브 인터페이스에 `audit`를 사용하도록 안내한다. [자동 검사 범위](https://impeccable.style/docs/hooks/)
- **제안:** FileToX에는 문구 명확성, 시각적 경쟁 감소, 정렬, 긴 파일명, 실패 후 복구를 살피는 수동 평가 기준으로 활용한다. SwiftUI 자동 검증 도구로 간주하지 않는다.

## REA: macOS 네이티브 분석 공급자와 요구사항

- **공통 확인:** REA는 로컬 MCP 또는 CLI를 통해 동작하며 현재 README 요구사항은 Node.js 22.x ≥22.19, 24.x ≥24.11 또는 26+와 npm이다. 네이티브 분석은 공급자별 추가 도구가 필요하다. 분석은 로컬에서 하지만 결과를 받은 모델 제공자의 데이터 정책까지 로컬이라는 뜻은 아니다. [README](https://github.com/morluto/rea#what-you-can-analyze), [FAQ](https://github.com/morluto/rea#faq)
- **설정 확인:** setup은 MCP 등록·워크플로 지침 설치 등 설정을 변경한다. 스킬만 설치하면 분석 엔진이나 MCP 연결이 생기지 않는다. 이번 작업에서는 실행하지 않았다. [설치 가이드](https://github.com/morluto/rea/blob/main/docs/installation.md#skill-only-installation)

### Hopper

- **확인:** macOS용 네이티브 분석 경로다. 별도 상용 도구이며 데모도 공급자 제한을 따른다. REA 자동 설치 경로는 macOS 12+이고, 기존 설치도 사용할 수 있다. 최초 데모·라이선스 선택이 필요할 수 있다. Apple Events가 거부되면 실행 주체의 Automation 권한이 관련된다. [Hopper 설치·실행 조건](https://github.com/morluto/rea/blob/main/docs/installation.md#hopper)
- **한계:** REA가 Hopper를 시작하고 분석 문서를 생성할 수 있다. 이는 대상 Tangerine 앱 실행과 구분되지만 ‘아무 앱도 실행하지 않는’ 현재 조사 범위에는 포함하지 않는다. 공급자 호출은 문서·캐시·임시 자원 효과가 있을 수 있다. [실행·종료 설명](https://github.com/morluto/rea/blob/main/docs/installation.md#launcher-paths-and-troubleshooting)

### Ghidra

- **확인:** macOS x64/arm64를 지원한다. 문서상 Ghidra 12.1.x, 설치본이 선언한 범위의 64비트 full JDK, 호스트와 맞는 네이티브 decompiler가 필요하다. 검증 조합은 12.1.4 + JDK 21이며 현재 12.1은 JDK 21 이상이다. [설치 요구사항](https://github.com/morluto/rea/blob/main/docs/installation.md#ghidra)
- **확인:** headless 임시 프로젝트를 사용하고 GUI 제어 권한은 없다. REA가 Ghidra·JDK를 설치하거나 Gatekeeper 설정을 바꾸지 않는다. Apple Silicon에서는 JDK·decompiler 아키텍처 일치도 확인해야 한다. [공급자 의미](https://github.com/morluto/rea/blob/main/docs/ghidra-provider.md), [arm64 안내](https://github.com/morluto/rea/blob/main/docs/installation.md#macos-arm64-native-decompiler)

### IDA와 Kuna

- **확인 — IDA:** 기존 IDA와 호환되는 upstream MCP 등록이 필요하다. 공식 가이드에는 macOS arm64 + IDA Professional 9.1 + 특정 upstream 커밋의 headless Mach-O fixture 검증이 기록돼 있다. 모든 IDA 버전·GUI 프로필의 macOS 지원을 보장하지 않으며 native MCP 플러그인의 macOS 실검증도 해당 기록에 포함되지 않는다. [IDA 가이드](https://github.com/morluto/rea/blob/main/docs/ida-provider.md)
- **확인 — Kuna:** 사용자가 제공한 실행 파일을 쓰는 정적 공급자이며 macOS 캐시 경로가 문서화돼 있다. 검증 버전은 1.833이고 대상은 ELF·thin Mach-O의 x86-64/AArch64/ARM이다. universal Mach-O는 거부하며 타입 복원·일부 참조·CFG 등은 제공하지 않는다. [Kuna 가이드](https://github.com/morluto/rea/blob/main/docs/kuna-provider.md)
- **추가 경로:** GNU objdump·Rizin의 오프라인 통합도 있지만 설치된 도구·빌드에 따른 형식 지원을 확인해야 한다. 이를 네이티브 UI 분석 공급자로 간주하지 않는다. REA의 GDB 및 지속 Rizin 디버깅은 Linux 한정이다. [공식 통합 가이드](https://github.com/morluto/rea/blob/main/docs/reverse-engineering-tools.md)

## 근거의 한계와 현재 상태

- **전달받은 환경 점검:** 부모 작업에서 REA MCP 도구·`rea` 실행 파일과 표준 `/Applications`의 Tangerine·Hopper·Ghidra 앱을 발견하지 못했다. 이 조사에서 재검사하지 않았으며 다른 경로나 IDA·Kuna의 설치 여부까지 부재로 단정하지 않는다.
- **릴리스 한계:** 위 기능은 저장소 `main` 기준이다. npm 배포본·고정된 MCP 등록·실제 연결 도구 목록은 다를 수 있다. 설치 문서 자체도 이 차이를 명시한다. 현재 배포 버전은 이번에 조회하지 않았다. [main과 배포본 경계](https://github.com/morluto/rea/blob/main/docs/installation.md#released-package-and-main)
- **정적 근거:** 의사코드는 원본 Swift 소스가 아니다. 문자열·심볼·정적 호출 관계가 없다고 실행 경로가 없음을 증명하지 못하며, 미해결 간접 호출·지원하지 않는 메타데이터는 미확인으로 남는다. [네이티브 조사 경계](https://github.com/morluto/rea/blob/main/docs/native-investigation.md#provider-and-verification-boundaries), [문자열 검색 한계](https://github.com/morluto/rea/blob/main/docs/ghidra-provider.md#admitted-inventory-semantics)
- **인벤토리 한계:** Apple bundle 인벤토리는 경로·해시·구성 및 런타임 계열의 힌트를 제공한다. 프레임워크 경로나 파일명만으로 SwiftUI 사용, 실제 로딩, 호출, 화면 배치를 확정하지 않는다. [Apple 분석](https://github.com/morluto/rea/blob/main/docs/apple-application-analysis.md)
- **UI 관찰은 별도:** `observe_native_ui`는 이미 실행 중인 명시적 PID/창을 선택하며 macOS 14+의 ScreenCaptureKit, Screen Recording·Accessibility 권한이 관련된다. 시나리오 액션은 앱 데이터·네트워크에 영향을 줄 수 있고 상태를 복원하지 않는다. [네이티브 데스크톱 관찰](https://github.com/morluto/rea/blob/main/docs/native-investigation.md#native-desktop-observation)
- **동적 호출은 별도:** `observe_native_calls`는 LLDB 아래에서 대상 프로세스를 새로 실행한다. 현재의 실행 금지 범위에서는 사용하지 않는다. [네이티브 호출 관찰](https://github.com/morluto/rea/blob/main/docs/native-investigation.md#native-call-observation)

## 작고 제한된 후속 조사안 — 아직 수행하지 않은 제안

1. **화면 근거부터:** 기존에 제공된 Tangerine 화면·설명과 FileToX 화면으로 핵심 작업 하나를 비교한다. 자료가 없으면 Tangerine에 관한 주장은 보류하고 FileToX 자체 평가만 진행한다.
2. **질문은 최대 세 개:** 아래 후보에서 답이 실제 설계 결정을 바꾸는 질문만 선택한다. 한 차례 30분, 관찰할 상태 최대 세 개, 개선 후보 최대 세 개로 제한한다.
3. **REA 도입이 별도 범위로 정해질 때:** 정확한 대상·버전·아키텍처·허용된 배포본과 공급자 설치 위치를 확인한다. 준비된 CLI의 scoped doctor와 실제 MCP 도구 목록으로 실행 가능성을 확인한다. 설정·설치·권한 변경을 이 문서만으로 수행하지 않는다.
4. **정적 탐색 우선:** 준비가 갖춰진 후에도 bundle 인벤토리·메타데이터로 답할 수 있는지 먼저 본다. 공식 desktop 검사 도구는 엔진 없이 제한된 디렉터리·헤더 검사만 하고 대상 앱을 실행하지 않는다. [범위](https://github.com/morluto/rea/blob/main/docs/desktop-applications.md)
5. **깊은 분석은 질문 하나만:** 필요성이 남을 때 선택한 공급자로 관련 함수·문자열·참조만 확인하고 대상 해시, 아키텍처, 도구 버전, 근거 위치, 관찰·추론·미확인을 함께 보존한다. UI 관찰·LLDB 실행은 이 정적 계획과 별도다.
6. **종료 기준:** 질문에 답하거나 근거 부족·시간 제한에 도달하면 중단한다. 전체 복원과 코드·자산 복사는 하지 않고, FileToX의 독립적인 행동 명세로 정리한다.

### 조사 질문 후보

- 빈 화면에서 파일 추가와 지원 형식을 알아내는 데 필요한 정보가 무엇인가?
- 파일별 진행·실패·재시도와 전체 작업의 주 행동을 어떻게 구분하면 혼동이 줄어드는가?
- 출력 형식·저장 위치·완료 후 파일 찾기를 어느 단계에 보여주는 것이 좋은가?

이 질문들은 UI 관찰로 먼저 검토할 항목이다. 실제 관찰 후에도 내부 처리에 대한 질문이 남을 때만 REA 정적 근거가 필요한지 판단한다. 현재 Tangerine의 답이나 우수성을 확인한 결과는 없다.
