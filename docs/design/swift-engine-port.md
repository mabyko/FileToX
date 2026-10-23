# Swift 엔진 이식 규칙

C# 변환 helper(`EngineHost` + Filee `Core`·`Engines`)를 Swift helper로 옮길 때 지키는 규칙이다. 전환 계획과 기능별 대체 방법은 [swift-engine-migration.md](swift-engine-migration.md)에 있다.

## 원칙

- **프로토콜은 그대로 둔다.** Swift helper는 [host-wire-v1](host-wire-v1.md)을 같은 필드·순서·오류 코드로 구현한다. 앱(`Sources/Core/Host`)은 helper가 바뀐 것을 몰라야 한다.
- **동작 기준은 패치 적용된 Filee다.** `Vendor/Filee`(커밋 `21fdd05`)에 `Vendor/Filee.patches/*.patch`를 적용한 소스가 기준이다. 읽기 전용 사본: `/tmp/ftx-ref/filee-patched` (없으면 `Vendor/Filee`를 복사하고 패치를 `git apply`한다). host 동작은 `EngineHost/*.cs`가 기준이다.
- **결과·옵션·진행률·취소·오류를 바꾸지 않는다.** 엔진 id, 변환 간선(edge)과 비용, 상태 사유 키(`engine.reason.*`), 출력 파일 이름(`Allocate` 확장자·접미사), 진행률 보고 시점, 취소 확인 지점, 사용자에게 보이는 오류 문구를 Filee와 같게 둔다. NuGet 라이브러리를 macOS 프레임워크나 Swift 코드로 바꾼 곳만 구현이 달라진다.
- **동등하게 대체할 수 없는 부분은 임의로 빼지 않는다.** 구현할 수 없거나 품질이 확실히 달라지는 부분은 코드에서 지우거나 숨기지 말고, 보고서에 무엇이·왜·어떤 대안이 있는지 적는다.
- **외부 실행 파일은 그대로 쓴다.** rhwp·7-Zip(번들), FFmpeg·Ghostscript·Pandoc·LibreOffice·Calibre(사용자 설치)는 같은 인자로 실행한다. 새 외부 프로그램을 추가하지 않는다.

## 위치와 이름

| 대상 | 위치 |
| --- | --- |
| 계약·코어(형식·프리셋·변환기·작업 큐·저장소) | `Sources/Engine/Core/` |
| host 프로토콜·실행 진입점 | `Sources/Engine/Host/`, `Sources/EngineMain/main.swift` |
| 공용 도구(ZIP·XML·인코딩·바이너리·이미지 정보·경로) | `Sources/Engine/Support/` |
| 외부 프로그램 실행·엔진 위치·버전 | `Sources/Engine/Infrastructure/` |
| 엔진 | `Sources/Engine/Engines/<Group>/` |
| 리소스(i18n, engines.json, 템플릿) | `Sources/Engine/Resources/` (`ResourceBundle`로 읽는다) |
| 테스트 | `Tests/Engine/<Group>/` (XCTest) |

- 모든 엔진이 한 Swift 모듈(`FileToXEngineKit`)에 있다. C# 네임스페이스가 없으므로 **최상위 타입 이름은 모듈 전체에서 유일해야 한다.** 새 최상위 타입을 만들기 전에 `grep -rn "class X\b\|struct X\b\|enum X\b" Sources/Engine`으로 확인한다. `Entry`, `Section`, `Part`, `Reader`, `Writer`, `Crc32`, `BigEndian`처럼 흔한 이름은 소유 타입 안에 중첩하거나 그룹 접두어를 붙인다.
- 표준 타입(`Data`, `String`, `Array`) 확장은 `fileprivate`으로 둔다. 모듈 전체에 공개해야 하면 그룹 접두어를 붙인다.
- Filee 타입 이름은 그대로(UpperCamel), 멤버는 lowerCamel로 옮긴다. 접근 수준은 기본 `internal`이다.
- 엔진 표시 이름(`displayName`)은 설정 화면에 그대로 보인다. 더 이상 쓰지 않는 라이브러리 이름("ImageMagick", "PDFium" 등)을 쓰지 않는다. 엔진 id는 바꾸지 않는다(설정의 엔진 우선순위·사용자 지정 경로 키).

## C# → Swift 대응

| C# | Swift |
| --- | --- |
| `IConverter.ConvertAsync(step, progress, ct)` | `func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String]` |
| `ct.ThrowIfCancellationRequested()`, `OperationCanceledException` | `try Task.checkCancellation()`, `CancellationError`. 오래 걸리는 반복문은 주기적으로 확인한다. |
| `progress?.Report(x)` | `progress?(x)` |
| `using (ProgressEstimate.Start(...))` | `let estimate = ProgressEstimate.start(progress, typical: 초, from:, to:)` + `defer { estimate.stop() }` |
| `ProcessRunner.RunAsync(...)` | `try await ProcessRunner.run(exe, args, timeout: 초, workingDirectory:, environment:, onOutput:)`. `status()`처럼 동기 문맥은 `ProcessRunner.runBlocking` |
| 예외 메시지 | `throw ConversionError("Filee와 같은 영어 문구")` — 파일 실패의 `errorDetail`이 된다 |
| `step.Output.Allocate(ext, suffix)` | `try step.output.allocate(ext, suffix: suffix)` (nil이면 건너뛴다) |
| `Path.*`, `File.Exists`, `Directory.*` | `FilePath.*`(.NET과 같은 규칙), `FileManager.default.fileExists(_:)`/`directoryExists(_:)`/`createDirectoryIfNeeded(_:)` |
| `ZipArchive`, `ZipFile` | `ZipReader`, `ZipWriter` (`CompressionLevel.Optimal` → `.optimal` 등) |
| `GZipStream`, `DeflateStream`, `ZLibStream` | `Deflate` (windowBits 31=gzip, 15=zlib, -15=raw) |
| Brotli, XZ | Apple `Compression` (`COMPRESSION_BROTLI`, `COMPRESSION_LZMA`) |
| `System.Xml.Linq` | `XDocument`·`XElement`·`XName`·`XNamespace` (`ns + "local"`), `element(_:)`, `elements(_:)`, `descendants(_:)`, `attributeValue(_:)`, `value`, `XElement(name, 내용...)`, `try doc.save(path, indent:)`. `LoadOptions.PreserveWhitespace` → `preserveWhitespace: true`, `SaveOptions.DisableFormatting` → `indent: false` |
| `Encoding.GetEncoding(949)` 등 | `TextEncodings.encoding(codePage:)` / `encoding(name:)`, `TextEncodings.decode(_:encoding:)` (.NET처럼 잘못된 바이트는 U+FFFD) |
| `DocumentReaders.DecodeText` | `TextEncodings.decodeText(_:)` |
| `BinaryPrimitives`, `BinaryReader`, `BinaryWriter` | 같은 이름의 `Support/Binary.swift` |
| `MagickImageInfo`, "PNG로 저장" | `ImageSupport.info(_:)`, `ImageSupport.pngData(_:)`, `ImageSupport.cgImage(_:)` (이미지 엔진의 `ImageEncoder`/`ImageReader`는 래스터 출력을 쓰는 엔진용) |

### 자주 생기는 차이

- **문자열 길이·색인:** C# `string.Length`와 인덱스는 UTF-16 코드 단위다. Swift `count`는 문자(grapheme) 수다. 파일 형식의 길이·오프셋·잘라내기처럼 UTF-16 기준이 필요한 곳은 `utf16` 보기를 쓴다.
- **사전 순서:** C# `Dictionary`는 실제로 삽입 순서를 유지하고, Filee 코드가 그 순서로 출력하는 곳이 있다. Swift `Dictionary`의 순회 순서는 실행마다 다르다. 출력 순서가 걸린 곳은 배열이나 별도 키 순서를 쓴다. 출력 바이트가 실행마다 달라지면 안 된다.
- **숫자 형식:** .NET `ToString(CultureInfo.InvariantCulture)`, `"0.##"`, `"R"`을 로케일에 영향받지 않는 형식으로 옮긴다. 시스템 로케일 기본값의 `NumberFormatter`·`String(format:)`(`%'`)을 쓰지 않는다.
- **대소문자 비교:** `OrdinalIgnoreCase`는 `caseInsensitiveCompare` 또는 `lowercased()` 비교로 옮긴다.
- **정렬:** LINQ `OrderBy`는 안정 정렬이다. Swift `sorted(by:)`도 안정 정렬이지만 비교 조건을 Filee와 같게 둔다.
- **정규식:** `NSRegularExpression`으로 같은 패턴을 쓴다. `RegexOptions.IgnoreCase` → `.caseInsensitive`.
- **임시 파일:** `step.workDirectory` 아래에만 만든다. 입력 파일은 절대 바꾸지 않는다.

## 이미지 공용 API (이미지 엔진 담당)

래스터 결과를 쓰는 엔진(PDF 렌더, SVG, CAD, Ghostscript, ICNS)은 Filee의 `ImageEncoder`·`ImageReader`와 같은 역할의 Swift API를 쓴다. 이미지 엔진 담당이 `Sources/Engine/Engines/Images/`에 다음 이름으로 제공한다.

```swift
struct ImageFrame { var image: CGImage; var delay: Double? /* 초, 애니메이션 */; var dpi: (x: Double, y: Double)?; var properties: [CFString: Any] }
enum ImageReader { static func read(_ path: String, format: String, preset: Preset) throws -> [ImageFrame] }
enum ImageEncoder {
    static var readable: [String]; static var writable: [String]; static var sources: [String]
    static func keepsAnimation(_ sourceFormat: String, _ targetFormat: String) -> Bool
    static func outputFormat(_ targetFormat: String, _ options: ImageOptions, sourcePath: String?) -> (format: String, extension: String)
    static func selectFrames(_ frames: [ImageFrame], sourceFormat: String, targetFormat: String) -> [ImageFrame]
    static func applyOptions(_ frame: ImageFrame, _ options: ImageOptions, targetFormat: String) throws -> ImageFrame
    static func write(_ frames: [ImageFrame], targetFormat: String, output: OutputAllocator, options: ImageOptions, sourcePath: String?) throws -> [String]
}
```

## 테스트와 검증

- 해당 엔진의 Filee 테스트(`tests/Filee.Engines.Tests/*`, 빌더 포함)를 XCTest로 옮겨 `Tests/Engine/<Group>/`에 둔다. 테스트 입력은 테스트 안에서 만들거나 `#filePath` 기준 경로의 작은 파일을 쓴다. `Package.swift`에 리소스를 추가하지 않는다.
- 외부 프로그램이 필요한 테스트는 프로그램이 없으면 `XCTSkip`으로 건너뛴다. 개발용 사본: `build/optional-engines/osx-arm64/{pandoc,libreoffice,calibre}`, 번들 엔진: 같은 저장소 `build/engines/osx-arm64/{rhwp,7zip}` (`FILETOX_BUNDLED_ENGINES`로 지정).
- `swift build --build-tests`와 `swift test --filter <그룹>`이 통과해야 한다.
- 결과 비교: `Tools/engine-compare/`(C# 기준선과 Swift helper를 같은 입력으로 실행해 비교)를 사용한다.

## 작업 방식

- `Sources/Engine/Core/`·`Support/`·`Infrastructure/`의 기존 파일은 담당자만 고친다. 필요한 보조 코드는 자기 그룹 폴더에 둔다. 공용 코드의 버그를 발견하면 최소한으로 고치고 보고서에 적는다.
- 변환기는 `Sources/Engine/EngineRegistry.swift`의 `createAll`에 Filee 순서대로 한 줄씩 추가한다.
- 자기 브랜치에 의미 단위로 커밋한다. 보고서에는 이식한 범위, Filee와 달라진 동작, 실행한 테스트 수와 결과, 이식하지 못한 부분과 이유, 다른 그룹이 쓰는 API를 적는다.
