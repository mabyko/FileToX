// Explicit field lists keep disk defaults and strict wire decoding independent.
import Foundation

extension ThemeMode: EngineStringEnum {}
extension TriggerMouseButton: EngineStringEnum {}
extension TriggerKind: EngineStringEnum {}
extension TriggerScope: EngineStringEnum {}
extension FormatCategory: EngineStringEnum {}
extension AfterConversion: EngineStringEnum {}
extension JobState: EngineStringEnum {}
extension FileState: EngineStringEnum {}
extension ResizeMode: EngineStringEnum {}
extension TiffCompression: EngineStringEnum {}
extension PdfPageSize: EngineStringEnum {}
extension MediaQuality: EngineStringEnum {}
extension WavSampleFormat: EngineStringEnum {}
extension ArchiveLevel: EngineStringEnum {}
extension OutputLocation: EngineStringEnum {}
extension ConflictPolicy: EngineStringEnum {}
extension RenameKind: EngineStringEnum {}

extension ThemeSettings: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["mode", "accent", "cornerRadius", "reduceMotion"], getters: [])
        mode = try c.engineField("mode", mode)
        accent = try c.engineField("accent", accent)
        cornerRadius = try c.engineField("cornerRadius", cornerRadius)
        reduceMotion = try c.engineField("reduceMotion", reduceMotion)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("mode", mode)
        try c.engineField("accent", accent)
        try c.engineField("cornerRadius", cornerRadius)
        try c.engineOptional("reduceMotion", reduceMotion, encoder)
    }
}

extension DonutSettings: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["outerRadius", "holeRatio", "opacity"], getters: [])
        outerRadius = try c.engineField("outerRadius", outerRadius)
        holeRatio = try c.engineField("holeRatio", holeRatio)
        opacity = try c.engineField("opacity", opacity)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("outerRadius", outerRadius)
        try c.engineField("holeRatio", holeRatio)
        try c.engineField("opacity", opacity)
    }
}

extension DefaultOutputSettings: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["location", "subfolderName", "customFolder"], getters: [])
        location = try c.engineField("location", location)
        subfolderName = try c.engineField("subfolderName", subfolderName)
        customFolder = try c.engineField("customFolder", customFolder)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("location", location)
        try c.engineField("subfolderName", subfolderName)
        try c.engineField("customFolder", customFolder)
    }
}

extension AppSettings: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["schemaVersion", "language", "startWithSystem", "contextMenuEnabled", "checkForUpdates", "keepHistory", "notifiedUpdateVersion", "paused", "theme", "donut", "triggers", "excludedProcesses", "enginePriority", "firstRunCompleted", "successfulConversions", "feedbackPromptShown", "watchFolders", "defaultOutput", "engineOwnCopies", "keepFileDates"], getters: [])
        schemaVersion = try c.engineField("schemaVersion", schemaVersion)
        language = try c.engineField("language", language)
        startWithSystem = try c.engineField("startWithSystem", startWithSystem)
        contextMenuEnabled = try c.engineField("contextMenuEnabled", contextMenuEnabled)
        checkForUpdates = try c.engineField("checkForUpdates", checkForUpdates)
        keepHistory = try c.engineField("keepHistory", keepHistory)
        notifiedUpdateVersion = try c.engineField("notifiedUpdateVersion", notifiedUpdateVersion)
        paused = try c.engineField("paused", paused)
        theme = try c.engineField("theme", theme)
        donut = try c.engineField("donut", donut)
        triggers = try c.engineField("triggers", triggers)
        excludedProcesses = try c.engineField("excludedProcesses", excludedProcesses)
        enginePriority = try c.engineField("enginePriority", enginePriority)
        firstRunCompleted = try c.engineField("firstRunCompleted", firstRunCompleted)
        successfulConversions = try c.engineField("successfulConversions", successfulConversions)
        feedbackPromptShown = try c.engineField("feedbackPromptShown", feedbackPromptShown)
        watchFolders = try c.engineField("watchFolders", watchFolders)
        defaultOutput = try c.engineField("defaultOutput", defaultOutput)
        engineOwnCopies = try c.engineField("engineOwnCopies", engineOwnCopies)
        keepFileDates = try c.engineField("keepFileDates", keepFileDates)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("schemaVersion", schemaVersion)
        try c.engineField("language", language)
        try c.engineField("startWithSystem", startWithSystem)
        try c.engineField("contextMenuEnabled", contextMenuEnabled)
        try c.engineField("checkForUpdates", checkForUpdates)
        try c.engineField("keepHistory", keepHistory)
        try c.engineOptional("notifiedUpdateVersion", notifiedUpdateVersion, encoder)
        try c.engineField("paused", paused)
        try c.engineField("theme", theme)
        try c.engineField("donut", donut)
        try c.engineField("triggers", triggers)
        try c.engineField("excludedProcesses", excludedProcesses)
        try c.engineField("enginePriority", enginePriority)
        try c.engineField("firstRunCompleted", firstRunCompleted)
        try c.engineField("successfulConversions", successfulConversions)
        try c.engineField("feedbackPromptShown", feedbackPromptShown)
        try c.engineField("watchFolders", watchFolders)
        try c.engineField("defaultOutput", defaultOutput)
        try c.engineField("engineOwnCopies", engineOwnCopies)
        try c.engineField("keepFileDates", keepFileDates)
    }
}

extension TriggerGesture: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["id", "enabled", "kind", "modifiers", "button", "key", "dragThreshold", "holdMilliseconds", "scope"], getters: [])
        id = try c.engineField("id", id)
        enabled = try c.engineField("enabled", enabled)
        kind = try c.engineField("kind", kind)
        modifiers = try c.engineField("modifiers", modifiers)
        button = try c.engineField("button", button)
        key = try c.engineField("key", key)
        dragThreshold = try c.engineField("dragThreshold", dragThreshold)
        holdMilliseconds = try c.engineField("holdMilliseconds", holdMilliseconds)
        scope = try c.engineField("scope", scope)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("id", id)
        try c.engineField("enabled", enabled)
        try c.engineField("kind", kind)
        try c.engineField("modifiers", modifiers)
        try c.engineField("button", button)
        try c.engineOptional("key", key, encoder)
        try c.engineField("dragThreshold", dragThreshold)
        try c.engineField("holdMilliseconds", holdMilliseconds)
        try c.engineField("scope", scope)
    }
}

extension PresetBundle: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["schemaVersion", "presets", "profiles"], getters: [])
        schemaVersion = try c.engineField("schemaVersion", schemaVersion)
        presets = try c.engineField("presets", presets)
        profiles = try c.engineField("profiles", profiles)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("schemaVersion", schemaVersion)
        try c.engineField("presets", presets)
        try c.engineField("profiles", profiles)
    }
}

extension WatchRule: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["id", "enabled", "folder", "presetId", "includeSubfolders", "outputFolder", "originals", "include", "fileNamePattern", "renames"], getters: ["resolvedOutputFolder", "originalsFolder"])
        id = try c.engineField("id", id)
        enabled = try c.engineField("enabled", enabled)
        folder = try c.engineField("folder", folder)
        presetId = try c.engineField("presetId", presetId)
        includeSubfolders = try c.engineField("includeSubfolders", includeSubfolders)
        outputFolder = try c.engineField("outputFolder", outputFolder)
        originals = try c.engineField("originals", originals)
        include = try c.engineField("include", include)
        fileNamePattern = try c.engineField("fileNamePattern", fileNamePattern)
        renames = try c.engineField("renames", renames)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("id", id)
        try c.engineField("enabled", enabled)
        try c.engineField("folder", folder)
        try c.engineField("presetId", presetId)
        try c.engineField("includeSubfolders", includeSubfolders)
        try c.engineField("outputFolder", outputFolder)
        try c.engineField("originals", originals)
        try c.engineField("include", include)
        try c.engineField("fileNamePattern", fileNamePattern)
        try c.engineField("renames", renames)
        try c.engineField("resolvedOutputFolder", resolvedOutputFolder)
        try c.engineField("originalsFolder", originalsFolder)
    }
}

extension HistoryFailure: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["source", "errorKey", "errorDetail"], getters: [])
        source = try c.engineField("source", source)
        errorKey = try c.engineField("errorKey", errorKey)
        errorDetail = try c.engineField("errorDetail", errorDetail)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("source", source)
        try c.engineOptional("errorKey", errorKey, encoder)
        try c.engineOptional("errorDetail", errorDetail, encoder)
    }
}

extension HistoryEntry: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["jobId", "finishedAt", "presetId", "presetName", "state", "sources", "outputs", "watchRuleId", "failures", "preset", "errors"], getters: [])
        jobId = try c.engineField("jobId", jobId)
        finishedAt = try c.engineField("finishedAt", finishedAt)
        presetId = try c.engineField("presetId", presetId)
        presetName = try c.engineField("presetName", presetName)
        state = try c.engineField("state", state)
        sources = try c.engineField("sources", sources)
        outputs = try c.engineField("outputs", outputs)
        watchRuleId = try c.engineField("watchRuleId", watchRuleId)
        failures = try c.engineField("failures", failures)
        preset = try c.engineField("preset", preset)
        errors = try c.engineField("errors", errors)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("jobId", jobId)
        try c.engineField("finishedAt", finishedAt)
        try c.engineField("presetId", presetId)
        try c.engineField("presetName", presetName)
        try c.engineField("state", state)
        try c.engineField("sources", sources)
        try c.engineField("outputs", outputs)
        try c.engineOptional("watchRuleId", watchRuleId, encoder)
        try c.engineField("failures", failures)
        try c.engineOptional("preset", preset, encoder)
        try c.engineField("errors", errors)
    }
}

extension ToolbarProfile: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["id", "name", "nameKey", "extensions", "isFallback", "presetIds"], getters: [])
        id = try c.engineField("id", id)
        name = try c.engineField("name", name)
        nameKey = try c.engineField("nameKey", nameKey)
        extensions = try c.engineField("extensions", extensions)
        isFallback = try c.engineField("isFallback", isFallback)
        presetIds = try c.engineField("presetIds", presetIds)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("id", id)
        try c.engineField("name", name)
        try c.engineOptional("nameKey", nameKey, encoder)
        try c.engineField("extensions", extensions)
        try c.engineField("isFallback", isFallback)
        try c.engineField("presetIds", presetIds)
    }
}

extension Preset: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["id", "name", "nameKey", "targetFormat", "image", "pdf", "document", "media", "archive", "output"], getters: [])
        id = try c.engineField("id", id)
        name = try c.engineField("name", name)
        nameKey = try c.engineField("nameKey", nameKey)
        targetFormat = try c.engineField("targetFormat", targetFormat)
        image = try c.engineField("image", image)
        pdf = try c.engineField("pdf", pdf)
        document = try c.engineField("document", document)
        media = try c.engineField("media", media)
        archive = try c.engineField("archive", archive)
        output = try c.engineField("output", output)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("id", id)
        try c.engineField("name", name)
        try c.engineOptional("nameKey", nameKey, encoder)
        try c.engineField("targetFormat", targetFormat)
        try c.engineField("image", image)
        try c.engineField("pdf", pdf)
        try c.engineField("document", document)
        try c.engineField("media", media)
        try c.engineField("archive", archive)
        try c.engineField("output", output)
    }
}

extension ImageOptions: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["quality", "resize", "resizePercent", "longEdge", "dpi", "keepMetadata", "keepColorProfile", "grayscale", "background", "tiffCompression", "multiPageTiff", "webpLossless", "icoSizes"], getters: [])
        quality = try c.engineField("quality", quality)
        resize = try c.engineField("resize", resize)
        resizePercent = try c.engineField("resizePercent", resizePercent)
        longEdge = try c.engineField("longEdge", longEdge)
        dpi = try c.engineField("dpi", dpi)
        keepMetadata = try c.engineField("keepMetadata", keepMetadata)
        keepColorProfile = try c.engineField("keepColorProfile", keepColorProfile)
        grayscale = try c.engineField("grayscale", grayscale)
        background = try c.engineField("background", background)
        tiffCompression = try c.engineField("tiffCompression", tiffCompression)
        multiPageTiff = try c.engineField("multiPageTiff", multiPageTiff)
        webpLossless = try c.engineField("webpLossless", webpLossless)
        icoSizes = try c.engineField("icoSizes", icoSizes)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("quality", quality)
        try c.engineField("resize", resize)
        try c.engineField("resizePercent", resizePercent)
        try c.engineField("longEdge", longEdge)
        try c.engineOptional("dpi", dpi, encoder)
        try c.engineField("keepMetadata", keepMetadata)
        try c.engineField("keepColorProfile", keepColorProfile)
        try c.engineField("grayscale", grayscale)
        try c.engineField("background", background)
        try c.engineField("tiffCompression", tiffCompression)
        try c.engineField("multiPageTiff", multiPageTiff)
        try c.engineField("webpLossless", webpLossless)
        try c.engineField("icoSizes", icoSizes)
    }
}

extension PdfOptions: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["mergeIntoSingle", "pageSize", "marginMm", "renderDpi", "pageRange", "splitPages"], getters: [])
        mergeIntoSingle = try c.engineField("mergeIntoSingle", mergeIntoSingle)
        pageSize = try c.engineField("pageSize", pageSize)
        marginMm = try c.engineField("marginMm", marginMm)
        renderDpi = try c.engineField("renderDpi", renderDpi)
        pageRange = try c.engineField("pageRange", pageRange)
        splitPages = try c.engineField("splitPages", splitPages)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("mergeIntoSingle", mergeIntoSingle)
        try c.engineField("pageSize", pageSize)
        try c.engineField("marginMm", marginMm)
        try c.engineField("renderDpi", renderDpi)
        try c.engineField("pageRange", pageRange)
        try c.engineField("splitPages", splitPages)
    }
}

extension DocumentOptions: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["pdfA"], getters: [])
        pdfA = try c.engineField("pdfA", pdfA)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("pdfA", pdfA)
    }
}

extension MediaOptions: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["quality", "maxHeight", "audioBitrateKbps", "removeAudio", "audioChannels", "audioSampleRate", "wavFormat"], getters: [])
        quality = try c.engineField("quality", quality)
        maxHeight = try c.engineField("maxHeight", maxHeight)
        audioBitrateKbps = try c.engineField("audioBitrateKbps", audioBitrateKbps)
        removeAudio = try c.engineField("removeAudio", removeAudio)
        audioChannels = try c.engineField("audioChannels", audioChannels)
        audioSampleRate = try c.engineField("audioSampleRate", audioSampleRate)
        wavFormat = try c.engineField("wavFormat", wavFormat)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("quality", quality)
        try c.engineField("maxHeight", maxHeight)
        try c.engineField("audioBitrateKbps", audioBitrateKbps)
        try c.engineField("removeAudio", removeAudio)
        try c.engineField("audioChannels", audioChannels)
        try c.engineField("audioSampleRate", audioSampleRate)
        try c.engineField("wavFormat", wavFormat)
    }
}

extension ArchiveOptions: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["combineIntoOne", "level"], getters: [])
        combineIntoOne = try c.engineField("combineIntoOne", combineIntoOne)
        level = try c.engineField("level", level)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("combineIntoOne", combineIntoOne)
        try c.engineField("level", level)
    }
}

extension OutputRule: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["location", "subfolderName", "customFolder", "fileNamePattern", "renames", "conflict", "keepDates"], getters: [])
        location = try c.engineField("location", location)
        subfolderName = try c.engineField("subfolderName", subfolderName)
        customFolder = try c.engineField("customFolder", customFolder)
        fileNamePattern = try c.engineField("fileNamePattern", fileNamePattern)
        renames = try c.engineField("renames", renames)
        conflict = try c.engineField("conflict", conflict)
        keepDates = try c.engineField("keepDates", keepDates)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("location", location)
        try c.engineField("subfolderName", subfolderName)
        try c.engineField("customFolder", customFolder)
        try c.engineField("fileNamePattern", fileNamePattern)
        try c.engineField("renames", renames)
        try c.engineField("conflict", conflict)
        try c.engineField("keepDates", keepDates)
    }
}

extension RenameStep: Codable {
    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: EngineCodingKey.self)
        try c.engineValidate(decoder, fields: ["kind", "find", "replace"], getters: ["isBlank"])
        kind = try c.engineField("kind", kind)
        find = try c.engineField("find", find)
        replace = try c.engineField("replace", replace)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: EngineCodingKey.self)
        try c.engineField("kind", kind)
        try c.engineField("find", find)
        try c.engineField("replace", replace)
        try c.engineField("isBlank", isBlank)
    }
}
