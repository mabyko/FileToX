// Factory defaults ported verbatim from Filee 21fdd05 BuiltInData.cs.
import Foundation

public extension BuiltInData {
    static func createPresets() -> [Preset] {
        [
            { var p = Preset(); p.id = "to-png"; p.name = "PNG"; p.targetFormat = "png"; return p }(),
            { var p = Preset(); p.id = "to-jpg"; p.name = "JPG"; p.targetFormat = "jpg"; p.image.quality = 90; return p }(),
            { var p = Preset(); p.id = "jpg-70"; p.name = "JPG 70%"; p.targetFormat = "jpg"; p.image.quality = 70; p.output.fileNamePattern = "{name}_70"; return p }(),
            { var p = Preset(); p.id = "to-webp"; p.name = "WEBP"; p.targetFormat = "webp"; p.image.quality = 85; return p }(),
            { var p = Preset(); p.id = "to-tiff"; p.name = "TIFF"; p.targetFormat = "tiff"; return p }(),
            { var p = Preset(); p.id = "to-bmp"; p.name = "BMP"; p.targetFormat = "bmp"; return p }(),
            { var p = Preset(); p.id = "to-ico"; p.name = "ICO"; p.targetFormat = "ico"; return p }(),
            { var p = Preset(); p.id = "to-gif"; p.name = "GIF"; p.targetFormat = "gif"; return p }(),
            { var p = Preset(); p.id = "to-avif"; p.name = "AVIF"; p.targetFormat = "avif"; p.image.quality = 60; return p }(),
            { var p = Preset(); p.id = "half-size"; p.nameKey = "preset.half_size"; p.targetFormat = sameAsSource; p.image.resize = .percent; p.image.resizePercent = 50; p.output.fileNamePattern = "{name}_50"; return p }(),
            { var p = Preset(); p.id = "grayscale"; p.nameKey = "preset.grayscale"; p.targetFormat = sameAsSource; p.image.grayscale = true; p.output.fileNamePattern = "{name}_gray"; return p }(),
            { var p = Preset(); p.id = "tiff-300"; p.name = "TIFF 300dpi"; p.targetFormat = "tiff"; p.image.dpi = 300; p.pdf.renderDpi = 300; p.output.fileNamePattern = "{name}_300dpi"; return p }(),
            { var p = Preset(); p.id = "to-pdf"; p.name = "PDF"; p.targetFormat = "pdf"; return p }(),
            { var p = Preset(); p.id = "merge-pdf"; p.nameKey = "preset.merge_pdf"; p.targetFormat = "pdf"; p.pdf.mergeIntoSingle = true; p.output.fileNamePattern = "{name}_merged"; return p }(),
            { var p = Preset(); p.id = "pdf-split"; p.nameKey = "preset.split_pdf"; p.targetFormat = "pdf"; p.pdf.splitPages = true; p.output.location = .subfolder; p.output.subfolderName = "{name}"; return p }(),
            { var p = Preset(); p.id = "to-docx"; p.name = "DOCX"; p.targetFormat = "docx"; return p }(),
            { var p = Preset(); p.id = "to-hwpx"; p.name = "HWPX"; p.targetFormat = "hwpx"; return p }()
        ] + hwpPresets() + [
            { var p = Preset(); p.id = "to-odt"; p.name = "ODT"; p.targetFormat = "odt"; return p }(),
            { var p = Preset(); p.id = "to-rtf"; p.name = "RTF"; p.targetFormat = "rtf"; return p }(),
            { var p = Preset(); p.id = "to-txt"; p.name = "TXT"; p.targetFormat = "txt"; return p }(),
            { var p = Preset(); p.id = "to-md"; p.name = "Markdown"; p.targetFormat = "md"; return p }(),
            { var p = Preset(); p.id = "to-html"; p.name = "HTML"; p.targetFormat = "html"; return p }()
        ] + spreadsheetPresets() + catalogPresets()
    }
    static func hwpPresets() -> [Preset] {
        [
            { var p = Preset(); p.id = "to-hwp"; p.name = "HWP"; p.targetFormat = "hwp"; return p }()
        ]
    }
    static func spreadsheetPresets() -> [Preset] {
        [
            { var p = Preset(); p.id = "to-xlsx"; p.name = "XLSX"; p.targetFormat = "xlsx"; return p }(),
            { var p = Preset(); p.id = "to-csv"; p.name = "CSV"; p.targetFormat = "csv"; return p }()
        ]
    }
    static func catalogPresets() -> [Preset] {
        [
            { var p = Preset(); p.id = "to-jxl"; p.name = "JPEG XL"; p.targetFormat = "jxl"; p.image.quality = 85; return p }(),
            { var p = Preset(); p.id = "to-psd"; p.name = "PSD"; p.targetFormat = "psd"; return p }(),
            { var p = Preset(); p.id = "to-tga"; p.name = "TGA"; p.targetFormat = "tga"; return p }(),
            { var p = Preset(); p.id = "to-icns"; p.name = "ICNS"; p.targetFormat = "icns"; return p }(),
            { var p = Preset(); p.id = "to-svg"; p.name = "SVG"; p.targetFormat = "svg"; return p }(),
            { var p = Preset(); p.id = "to-eps"; p.name = "EPS"; p.targetFormat = "eps"; return p }(),
            { var p = Preset(); p.id = "to-ods"; p.name = "ODS"; p.targetFormat = "ods"; return p }(),
            { var p = Preset(); p.id = "to-pptx"; p.name = "PPTX"; p.targetFormat = "pptx"; return p }(),
            { var p = Preset(); p.id = "to-odp"; p.name = "ODP"; p.targetFormat = "odp"; return p }(),
            { var p = Preset(); p.id = "to-epub"; p.name = "EPUB"; p.targetFormat = "epub"; return p }(),
            { var p = Preset(); p.id = "to-mobi"; p.name = "MOBI"; p.targetFormat = "mobi"; return p }(),
            { var p = Preset(); p.id = "to-azw3"; p.name = "AZW3"; p.targetFormat = "azw3"; return p }(),
            { var p = Preset(); p.id = "to-fb2"; p.name = "FB2"; p.targetFormat = "fb2"; return p }(),
            { var p = Preset(); p.id = "to-cbz"; p.name = "CBZ"; p.targetFormat = "cbz"; return p }(),
            { var p = Preset(); p.id = "to-mp4"; p.name = "MP4"; p.targetFormat = "mp4"; return p }(),
            { var p = Preset(); p.id = "mp4-720"; p.name = "MP4 720p"; p.targetFormat = "mp4"; p.media.maxHeight = 720; p.media.quality = .small; p.output.fileNamePattern = "{name}_720p"; return p }(),
            { var p = Preset(); p.id = "to-webm"; p.name = "WEBM"; p.targetFormat = "webm"; return p }(),
            { var p = Preset(); p.id = "to-mov"; p.name = "MOV"; p.targetFormat = "mov"; return p }(),
            { var p = Preset(); p.id = "to-mkv"; p.name = "MKV"; p.targetFormat = "mkv"; return p }(),
            { var p = Preset(); p.id = "to-avi"; p.name = "AVI"; p.targetFormat = "avi"; return p }(),
            { var p = Preset(); p.id = "to-mp3"; p.name = "MP3"; p.targetFormat = "mp3"; return p }(),
            { var p = Preset(); p.id = "mp3-128"; p.name = "MP3 128k"; p.targetFormat = "mp3"; p.media.audioBitrateKbps = 128; p.output.fileNamePattern = "{name}_128k"; return p }(),
            { var p = Preset(); p.id = "to-m4a"; p.name = "M4A"; p.targetFormat = "m4a"; return p }(),
            { var p = Preset(); p.id = "to-wav"; p.name = "WAV"; p.targetFormat = "wav"; return p }(),
            { var p = Preset(); p.id = "to-flac"; p.name = "FLAC"; p.targetFormat = "flac"; return p }(),
            { var p = Preset(); p.id = "to-ogg"; p.name = "OGG"; p.targetFormat = "ogg"; return p }(),
            { var p = Preset(); p.id = "to-opus"; p.name = "OPUS"; p.targetFormat = "opus"; return p }(),
            { var p = Preset(); p.id = "to-aac"; p.name = "AAC"; p.targetFormat = "aac"; return p }(),
            { var p = Preset(); p.id = "to-zip"; p.name = "ZIP"; p.targetFormat = "zip"; return p }(),
            { var p = Preset(); p.id = "to-7z"; p.name = "7Z"; p.targetFormat = "7z"; return p }(),
            { var p = Preset(); p.id = "to-tgz"; p.name = "TAR.GZ"; p.targetFormat = "tgz"; return p }(),
            { var p = Preset(); p.id = "to-tar"; p.name = "TAR"; p.targetFormat = "tar"; return p }(),
            { var p = Preset(); p.id = "extract"; p.nameKey = "preset.extract"; p.targetFormat = FormatRegistry.folder; return p }(),
            { var p = Preset(); p.id = "zip-all"; p.nameKey = "preset.zip_all"; p.targetFormat = "zip"; p.archive.combineIntoOne = true; p.output.fileNamePattern = "{name}_files"; return p }(),
            { var p = Preset(); p.id = "to-dxf"; p.name = "DXF"; p.targetFormat = "dxf"; return p }(),
            { var p = Preset(); p.id = "to-dwg"; p.name = "DWG"; p.targetFormat = "dwg"; return p }(),
            { var p = Preset(); p.id = "to-ttf"; p.name = "TTF"; p.targetFormat = "ttf"; return p }(),
            { var p = Preset(); p.id = "to-otf"; p.name = "OTF"; p.targetFormat = "otf"; return p }(),
            { var p = Preset(); p.id = "to-woff"; p.name = "WOFF"; p.targetFormat = "woff"; return p }(),
            { var p = Preset(); p.id = "to-woff2"; p.name = "WOFF2"; p.targetFormat = "woff2"; return p }(),
            { var p = Preset(); p.id = "to-eot"; p.name = "EOT"; p.targetFormat = "eot"; return p }()
        ]
    }
    static func createProfiles() -> [ToolbarProfile] {
        [
            { var p = ToolbarProfile(); p.id = "images"; p.nameKey = "profile.images"; p.extensions = extensionsOf(.image); p.presetIds = ["to-png", "to-jpg", "to-webp", "to-pdf", "to-tiff", "to-bmp", "to-ico", "half-size"]; return p }(),
            { var p = ToolbarProfile(); p.id = "pdf"; p.nameKey = "profile.pdf"; p.extensions = ["pdf"]; p.presetIds = ["to-png", "to-jpg", "to-docx", "to-txt", "to-md", "to-epub", "to-hwpx", "to-hwp", "to-tiff", "pdf-split", "merge-pdf"]; return p }(),
            { var p = ToolbarProfile(); p.id = "office"; p.nameKey = "profile.office"; p.extensions = extensionsOf(.document); p.presetIds = ["to-pdf", "to-hwpx", "to-hwp", "to-docx", "to-odt", "to-txt", "to-html", "to-epub", "to-png", "merge-pdf"]; return p }(),
            spreadsheetProfile(),
            presentationProfile(),
            { var p = ToolbarProfile(); p.id = "hwp"; p.nameKey = "profile.hwp"; p.extensions = ["hwp", "hwpx"]; p.presetIds = ["to-pdf", "to-docx", "to-hwpx", "to-hwp", "to-png", "to-jpg", "to-txt", "to-md", "to-epub", "merge-pdf"]; return p }(),
            textProfile()
        ] + catalogProfiles() + [
            { var p = ToolbarProfile(); p.id = "mixed"; p.nameKey = "profile.mixed"; p.isFallback = true; p.presetIds = ["to-pdf", "merge-pdf", "zip-all", "to-png", "to-txt"]; return p }()
        ]
    }
    static func spreadsheetProfile() -> ToolbarProfile {
        { var p = ToolbarProfile(); p.id = "spreadsheets"; p.nameKey = "profile.spreadsheets"; p.extensions = extensionsOf(.spreadsheet); p.presetIds = ["to-pdf", "to-xlsx", "to-csv", "to-ods", "to-hwpx", "to-hwp", "to-html", "merge-pdf"]; return p }()
    }
    static func presentationProfile() -> ToolbarProfile {
        { var p = ToolbarProfile(); p.id = "presentations"; p.nameKey = "profile.presentations"; p.extensions = extensionsOf(.presentation); p.presetIds = ["to-pdf", "to-png", "to-jpg", "to-pptx", "to-hwpx", "to-hwp", "merge-pdf"]; return p }()
    }
    static func textProfile() -> ToolbarProfile {
        { var p = ToolbarProfile(); p.id = "text"; p.nameKey = "profile.text"; p.extensions = extensionsOf(.text); p.presetIds = ["to-pdf", "to-hwpx", "to-hwp", "to-docx", "to-html", "to-txt", "to-epub"]; return p }()
    }
    static func catalogProfiles() -> [ToolbarProfile] {
        [
            { var p = ToolbarProfile(); p.id = "ebooks"; p.nameKey = "profile.ebooks"; p.extensions = extensionsOf(.ebook); p.presetIds = ["to-pdf", "to-epub", "to-docx", "to-txt", "to-azw3", "to-mobi", "to-hwpx", "to-hwp", "to-html"]; return p }(),
            { var p = ToolbarProfile(); p.id = "video"; p.nameKey = "profile.video"; p.extensions = extensionsOf(.video); p.presetIds = ["to-mp4", "mp4-720", "to-webm", "to-mov", "to-gif", "to-mp3", "to-mkv", "to-avi"]; return p }(),
            { var p = ToolbarProfile(); p.id = "audio"; p.nameKey = "profile.audio"; p.extensions = extensionsOf(.audio); p.presetIds = ["to-mp3", "mp3-128", "to-m4a", "to-wav", "to-flac", "to-ogg", "to-opus", "to-aac"]; return p }(),
            { var p = ToolbarProfile(); p.id = "vector"; p.nameKey = "profile.vector"; p.extensions = extensionsOf(.vector); p.presetIds = ["to-png", "to-pdf", "to-svg", "to-jpg", "to-webp", "to-eps"]; return p }(),
            { var p = ToolbarProfile(); p.id = "archives"; p.nameKey = "profile.archives"; p.extensions = extensionsOf(.archive); p.presetIds = ["extract", "to-zip", "to-7z", "to-tgz", "to-tar"]; return p }(),
            { var p = ToolbarProfile(); p.id = "cad"; p.nameKey = "profile.cad"; p.extensions = extensionsOf(.cad); p.presetIds = ["to-pdf", "to-png", "to-svg", "to-dxf", "to-dwg"]; return p }(),
            { var p = ToolbarProfile(); p.id = "fonts"; p.nameKey = "profile.fonts"; p.extensions = extensionsOf(.font); p.presetIds = ["to-woff2", "to-woff", "to-ttf", "to-otf", "to-eot"]; return p }()
        ]
    }
    static func extensionsOf(_ category: FormatCategory) -> [String] {
        FormatRegistry.known.filter { $0.category == category }.flatMap(\.extensions).filter { !$0.isEmpty }
    }
}
