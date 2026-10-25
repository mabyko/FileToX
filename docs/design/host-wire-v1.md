# 구현 공통 프로토콜 v1

모든 메시지는 UTF-8 NDJSON, 최대 4 MiB. 요청 `{v:1,id:String,method:String,params:Object}`, 응답 `{v:1,id,result}` 또는 `{v:1,id,error:{code,message}}`, 이벤트 `{v:1,event,data}`. enum은 camelCase 문자열, 날짜는 ISO8601. 이 문서는 병렬 구현에서 사용하는 필드 계약이다.

앱은 helper 실행 시 `--chunked-output`을 전달한다. 이 옵션을 받은 helper는 4 MiB보다 큰 응답·이벤트를
`{v:1,chunk:{id:UUID,offset:Int,total:Int,bytes:Base64}}` 전송 프레임으로 나눈다. 각 프레임은 기존 줄 제한을
지키며 원본 JSON의 최대 2 MiB를 담는다. `offset`은 재조립한 바이트 수와 같아야 하며, 같은 `id`와 `total`의
프레임이 끊김 없이 순서대로 온다. 재조립 뒤에는 위와 같은 v1 메시지를 처리하므로 파일 목록·이력을 생략하지 않는다.
메시지 전체와 writer 대기 큐는 각각 64 MiB로 제한한다. 전체 제한을 넘는 응답은 오류, 완료 이벤트는 기존 fatal
경로로 처리한다. 이 옵션이 없는 클라이언트에는 기존 v1 메시지만 보내며, 요청 줄 제한은 그대로 4 MiB다.

- `hello`: `{protocol:1,hostVersion,fileeCommit,rid,dataDir}`.
- `catalog.get` → `{formats:[{id,displayName,category,extensions,writable,isVirtual}],engines:[{id,displayName,available,reasonKey?,detail?,version?}]}`.
- `selection.resolve {paths:[String]}` → `{profileId:String?,formats:[String],unknown:[String],rejected:[{path,reason}],slices:[Slice],tools:[Slice],presetOptions:[Slice],targets:[Target]}`. 일치하는 툴바 프로필이 없으면 `profileId=null`, `slices=[]`이며 전체 출력 형식은 그대로 반환한다.
- `tools`는 입력 종류와 옵션에 맞는 도구 프리셋(최대 12개), `presetOptions`는 모든 저장된 프리셋의 실행 가능 여부다. 기존 `slices`는 파일 종류별 사용자 프로필 순서를 유지한다. Swift는 두 새 배열이 없는 이전 응답도 읽을 수 있다. 클립보드·Finder 작업은 host 프리셋이 아니며 Swift에서 수행한다.
- Slice = `{presetId,displayName,targetFormat,available,reasonKey?,reasonText?,runnableCount,needsPackage?,canDownload:Bool,guidanceKey?}`.
- Target = `{formatId,available,reasonKey?,reasonText?,runnableCount}`. 전체 writable 형식과 folder·*에 대해 host의 planner와 옵션으로 판단한다.
- `job.start {paths:[String],presetId?:String,targetFormat?:String,preset?:Object}` → `{jobId}`. 셋 중 하나만 허용. targetFormat은 기본 옵션으로 프리셋을 만들며 이름 충돌 정책은 Rename을 기본으로 한다. presetId는 저장된 라이브러리의 프리셋이다.
- `job.cancel {jobId}` → `{}`.
- `watch.status {}` → `{rules:[{id,state,detail?}]}`. 상태는 `disabled`, `starting`, `watching`, `running`, `error`, `stopped`이며 메모리에 캐시한 값을 반환한다. `error`는 이전 변환·원본 이동 오류를 표시할 수도 있고, 그 자체로 다른 작업 취소를 뜻하지 않는다.
- `watch.stop {}` → `{}`. 현재 helper 세션의 새 감시 작업을 막고 감시 작업을 취소한다. 저장한 규칙을 끄지 않으며 helper를 다시 시작하면 저장한 설정을 따른다. 앱 종료 시 전체 작업 취소·stdin 종료보다 먼저 호출한다.
- `job.updated` / `job.finished` data = `{jobId,state,progress,presetName,files:[File],historyEntry?:History,retrySources?:[String],preset?:Object}`.
- File = `{source,state,progress,outputs?:[{path,isDirectory}],errorKey?,errorDetail?}`. Outputs는 finished에만 포함한다.
- `history.get` → `{entries:[History]}`. `history.clear` → `{}`.
- History = `HistoryEntry` 전체 camelCase JSON. `finishedAt` ISO8601, outputs는 [String], preset은 null 또는 당시 Preset. job 수준 실패에는 전체 Sources+Preset을 남긴다.
- `library.get` → `{revision:Int,settings:Object,presets:[Object],profiles:[Object]}`.
- `library.save {baseRevision:Int,presets:[Object],profiles:[Object]}` / `settings.save {baseRevision:Int,settings:Object}` → Library. 받은 JSON의 전체 필드를 보존한다.

Swift 인터페이스(EngineHost actor): start()→HostHello, catalog()→HostCatalog, resolve(paths:[String])→HostSelection, startJob(paths:[String],presetId:String?=nil,targetFormat:String?=nil,preset:JSONValue?=nil)→String, cancel(jobId:String), events()→AsyncStream<HostEvent>, history()→[HostHistory], library()→HostLibrary, saveLibrary(baseRevision:presets:profiles:)→HostLibrary, saveSettings(baseRevision:settings:)→HostLibrary, clearHistory(), shutdown(). 모두 async throws (events는 async, shutdown은 async). actor init(executableURL:URL?=nil,dataDirectory:URL?=nil).

추가 클라이언트 메서드는 `watchStatus() async throws → [JSONValue]`, `stopWatching() async throws`다. 감시 작업은 기존 job 이벤트와 이력을 사용하며 이력의 `watchRuleId`로 규칙을 식별한다. 프로토콜 버전과 설정 schema 8은 유지한다.

HostEvent = .hello(HostHello), .updated(HostJob), .finished(HostJob), .fatal(String), .interrupted(String). Models의 필드명은 위 JSON과 같다. HostLibrary 설정·프리셋·프로필은 JSONValue, HostHistory.preset은 JSONValue?. JSONValue는 Foundation 값의 전체 JSON을 보존하는 Codable/Sendable enum이다. 외부 변환 실패는 file/job 상태로 전달하며 host crash는 pending 요청 실패·interrupted 이벤트다.

구현 경계: `Sources/Core/Host`는 Swift 앱의 클라이언트·wire 모델, `Sources/Engine/Host`와 `Sources/EngineMain`은 Swift helper의 요청·이벤트 처리를 담당한다. 앱 화면·macOS 연동은 `Sources/App`·`Sources/UI`·`Sources/Platform`, 빌드·패키징은 `Tools`·`Config`·`project.yml`에서 관리한다. 전환 전 C# helper는 현재 빌드 입력이 아니다.
