import Foundation

public enum AfterConversion: String, CaseIterable, Sendable { case keep = "Keep", moveToOriginals = "MoveToOriginals" }
public struct WatchRule: Equatable, Sendable {
    public static let defaultOutputName = "converted", originalsName = "originals"
    public var id = String(Preset.newId().prefix(8))
    public var enabled = true
    public var folder = ""
    public var presetId = ""
    public var includeSubfolders = false
    public var outputFolder = ""
    public var originals = AfterConversion.keep
    public var include: [String] = []
    public var fileNamePattern = ""
    public var renames: [RenameStep] = []
    public init() {}
    public var resolvedOutputFolder: String { outputFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? FilePath.combine(folder, Self.defaultOutputName) : outputFolder }
    public var originalsFolder: String { FilePath.combine(folder, Self.originalsName) }
    public func apply(_ preset: Preset) -> Preset {
        var copy = preset
        copy.output.location = .customFolder; copy.output.customFolder = resolvedOutputFolder
        if !fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { copy.output.fileNamePattern = fileNamePattern.trimmingCharacters(in: .whitespacesAndNewlines) }
        copy.output.renames += renames.filter { !$0.isBlank }
        return copy
    }
}
