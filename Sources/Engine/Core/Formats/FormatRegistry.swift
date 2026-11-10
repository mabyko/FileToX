// Port of Filee.Core/Formats/FileFormat.cs and FormatRegistry.cs (Filee 21fdd05).
// Central list of supported formats and extension lookup. Adding a format: one line in `known` plus an engine edge.

import Foundation

/// Broad family a format belongs to. Toolbar profiles and the UI group formats by this.
public enum FormatCategory: String, CaseIterable, Sendable {
    case image = "Image", pdf = "Pdf", document = "Document", spreadsheet = "Spreadsheet",
         presentation = "Presentation", hwp = "Hwp", text = "Text", video = "Video", audio = "Audio",
         ebook = "Ebook", archive = "Archive", vector = "Vector", cad = "Cad", font = "Font"
}

/// A file format known to Filee. The first extension is used for output files; compound extensions ("tar.gz") are allowed.
public struct FileFormat: Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let category: FormatCategory
    public let extensions: [String]
    /// False for formats only read (camera RAW, Pages, ...): never offered as a target.
    public let writable: Bool

    public init(id: String, displayName: String, category: FormatCategory, extensions: [String], writable: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.category = category
        self.extensions = extensions
        self.writable = writable
    }

    /// Extension (without dot) used when writing a file of this format.
    public var primaryExtension: String { extensions[0] }
}

/// Lookup table of every format Filee knows about.
public enum FormatRegistry {
    /// Pseudo format of the "Extract" preset: the output is a folder with the archive's files.
    public static let folder = "folder"

    /// All known formats, in the order shown in format pickers.
    public static let known: [FileFormat] = [
        FileFormat(id: "png", displayName: "PNG", category: .image, extensions: ["png"]),
        FileFormat(id: "jpg", displayName: "JPG", category: .image, extensions: ["jpg", "jpeg", "jpe", "jfif"]),
        FileFormat(id: "webp", displayName: "WEBP", category: .image, extensions: ["webp"]),
        FileFormat(id: "tiff", displayName: "TIFF", category: .image, extensions: ["tiff", "tif"]),
        FileFormat(id: "bmp", displayName: "BMP", category: .image, extensions: ["bmp", "dib"]),
        FileFormat(id: "gif", displayName: "GIF", category: .image, extensions: ["gif"]),
        FileFormat(id: "ico", displayName: "ICO", category: .image, extensions: ["ico"]),
        FileFormat(id: "avif", displayName: "AVIF", category: .image, extensions: ["avif"]),
        FileFormat(id: "heic", displayName: "HEIC", category: .image, extensions: ["heic", "heif"], writable: false),
        FileFormat(id: "jxl", displayName: "JPEG XL", category: .image, extensions: ["jxl"]),
        FileFormat(id: "jp2", displayName: "JPEG 2000", category: .image, extensions: ["jp2", "j2k", "jpf", "jpx"]),
        FileFormat(id: "psd", displayName: "PSD", category: .image, extensions: ["psd"]),
        FileFormat(id: "psb", displayName: "PSB", category: .image, extensions: ["psb"]),
        FileFormat(id: "tga", displayName: "TGA", category: .image, extensions: ["tga", "icb", "vda", "vst"]),
        FileFormat(id: "ppm", displayName: "PPM", category: .image, extensions: ["ppm", "pgm", "pbm", "pnm"]),
        FileFormat(id: "icns", displayName: "ICNS", category: .image, extensions: ["icns"]),
        FileFormat(id: "xcf", displayName: "XCF", category: .image, extensions: ["xcf"], writable: false),
        FileFormat(id: "raw", displayName: "RAW", category: .image, extensions: ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2", "raf", "pef", "dcr", "kdc", "erf", "mos", "mrw", "x3f", "3fr", "fff", "iiq", "mef", "rwl", "srw", "raw"], writable: false),
        FileFormat(id: "svg", displayName: "SVG", category: .vector, extensions: ["svg"]),
        FileFormat(id: "svgz", displayName: "SVGZ", category: .vector, extensions: ["svgz"]),
        FileFormat(id: "eps", displayName: "EPS", category: .vector, extensions: ["eps", "epsf", "epsi"]),
        FileFormat(id: "ps", displayName: "PS", category: .vector, extensions: ["ps"]),
        FileFormat(id: "ai", displayName: "AI", category: .vector, extensions: ["ai"], writable: false),
        FileFormat(id: "emf", displayName: "EMF", category: .vector, extensions: ["emf"], writable: false),
        FileFormat(id: "wmf", displayName: "WMF", category: .vector, extensions: ["wmf"], writable: false),
        FileFormat(id: "cdr", displayName: "CDR", category: .vector, extensions: ["cdr"], writable: false),
        FileFormat(id: "cgm", displayName: "CGM", category: .vector, extensions: ["cgm"], writable: false),
        FileFormat(id: "vsd", displayName: "VSD", category: .vector, extensions: ["vsd", "vsdx"], writable: false),
        FileFormat(id: "odg", displayName: "ODG", category: .vector, extensions: ["odg"]),
        FileFormat(id: "pdf", displayName: "PDF", category: .pdf, extensions: ["pdf"]),
        FileFormat(id: "docx", displayName: "DOCX", category: .document, extensions: ["docx"]),
        FileFormat(id: "docm", displayName: "DOCM", category: .document, extensions: ["docm"]),
        FileFormat(id: "dotx", displayName: "DOTX", category: .document, extensions: ["dotx"]),
        FileFormat(id: "dotm", displayName: "DOTM", category: .document, extensions: ["dotm"]),
        FileFormat(id: "doc", displayName: "DOC", category: .document, extensions: ["doc"]),
        FileFormat(id: "dot", displayName: "DOT", category: .document, extensions: ["dot"], writable: false),
        FileFormat(id: "odt", displayName: "ODT", category: .document, extensions: ["odt"]),
        FileFormat(id: "rtf", displayName: "RTF", category: .document, extensions: ["rtf"]),
        FileFormat(id: "wps", displayName: "WPS", category: .document, extensions: ["wps"], writable: false),
        FileFormat(id: "wpd", displayName: "WPD", category: .document, extensions: ["wpd"], writable: false),
        FileFormat(id: "lwp", displayName: "LWP", category: .document, extensions: ["lwp"], writable: false),
        FileFormat(id: "abw", displayName: "ABW", category: .document, extensions: ["abw", "zabw"], writable: false),
        FileFormat(id: "pages", displayName: "Pages", category: .document, extensions: ["pages"], writable: false),
        FileFormat(id: "sdw", displayName: "SDW", category: .document, extensions: ["sdw"], writable: false),
        FileFormat(id: "pub", displayName: "PUB", category: .document, extensions: ["pub"], writable: false),
        FileFormat(id: "eml", displayName: "EML", category: .document, extensions: ["eml"], writable: false),
        FileFormat(id: "hwpx", displayName: "HWPX", category: .hwp, extensions: ["hwpx"]),
        FileFormat(id: "hwp", displayName: "HWP", category: .hwp, extensions: ["hwp"]),
        FileFormat(id: "xlsx", displayName: "XLSX", category: .spreadsheet, extensions: ["xlsx"]),
        FileFormat(id: "xlsm", displayName: "XLSM", category: .spreadsheet, extensions: ["xlsm"]),
        FileFormat(id: "xltx", displayName: "XLTX", category: .spreadsheet, extensions: ["xltx"]),
        FileFormat(id: "xls", displayName: "XLS", category: .spreadsheet, extensions: ["xls", "xlt"]),
        FileFormat(id: "ods", displayName: "ODS", category: .spreadsheet, extensions: ["ods"]),
        FileFormat(id: "csv", displayName: "CSV", category: .spreadsheet, extensions: ["csv"]),
        FileFormat(id: "tsv", displayName: "TSV", category: .spreadsheet, extensions: ["tsv", "tab"]),
        FileFormat(id: "et", displayName: "ET", category: .spreadsheet, extensions: ["et"], writable: false),
        FileFormat(id: "numbers", displayName: "Numbers", category: .spreadsheet, extensions: ["numbers"], writable: false),
        FileFormat(id: "sdc", displayName: "SDC", category: .spreadsheet, extensions: ["sdc"], writable: false),
        FileFormat(id: "pptx", displayName: "PPTX", category: .presentation, extensions: ["pptx"]),
        FileFormat(id: "pptm", displayName: "PPTM", category: .presentation, extensions: ["pptm"]),
        FileFormat(id: "potx", displayName: "POTX", category: .presentation, extensions: ["potx"]),
        FileFormat(id: "ppsx", displayName: "PPSX", category: .presentation, extensions: ["ppsx"]),
        FileFormat(id: "ppt", displayName: "PPT", category: .presentation, extensions: ["ppt", "pps", "pot"]),
        FileFormat(id: "odp", displayName: "ODP", category: .presentation, extensions: ["odp"]),
        FileFormat(id: "key", displayName: "Keynote", category: .presentation, extensions: ["key"], writable: false),
        FileFormat(id: "dps", displayName: "DPS", category: .presentation, extensions: ["dps"], writable: false),
        FileFormat(id: "sda", displayName: "SDA", category: .presentation, extensions: ["sda", "sdd"], writable: false),
        FileFormat(id: "txt", displayName: "TXT", category: .text, extensions: ["txt"]),
        FileFormat(id: "md", displayName: "Markdown", category: .text, extensions: ["md", "markdown"]),
        FileFormat(id: "html", displayName: "HTML", category: .text, extensions: ["html", "htm", "xhtml"]),
        FileFormat(id: "rst", displayName: "reStructuredText", category: .text, extensions: ["rst"]),
        FileFormat(id: "tex", displayName: "LaTeX", category: .text, extensions: ["tex", "latex"]),
        FileFormat(id: "epub", displayName: "EPUB", category: .ebook, extensions: ["epub"]),
        FileFormat(id: "mobi", displayName: "MOBI", category: .ebook, extensions: ["mobi"]),
        FileFormat(id: "azw3", displayName: "AZW3", category: .ebook, extensions: ["azw3"]),
        FileFormat(id: "azw", displayName: "AZW", category: .ebook, extensions: ["azw"], writable: false),
        FileFormat(id: "azw4", displayName: "AZW4", category: .ebook, extensions: ["azw4"], writable: false),
        FileFormat(id: "prc", displayName: "PRC", category: .ebook, extensions: ["prc"], writable: false),
        FileFormat(id: "fb2", displayName: "FB2", category: .ebook, extensions: ["fb2"]),
        FileFormat(id: "cbz", displayName: "CBZ", category: .ebook, extensions: ["cbz"]),
        FileFormat(id: "cbr", displayName: "CBR", category: .ebook, extensions: ["cbr"], writable: false),
        FileFormat(id: "cb7", displayName: "CB7", category: .ebook, extensions: ["cb7"], writable: false),
        FileFormat(id: "cbt", displayName: "CBT", category: .ebook, extensions: ["cbt"], writable: false),
        FileFormat(id: "cbc", displayName: "CBC", category: .ebook, extensions: ["cbc"], writable: false),
        FileFormat(id: "htmlz", displayName: "HTMLZ", category: .ebook, extensions: ["htmlz"]),
        FileFormat(id: "txtz", displayName: "TXTZ", category: .ebook, extensions: ["txtz"]),
        FileFormat(id: "chm", displayName: "CHM", category: .ebook, extensions: ["chm"], writable: false),
        FileFormat(id: "lit", displayName: "LIT", category: .ebook, extensions: ["lit"]),
        FileFormat(id: "lrf", displayName: "LRF", category: .ebook, extensions: ["lrf"]),
        // Read only in FileToX: PalmDoc holds only Windows-1252 text, so Korean books could not be written.
        FileFormat(id: "pdb", displayName: "PDB", category: .ebook, extensions: ["pdb"], writable: false),
        FileFormat(id: "pml", displayName: "PML", category: .ebook, extensions: ["pml"]),
        FileFormat(id: "rb", displayName: "RB", category: .ebook, extensions: ["rb"]),
        FileFormat(id: "snb", displayName: "SNB", category: .ebook, extensions: ["snb"]),
        FileFormat(id: "tcr", displayName: "TCR", category: .ebook, extensions: ["tcr"]),
        FileFormat(id: "oeb", displayName: "OEB", category: .ebook, extensions: ["oeb", "opf"], writable: false),
        FileFormat(id: "mp4", displayName: "MP4", category: .video, extensions: ["mp4"]),
        FileFormat(id: "m4v", displayName: "M4V", category: .video, extensions: ["m4v"]),
        FileFormat(id: "mov", displayName: "MOV", category: .video, extensions: ["mov", "qt"]),
        FileFormat(id: "mkv", displayName: "MKV", category: .video, extensions: ["mkv"]),
        FileFormat(id: "webm", displayName: "WEBM", category: .video, extensions: ["webm"]),
        FileFormat(id: "avi", displayName: "AVI", category: .video, extensions: ["avi", "divx"]),
        FileFormat(id: "wmv", displayName: "WMV", category: .video, extensions: ["wmv", "asf"]),
        FileFormat(id: "flv", displayName: "FLV", category: .video, extensions: ["flv", "f4v"]),
        FileFormat(id: "mpg", displayName: "MPEG", category: .video, extensions: ["mpg", "mpeg", "mpe", "m1v", "m2v"]),
        FileFormat(id: "ts", displayName: "TS", category: .video, extensions: ["ts"]),
        FileFormat(id: "m2ts", displayName: "M2TS", category: .video, extensions: ["m2ts", "mts", "m2t"]),
        FileFormat(id: "3gp", displayName: "3GP", category: .video, extensions: ["3gp", "3gpp"]),
        FileFormat(id: "3g2", displayName: "3G2", category: .video, extensions: ["3g2"]),
        FileFormat(id: "ogv", displayName: "OGV", category: .video, extensions: ["ogv"]),
        FileFormat(id: "vob", displayName: "VOB", category: .video, extensions: ["vob"]),
        FileFormat(id: "mod", displayName: "MOD", category: .video, extensions: ["mod", "tod"], writable: false),
        FileFormat(id: "dv", displayName: "DV", category: .video, extensions: ["dv", "dif"]),
        FileFormat(id: "mxf", displayName: "MXF", category: .video, extensions: ["mxf"]),
        FileFormat(id: "rm", displayName: "RM", category: .video, extensions: ["rm", "rmvb"], writable: false),
        FileFormat(id: "swf", displayName: "SWF", category: .video, extensions: ["swf"], writable: false),
        FileFormat(id: "wtv", displayName: "WTV", category: .video, extensions: ["wtv", "dvr-ms", "dvr"], writable: false),
        FileFormat(id: "cavs", displayName: "CAVS", category: .video, extensions: ["cavs"], writable: false),
        FileFormat(id: "mp3", displayName: "MP3", category: .audio, extensions: ["mp3"]),
        FileFormat(id: "m4a", displayName: "M4A", category: .audio, extensions: ["m4a"]),
        FileFormat(id: "m4b", displayName: "M4B", category: .audio, extensions: ["m4b"]),
        FileFormat(id: "aac", displayName: "AAC", category: .audio, extensions: ["aac"]),
        FileFormat(id: "wav", displayName: "WAV", category: .audio, extensions: ["wav", "wave"]),
        FileFormat(id: "flac", displayName: "FLAC", category: .audio, extensions: ["flac"]),
        FileFormat(id: "ogg", displayName: "OGG", category: .audio, extensions: ["ogg", "oga"]),
        FileFormat(id: "opus", displayName: "OPUS", category: .audio, extensions: ["opus"]),
        FileFormat(id: "wma", displayName: "WMA", category: .audio, extensions: ["wma"]),
        FileFormat(id: "aiff", displayName: "AIFF", category: .audio, extensions: ["aiff", "aif", "aifc"]),
        FileFormat(id: "ac3", displayName: "AC3", category: .audio, extensions: ["ac3"]),
        FileFormat(id: "amr", displayName: "AMR", category: .audio, extensions: ["amr"]),
        FileFormat(id: "au", displayName: "AU", category: .audio, extensions: ["au", "snd"]),
        FileFormat(id: "caf", displayName: "CAF", category: .audio, extensions: ["caf"]),
        FileFormat(id: "weba", displayName: "WEBA", category: .audio, extensions: ["weba"]),
        FileFormat(id: "mka", displayName: "MKA", category: .audio, extensions: ["mka"]),
        FileFormat(id: "mp2", displayName: "MP2", category: .audio, extensions: ["mp2", "mpa"]),
        FileFormat(id: "dss", displayName: "DSS", category: .audio, extensions: ["dss"], writable: false),
        FileFormat(id: "voc", displayName: "VOC", category: .audio, extensions: ["voc"]),
        FileFormat(id: "zip", displayName: "ZIP", category: .archive, extensions: ["zip"]),
        FileFormat(id: "7z", displayName: "7Z", category: .archive, extensions: ["7z"]),
        FileFormat(id: "rar", displayName: "RAR", category: .archive, extensions: ["rar"], writable: false),
        FileFormat(id: "tar", displayName: "TAR", category: .archive, extensions: ["tar"]),
        FileFormat(id: "tgz", displayName: "TAR.GZ", category: .archive, extensions: ["tar.gz", "tgz", "taz"]),
        FileFormat(id: "tbz2", displayName: "TAR.BZ2", category: .archive, extensions: ["tar.bz2", "tbz2", "tar.bz", "tbz"]),
        FileFormat(id: "txz", displayName: "TAR.XZ", category: .archive, extensions: ["tar.xz", "txz"]),
        FileFormat(id: "tar7z", displayName: "TAR.7Z", category: .archive, extensions: ["tar.7z"], writable: false),
        FileFormat(id: "tlz", displayName: "TAR.LZ", category: .archive, extensions: ["tar.lz", "tlz"], writable: false),
        FileFormat(id: "tz", displayName: "TAR.Z", category: .archive, extensions: ["tar.z", "tz"], writable: false),
        FileFormat(id: "gz", displayName: "GZ", category: .archive, extensions: ["gz"]),
        FileFormat(id: "bz2", displayName: "BZ2", category: .archive, extensions: ["bz2", "bz"]),
        FileFormat(id: "xz", displayName: "XZ", category: .archive, extensions: ["xz"]),
        FileFormat(id: "lz", displayName: "LZ", category: .archive, extensions: ["lz"], writable: false),
        FileFormat(id: "lzma", displayName: "LZMA", category: .archive, extensions: ["lzma"], writable: false),
        FileFormat(id: "z", displayName: "Z", category: .archive, extensions: ["z"], writable: false),
        FileFormat(id: "jar", displayName: "JAR", category: .archive, extensions: ["jar"], writable: false),
        FileFormat(id: "cab", displayName: "CAB", category: .archive, extensions: ["cab"], writable: false),
        FileFormat(id: "cpio", displayName: "CPIO", category: .archive, extensions: ["cpio"], writable: false),
        FileFormat(id: "deb", displayName: "DEB", category: .archive, extensions: ["deb"], writable: false),
        FileFormat(id: "rpm", displayName: "RPM", category: .archive, extensions: ["rpm"], writable: false),
        FileFormat(id: "dmg", displayName: "DMG", category: .archive, extensions: ["dmg"], writable: false),
        FileFormat(id: "iso", displayName: "ISO", category: .archive, extensions: ["iso"], writable: false),
        FileFormat(id: "img", displayName: "IMG", category: .archive, extensions: ["img"], writable: false),
        FileFormat(id: "lha", displayName: "LHA", category: .archive, extensions: ["lha", "lzh"], writable: false),
        FileFormat(id: "arj", displayName: "ARJ", category: .archive, extensions: ["arj"], writable: false),
        FileFormat(id: "alz", displayName: "ALZ", category: .archive, extensions: ["alz"], writable: false),
        FileFormat(id: "egg", displayName: "EGG", category: .archive, extensions: ["egg"], writable: false),
        FileFormat(id: "folder", displayName: "Folder", category: .archive, extensions: [""]),
        FileFormat(id: "dwg", displayName: "DWG", category: .cad, extensions: ["dwg"]),
        FileFormat(id: "dxf", displayName: "DXF", category: .cad, extensions: ["dxf"]),
        FileFormat(id: "ttf", displayName: "TTF", category: .font, extensions: ["ttf"]),
        FileFormat(id: "otf", displayName: "OTF", category: .font, extensions: ["otf"]),
        FileFormat(id: "woff", displayName: "WOFF", category: .font, extensions: ["woff"]),
        FileFormat(id: "woff2", displayName: "WOFF2", category: .font, extensions: ["woff2"]),
        FileFormat(id: "eot", displayName: "EOT", category: .font, extensions: ["eot"]),
    ]

    private static let byId: [String: FileFormat] = Dictionary(known.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })

    private static let byExtension: [String: FileFormat] = {
        var map: [String: FileFormat] = [:]
        for format in known {
            for ext in format.extensions where !ext.isEmpty { map[ext.lowercased()] = map[ext.lowercased()] ?? format }
        }
        return map
    }()

    /// Extensions made of two parts ("tar.gz"), longest first, checked before the last part alone.
    private static let compoundExtensions: [String] = known
        .flatMap { $0.extensions.filter { $0.contains(".") } }
        .enumerated()
        .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
        .map(\.element)

    /// The format with the given id (case-insensitive), or nil.
    public static func find(id: String) -> FileFormat? { byId[id.lowercased()] }

    /// The format with the given id; traps on unknown ids like Filee's `Get` throws.
    public static func get(_ id: String) -> FileFormat {
        guard let format = find(id: id) else { preconditionFailure("Unknown format id '\(id)'.") }
        return format
    }

    /// The format for an extension (with or without the leading dot), or nil.
    public static func find(extension ext: String) -> FileFormat? {
        let trimmed = ext.drop { $0 == "." }
        return trimmed.isEmpty ? nil : byExtension[trimmed.lowercased()]
    }

    /// Detects the format of a file from its extension, or nil if it is not supported.
    public static func detect(_ path: String) -> FileFormat? { find(extension: extensionOf(path)) }

    /// The extension without the dot, including known two-part extensions ("archive.tar.gz" → "tar.gz").
    public static func extensionOf(_ path: String) -> String {
        let name = FilePath.fileName(path)
        let lowered = name.lowercased()
        for compound in compoundExtensions where name.count > compound.count + 1 && lowered.hasSuffix("." + compound) {
            return String(name.suffix(compound.count))
        }
        return String(FilePath.extension(name).dropFirst())
    }

    /// The file name without its (possibly two-part) extension: "backup.tar.gz" → "backup".
    public static func nameWithoutExtension(_ path: String) -> String {
        let name = FilePath.fileName(path)
        let ext = extensionOf(name)
        return ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
    }
}
