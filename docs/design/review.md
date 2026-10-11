# 설계·importer 검토 기록과 구현 검토

아래의 설계 검토는 host 구현 전 기록이다. 구현 후 검토와 실제 검사 결과는 마지막 절에 추가했다.

검토일 2026-10-11. 기준은 `.reference/Filee` 커밋 `21fdd05`(HEAD 일치)와 `Vendor/Filee`(고정 스냅샷)다. 대상은 `docs/design/{engine-host,macos-packaging,swiftui-port}.md`, `Tools/*.py`, `Tests/Tools`다. 이 파일만 고쳤다.

실행한 검사: `import-filee-formats.py --check` 통과(172 = 171 + 1, 14 분류, 257 확장자, 58 읽기 전용), `--selftest` 통과, `verify-filee-vendor.py` "Verified 236 pinned Filee source files". Xcode·Swift 테스트와 .NET 빌드는 실행하지 않았다(지시에 따름).

## 결론

설계 결함으로 남은 **차단 항목은 없다.** 비차단 문장 2건도 최종 정리에서 수정했다. 호스트·엔진은 아직 구현되지 않았고, 이 검토는 변환이 실제로 동작한다는 증거가 아니다.

## 1차 지적의 처리 결과

| # | 지적 | 상태 | 근거(실제 파일·소스) |
| --- | --- | --- | --- |
| 1 | 합치기·묶기가 알 수 없는 입력에서 막힘 | 해결 | engine-host §5 `unknown[]`, §6 "거부하지 않고 `unknown[]`", §8 압축 행, G3 "ZIP 묶기(unknown·폴더)". `JobQueue.RunCombinedAsync`는 형식 검사 없이 존재만 확인하고, 일반 변환은 `error.unsupported_source`(소스 311–313행). swiftui-port도 같은 문구 |
| 2 | 병합 취소·실패의 이력·재시도 | 해결 | engine-host §8: `HistoryEntry.From`은 `FileState.Failed`만 Failures에 담고 `failures.Count > 0`일 때만 Preset을 복제한다(소스 37·50행). 파일 실패가 없는 `failed`·`cancelled`는 원래 입력 전체 + 프리셋으로 재시도, `KeepHistory=false`여도 메모리 최대 200개. 병합기 예외는 바깥 `catch`가 `Failed`로 만든다(`JobQueue.cs` 90–94행)는 서술과 `RunCombinedAsync`의 자체 취소 처리(251행)도 소스와 일치. `ConversionJob.State`는 건드리지 않고 DTO·이력 항목만 보정 |
| 3 | 문서 간 충돌 | 해결 | 제품 macOS 15 / 프로토타입 14 구분이 README 44·72행, architecture 3·94행, engine-host §1, packaging 서두에서 일치(`project.yml`은 아직 14, "host 통합 때 맞춘다"고 명시). helper 후보 경로 `Helpers/FileToXEngine.app/Contents/MacOS`, `core/engines/tmp` 경로, `Vendor/Filee`가 두 문서에서 같다 |
| 3 | PATH 거짓 근거 | 해결 | engine-host §4 "PATH는 바꾸지 않는다". `EngineEnvironment.SystemFolders`가 비-Windows에서 `/opt/homebrew/bin` 등을 항상 덧붙임을 소스로 재확인 |
| 3 | i18n 누락 | 해결 | `Vendor/Filee/src/Filee.App/Assets/i18n/{en,ko,zh-CN}.json`이 실제로 있고 manifest `importedPaths`에 포함 |
| 3 | TCC 미검증 | 해결(게이트로 분리) | packaging 완료 조건 7, G6. "아직 검증하지 않았다"고 명시 |
| 4 | importer 대체 ref 우회 | 해결 | `load_sources`가 모든 git 호출에 `--no-replace-objects`와 `encoding="utf-8"`을 쓰고, `git hash-object --no-filters` ≟ pinned blob id로 비교한다(224–232행). 회귀 테스트(`Tests/Tools/test_import_filee_formats.py` 44행)가 `git replace` 후 실패를 확인한다. `main()`은 `UnicodeError`도 잡는다. 상위 저장소·blob 메타데이터 추가는 root가 불필요하다고 판단했고, 고정 커밋·blob 검사가 어느 clone에서나 성립하므로 수용 |
| 5 | 도넛 비동기 흐름 | 해결 | swiftui-port 1–2단계: 파일 없는 드래그는 숨김, 같은 목록 1회 resolve, 최신 응답만 반영, 응답 전 드롭 `.none`, 섹터 수·순서 고정과 늦은 갱신은 활성·사유만 변경, 250 ms 유예, 드롭 목록 불일치 시 재resolve, `job.start` 재검증 |
| 5 | 설치 불가 패키지 안내 | 해결 | engine-host §5 `canDownload`·`guidanceKey`, §9, G3 `mp4→mp3` |
| 보강 | Preset 왕복 손실 | 해결 | swiftui-port·engine-host §10: 원본 JSON 전체 초안(null·배열 순서 보존), host가 버전·필드를 엄격 검증. G7에 Dpi=null·Renames·IcoSizes·미지 키 |
| 보강 | ReduceMotion·DonutSettings 매핑 | 해결 | swiftui-port 접근성 절 |
| 보강 | 출력 확정·이벤트 순서 | 해결 | engine-host §6 경로별 확정·부분 결과·배타적 rename 미지원 시 실패(폴더), 파일은 `link`+`unlink`(배타성 유지). §7 `gate` 안 enqueue→응답→이벤트 순서는 소스(`Enqueue`가 채널 기록 후 `JobUpdated`, 49–55행)와 맞는다. `MaxHistory=200`은 `UserDataStore.cs` 19행과 일치 |

## 최종 정리에서 수정한 문장

root가 다음 두 항목을 반영했다(2026-10-11).

1. packaging의 문구를 “`--deep`로 일괄 서명하지 않으며”로 수정했다. 개별 내부 코드 → helper → 앱의 서명 순서와 일치한다.
2. engine-host §5에 host 전용 JSON `ILocalizer`, en·ko·zh-CN 입력, G1 이전 fallback·파일명 토큰 검증을 명시했다.

## 런타임 검증 게이트 (설계 결함 아님, 아직 미실행)

| 게이트 | 확인할 것 |
| --- | --- |
| G0·G1 | .NET SDK 고정·빌드·패치 `git apply --check`, 프로토콜·fd 분리·ack 전 이벤트 금지 1,000회 테스트 |
| G2·G4 | 데이터 분리, 출력 확정 패치 테스트, NFD·심볼릭 링크, exFAT·SMB의 `RENAME_EXCL` 지원 |
| G3·G5 | 형식별 실제 변환(엔진·native 로딩), 취소 중 하위 프로세스 정리 |
| G6 | 두 RID publish, 서명·공증·Gatekeeper, **TCC 귀속 주체**, macOS 15 이상 실행, macOS 14는 참고 결과 |
| G7 | Swift Codable·원본 JSON 왕복, Finder 드래그·다중 모니터·VoiceOver |

위 항목은 모두 구현 후 실행으로만 확인된다. 현재 문서는 어떤 형식의 런타임 동작도 보장하지 않으며, 이 검토도 그렇다.

## 구현 후 Claude 검토

Claude Opus 5.5가 실제 C# host와 출력 staging 패치를 구현했고, Claude Sonnet 5.5가 구현을 검토하며 Pandoc 첨부 이미지가 staging 밖에 쓰이던 문제를 고쳤다. `0002`는 Pandoc의 작업 디렉터리와 `--extract-media`를 staging으로 옮기고 상대 링크를 유지한다. 첨부 이미지 폴더 충돌은 본문 게시 전에 검사한다. 기존 디렉터리의 다른 파일은 보존하고 입력은 symlink·Unicode 경로 별칭에서도 보호한다.

실제 Pandoc 회귀 테스트는 이전 코드에서 실패하고 수정 후 통과했다. .NET Core는 baseline 154 통과에서 패치 후 164 통과로 늘었고 실패는 없다. Engines의 기존 FFmpeg 인코더 실패 3개는 패치 전후 같다. helper 자체 검사는 50개다. macOS에서 빈 외부 엔진 경로를 지울 때 저장이 거부되던 문제와, 엔진 상태 갱신이 host lock을 오래 잡던 문제도 수정했다.

Swift client·전체 JSON 초안·nullable selection을 대조했다. 초안의 기준 revision이 다른 편집 때문에 바뀌면 저장을 `conflict`로 거부하며, 덮어쓰지 않는다. RPC와 취소 응답의 30초 유예, 여러 결과 게시 중 강제 종료의 한계는 [구현 현황](../../EngineHost/IMPLEMENTATION.md)에 기록한다. 여러 출력과 본문·첨부 이미지 사이의 게시 전체는 원자적이지 않다.

실행 명령·최종 앱 검증·미검증 항목은 [README](../../README.md)를 기준으로 한다.
