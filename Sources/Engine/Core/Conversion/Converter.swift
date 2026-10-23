// Port of Filee.Core/Conversion/IConverter.cs (Filee 21fdd05): the contract every conversion engine implements.
//
// Cancellation uses Swift task cancellation (Filee's CancellationToken): engines call `try Task.checkCancellation()`
// between units of work, throw `CancellationError` to stop, and `ProcessRunner` kills external tools when the task is
// cancelled. Any other error fails the file with `error.conversion_failed` and the error's description as detail.

import Foundation

/// One direct conversion a converter can perform, e.g. docx → pdf. `cost` is relative (10 = normal direct
/// conversion; higher for lossy or slow paths); multi-step routes add up their costs.
public struct ConversionEdge: Hashable, Sendable {
    public var from: String
    public var to: String
    public var cost: Int

    public init(_ from: String, _ to: String, _ cost: Int = 10) {
        self.from = from
        self.to = to
        self.cost = cost
    }
}

/// Whether an engine can currently be used.
public struct EngineStatus: Equatable, Sendable {
    public var isAvailable: Bool
    /// Localization key explaining why the engine is unavailable (e.g. `engine.reason.not_installed`).
    public var reasonKey: String?
    /// Extra, non-localized detail such as the program's path.
    public var detail: String?
    /// Version label shown in Settings → Engines.
    public var version: String?

    public init(isAvailable: Bool, reasonKey: String? = nil, detail: String? = nil, version: String? = nil) {
        self.isAvailable = isAvailable
        self.reasonKey = reasonKey
        self.detail = detail
        self.version = version
    }

    public static func available(detail: String? = nil, version: String? = nil) -> EngineStatus {
        EngineStatus(isAvailable: true, detail: detail, version: version)
    }

    public static func unavailable(_ reasonKey: String, detail: String? = nil) -> EngineStatus {
        EngineStatus(isAvailable: false, reasonKey: reasonKey, detail: detail)
    }
}

/// Hands out output paths to a converter. Thread-safe.
public protocol OutputAllocator: AnyObject {
    /// The path the converter should write its next output to, or nil when this output must be skipped
    /// (existing file + "skip" policy). An empty `extension` asks for a folder path (the converter creates it).
    /// `suffix` such as "_p2" is used when one input produces several files.
    func allocate(_ extension: String, suffix: String?) throws -> String?
}

public extension OutputAllocator {
    func allocate(_ extension: String) throws -> String? { try allocate(`extension`, suffix: nil) }
}

/// Everything a converter needs to perform one step.
public struct ConversionStep {
    /// File to read. Never modified.
    public let inputPath: String
    /// Format id of `inputPath`.
    public let from: String
    /// Format id to produce.
    public let to: String
    /// Options chosen by the user.
    public let preset: Preset
    /// Where to write results.
    public let output: OutputAllocator
    /// Private scratch directory for this job; deleted afterwards.
    public let workDirectory: String

    public init(inputPath: String, from: String, to: String, preset: Preset, output: OutputAllocator, workDirectory: String) {
        self.inputPath = inputPath
        self.from = from
        self.to = to
        self.preset = preset
        self.output = output
        self.workDirectory = workDirectory
    }
}

/// Progress 0…1 of one conversion step. Reports may arrive from any thread; the queue only moves progress forward.
public typealias ProgressHandler = @Sendable (Double) -> Void

/// A conversion engine. Implementations must be safe for `maxParallelism` concurrent calls, honour task cancellation
/// and never modify the input file.
public protocol Converter: AnyObject {
    /// Stable id used in settings (engine priority, custom paths). Lower-case, no spaces. Same ids as Filee.
    var id: String { get }
    /// Human readable engine name (not localized).
    var displayName: String { get }
    /// Direct conversions this engine supports.
    var edges: [ConversionEdge] { get }
    /// How many conversions may run at the same time. 0 means one per CPU core.
    var maxParallelism: Int { get }
    /// Whether the engine is installed / usable. Should be cheap; the catalog caches it.
    func status() -> EngineStatus
    /// Performs one conversion step and returns the files (or folders) that were written.
    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String]
}

/// Merges several PDF files into one. Implemented by the PDF engine.
public protocol PdfMerger: AnyObject {
    func merge(_ inputPaths: [String], into outputPath: String) async throws
}

/// Writes TIFF pages (and every page of multi-page TIFFs) into one multi-page TIFF, in order.
public protocol TiffMerger: AnyObject {
    func merge(_ inputPaths: [String], into outputPath: String, options: ImageOptions) async throws
}

/// Packs several files, unchanged, into one archive ("Compress into one archive"). Implemented by the archive engine.
public protocol FileCombiner: AnyObject {
    /// True if files can be packed into `format` now (e.g. the tool it needs is installed).
    func canCombine(into format: String) -> Bool
    /// Writes every input (stored under its own name, "name (2)" on clashes) into one archive of `format` at
    /// `outputPath`, written only when complete.
    func combine(_ inputPaths: [String], into outputPath: String, format: String, preset: Preset,
                 workDirectory: String, progress: ProgressHandler?) async throws
}

/// An error whose message is shown to the user as the failure detail (Filee shows `Exception.Message`).
public struct ConversionError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}
