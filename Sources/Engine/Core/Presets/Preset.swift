// Port of Filee.Core/Presets/Preset.cs and OutputRule.cs (Filee 21fdd05): the options of one conversion recipe.
// Value types, so a job's copy never changes when the library is edited (Filee's Clone()).
// Raw values are Filee's enum member names, as written in the user's JSON files.

import Foundation

/// A named conversion recipe ("convert to TargetFormat with these options"). One slice of the donut toolbar.
public struct Preset: Equatable, Sendable {
    /// Stable identifier referenced by toolbar profiles. Never shown to users.
    public var id: String = Preset.newId()
    /// User-defined name. When empty, `nameKey` is localized and shown instead.
    public var name: String = ""
    /// Localization key for built-in presets (e.g. `preset.merge_pdf`). Ignored when `name` is set.
    public var nameKey: String?
    /// Id of the output format (see `FormatRegistry`), or `BuiltInData.sameAsSource`.
    public var targetFormat: String = "png"
    public var image = ImageOptions()
    public var pdf = PdfOptions()
    public var document = DocumentOptions()
    public var media = MediaOptions()
    public var archive = ArchiveOptions()
    public var output = OutputRule()

    public init() {}

    /// A new random preset id: 12 lower-case hex digits like Filee's `Guid.ToString("N")[..12]`.
    public static func newId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)) }
}

/// How an image is resized before it is encoded.
public enum ResizeMode: String, CaseIterable, Sendable {
    /// Keep the original pixel size.
    case none = "None"
    /// Scale by `ImageOptions.resizePercent`.
    case percent = "Percent"
    /// Scale so the longer edge equals `ImageOptions.longEdge` (never upscales).
    case longEdge = "LongEdge"
}

public enum TiffCompression: String, CaseIterable, Sendable {
    case none = "None", lzw = "Lzw", zip = "Zip"
}

/// Raster image encoding options.
public struct ImageOptions: Equatable, Sendable {
    /// Lossy quality 1-100 (JPG, WEBP, AVIF).
    public var quality = 90
    public var resize = ResizeMode.none
    /// Scale in percent when `resize` is `.percent`.
    public var resizePercent = 50
    /// Target long-edge length in pixels when `resize` is `.longEdge`.
    public var longEdge = 1920
    /// Output DPI written into the file. nil keeps the source value.
    public var dpi: Int?
    /// Keep EXIF / XMP / ICC metadata.
    public var keepMetadata = true
    /// When metadata is removed, still keep the ICC profile (wide-gamut photos look washed out without it).
    public var keepColorProfile = true
    public var grayscale = false
    /// Fill colour for transparent pixels when the target has no alpha channel (e.g. JPG).
    public var background = "#FFFFFF"
    public var tiffCompression = TiffCompression.lzw
    /// TIFF target: every file becomes pages of one multi-page TIFF instead of one TIFF per file.
    public var multiPageTiff = false
    /// Use lossless WEBP encoding.
    public var webpLossless = false
    /// Icon sizes embedded in an ICO file.
    public var icoSizes = [256, 128, 64, 48, 32, 16]

    public init() {}
}

/// Page size used when images are placed into a PDF.
public enum PdfPageSize: String, CaseIterable, Sendable {
    /// Each page has the size of its image.
    case fitImage = "FitImage"
    case a4 = "A4"
    case letter = "Letter"
}

public struct PdfOptions: Equatable, Sendable {
    /// Combine all dropped files into one PDF instead of one PDF per file.
    public var mergeIntoSingle = false
    public var pageSize = PdfPageSize.fitImage
    /// Page margin in millimetres (ignored for `.fitImage`).
    public var marginMm = 0.0
    /// Resolution used when PDF pages are rendered to images.
    public var renderDpi = 150
    /// Pages to process, e.g. "1-3,5". Empty means all pages (see `PageRange`).
    public var pageRange = ""
    /// For PDF → PDF: write every page as its own file.
    public var splitPages = false

    public init() {}
}

public struct DocumentOptions: Equatable, Sendable {
    /// Export PDF/A (archival) when producing PDF from documents.
    public var pdfA = false

    public init() {}
}

/// Trade-off between quality and file size for video and lossy audio.
public enum MediaQuality: String, CaseIterable, Sendable {
    case high = "High", balanced = "Balanced", small = "Small"
}

/// Sample format of a WAV file.
public enum WavSampleFormat: String, CaseIterable, Sendable {
    case pcm16 = "Pcm16", pcm8 = "Pcm8", pcm24 = "Pcm24", pcm32 = "Pcm32", float32 = "Float32"
}

public struct MediaOptions: Equatable, Sendable {
    public var quality = MediaQuality.balanced
    /// Largest output height in pixels (e.g. 720); 0 keeps the source size. Never upscales.
    public var maxHeight = 0
    /// Audio bitrate in kbit/s for lossy audio; 0 uses a good default for the format.
    public var audioBitrateKbps = 0
    /// Drop the audio track of a video.
    public var removeAudio = false
    /// Audio channels of an audio file: 0 keeps the source's, 1 mono, 2 stereo.
    public var audioChannels = 0
    /// Sample rate in Hz of a WAV file (8000 … 48000); 0 keeps the source's.
    public var audioSampleRate = 0
    public var wavFormat = WavSampleFormat.pcm16

    public init() {}
}

/// How hard archives are compressed.
public enum ArchiveLevel: String, CaseIterable, Sendable {
    case store = "Store", fast = "Fast", normal = "Normal", maximum = "Maximum"
}

public struct ArchiveOptions: Equatable, Sendable {
    /// Put all dropped files into one archive instead of one archive per file.
    public var combineIntoOne = false
    public var level = ArchiveLevel.normal

    public init() {}
}

/// Where converted files go.
public enum OutputLocation: String, CaseIterable, Sendable {
    /// The default save location from Settings → General; where nothing resolves it, `.sameFolder`.
    case `default` = "Default"
    /// Next to the source file.
    case sameFolder = "SameFolder"
    /// In a sub folder (`OutputRule.subfolderName`) next to the source file.
    case subfolder = "Subfolder"
    /// In a fixed folder (`OutputRule.customFolder`).
    case customFolder = "CustomFolder"
}

/// What to do when the output file already exists.
public enum ConflictPolicy: String, CaseIterable, Sendable {
    /// Append " (2)", " (3)" ... to the file name.
    case rename = "Rename"
    /// Replace the existing file (never the source file itself).
    case overwrite = "Overwrite"
    /// Leave the existing file alone and skip this conversion.
    case skip = "Skip"
}

/// Output placement and naming rules.
public struct OutputRule: Equatable, Sendable {
    public var location = OutputLocation.default
    public var subfolderName = "converted"
    public var customFolder = ""
    /// File name pattern without extension. Tokens: {name} {ext} {preset} {date} {time} {index}.
    public var fileNamePattern = "{name}"
    /// Replacements applied in order to the name made from `fileNamePattern`.
    public var renames: [RenameStep] = []
    public var conflict = ConflictPolicy.rename
    /// Give converted files the creation and modification dates of their source (not merged PDFs / combined archives).
    public var keepDates = false

    public init() {}
}

/// What a `RenameStep` does to a name.
public enum RenameKind: String, CaseIterable, Sendable {
    case replace = "Replace", remove = "Remove", prefix = "Prefix", suffix = "Suffix",
         spacesToUnderscores = "SpacesToUnderscores", removeCopyNumber = "RemoveCopyNumber",
         removeBrackets = "RemoveBrackets", removeLeadingNumber = "RemoveLeadingNumber",
         removeSymbols = "RemoveSymbols", lowercase = "Lowercase", uppercase = "Uppercase", regex = "Regex"
}

/// One change to the name of a converted file.
public struct RenameStep: Equatable, Sendable {
    public var kind = RenameKind.replace
    /// The text (or, for `.regex`, the expression) looked for.
    public var find = ""
    /// What goes in its place, or the text added by `.prefix` and `.suffix`.
    public var replace = ""

    public init(kind: RenameKind = .replace, find: String = "", replace: String = "") {
        self.kind = kind
        self.find = find
        self.replace = replace
    }

    /// True for a step that changes nothing because its text is still missing.
    public var isBlank: Bool {
        switch kind {
        case .replace, .remove, .regex: find.isEmpty
        case .prefix, .suffix: replace.isEmpty
        default: false
        }
    }
}

/// Built-in data shared by presets and engines (the preset/profile lists themselves live with the user data store).
public enum BuiltInData {
    /// Target format of "convert to the same format" presets (re-encode, compress, split).
    public static let sameAsSource = "*"
}
