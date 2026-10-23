import Foundation

public enum ThemeMode: String, CaseIterable, Sendable { case system = "System", light = "Light", dark = "Dark" }
public struct ThemeSettings: Equatable, Sendable {
    public var mode = ThemeMode.system
    public var accent = "#7F77DD"
    public var cornerRadius = 16.0
    public var reduceMotion: Bool?
    public init() {}
}
public struct DonutSettings: Equatable, Sendable {
    public var outerRadius = 150.0
    public var holeRatio = 0.42
    public var opacity = 0.96
    public init() {}
}
public struct DefaultOutputSettings: Equatable, Sendable {
    public var location = OutputLocation.sameFolder
    public var subfolderName = "converted"
    public var customFolder = ""
    public init() {}
}
public struct AppSettings: Equatable, Sendable {
    public static let currentSchemaVersion = 8
    public var schemaVersion = 8
    public var language = "auto"
    public var startWithSystem = true
    public var contextMenuEnabled = true
    public var checkForUpdates = true
    public var keepHistory = true
    public var notifiedUpdateVersion: String?
    public var paused = false
    public var theme = ThemeSettings()
    public var donut = DonutSettings()
    public var triggers = TriggerGesture.defaults()
    public var excludedProcesses: [String] = []
    public var enginePriority = ["magick", "pdfium", "pdfsharp", "rhwp", "unhwp", "markdown", "spreadsheet", "ooxml", "hwpx-writer", "docx-writer", "pdf-text", "email", "vector", "icns", "font", "cad", "archive", "ebook", "ffmpeg", "pandoc", "ghostscript", "calibre", "libreoffice"]
    public var firstRunCompleted = false
    public var successfulConversions = 0
    public var feedbackPromptShown = false
    public var watchFolders: [WatchRule] = []
    public var defaultOutput = DefaultOutputSettings()
    public var engineOwnCopies: [String: String] = [:]
    public var keepFileDates = false
    public init() {}
    public func withDefaultOutput(_ preset: Preset) -> Preset {
        var copy = preset
        if copy.output.location == .default {
            copy.output.location = defaultOutput.location == .default ? .sameFolder : defaultOutput.location
            copy.output.subfolderName = defaultOutput.subfolderName
            copy.output.customFolder = defaultOutput.customFolder
        }
        if keepFileDates { copy.output.keepDates = true }
        return copy
    }
}
