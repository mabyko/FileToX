import Foundation

final class Selection {
    private struct Input { let path: String; let isFolder: Bool; let format: FileFormat? }
    private let catalog: ConverterCatalog, profiles: [ToolbarProfile], library: [Preset], loc: Localizer
    init(_ catalog: ConverterCatalog, _ profiles: [ToolbarProfile], _ library: [Preset], _ loc: Localizer) { self.catalog = catalog; self.profiles = profiles; self.library = library; self.loc = loc }
    func resolve(_ paths: [String]) -> [String: Any] {
        var inputs: [Input] = [], rejected: [[String: String]] = []
        for path in paths {
            if FileManager.default.directoryExists(path) { inputs.append(Input(path: path, isFolder: true, format: nil)) }
            else if FileManager.default.fileExists(path) { inputs.append(Input(path: path, isFolder: false, format: FormatRegistry.detect(path))) }
            else { rejected.append(["path": path, "reason": "not_found"]) }
        }
        let profile = ProfileSelector.select(profiles, inputs.map { $0.isFolder ? $0.path + "/" : $0.path })
        var seen = Set<String>(); let presets = library.filter { seen.insert($0.id).inserted }
        let planner = catalog.createPlanner()
        func slice(_ preset: Preset) -> [String: Any] {
            var s = check(preset, inputs, planner); s["presetId"] = preset.id; s["displayName"] = loc.displayName(preset); s["targetFormat"] = preset.targetFormat; return s
        }
        let slices = (profile?.presetIds ?? []).compactMap { id in presets.first { $0.id == id }.map(slice) }
        let options = presets.map(slice)
        let tools = presets.enumerated().filter { isToolFor($0.element, inputs) }.prefix(12).map { options[$0.offset] }
        let targets = (FormatRegistry.known.filter(\.writable).map(\.id) + [BuiltInData.sameAsSource]).map { format -> [String: Any] in
            var p = Preset(); p.targetFormat = format; let s = check(p, inputs, planner)
            return ["formatId": format, "available": s["available"]!, "reasonKey": s["reasonKey"]!, "reasonText": s["reasonText"]!, "runnableCount": s["runnableCount"]!]
        }
        var formats = Set<String>()
        return ["profileId": profile?.id as Any? ?? NSNull(), "formats": inputs.compactMap(\.format).map(\.id).filter { formats.insert($0).inserted }, "unknown": inputs.filter { $0.format == nil }.map(\.path), "rejected": rejected, "slices": slices, "tools": tools, "presetOptions": options, "targets": targets]
    }
    private func isToolFor(_ p: Preset, _ inputs: [Input]) -> Bool {
        if inputs.isEmpty { return false }
        let target = FormatRegistry.find(id: p.targetFormat)?.category
        if p.archive.combineIntoOne && target == .archive { return true }
        func has(_ categories: [FormatCategory]) -> Bool { inputs.contains { $0.format.map { categories.contains($0.category) } == true } }
        if p.targetFormat == FormatRegistry.folder { return has([.archive]) }
        if target == .pdf && (p.pdf.mergeIntoSingle || p.pdf.splitPages) { return has(p.pdf.splitPages ? [.pdf] : [.pdf, .image, .document, .text, .hwp, .presentation, .spreadsheet]) }
        if (p.targetFormat == BuiltInData.sameAsSource || target == .image) && has([.image, .vector, .pdf]) {
            return p.targetFormat == BuiltInData.sameAsSource || p.image.resize != .none || p.image.grayscale || p.image.dpi != nil || !p.image.keepMetadata || p.image.multiPageTiff || (p.image.quality < 90 && !p.id.hasPrefix("to-"))
        }
        return (target == .video || target == .audio) && has([.video, .audio]) && (p.media.maxHeight > 0 || p.media.audioBitrateKbps > 0 || p.media.removeAudio || p.media.audioChannels > 0 || p.media.audioSampleRate > 0 || p.media.quality != .balanced)
    }
    private func check(_ preset: Preset, _ inputs: [Input], _ planner: RoutePlanner) -> [String: Any] {
        if preset.archive.combineIntoOne, let archive = FormatRegistry.find(id: preset.targetFormat), archive.category == .archive && archive.id != FormatRegistry.folder {
            return catalog.all.compactMap { $0 as? FileCombiner }.contains { $0.canCombine(into: archive.id) } ? available(inputs.count) : unavailable("error.no_route", loc["error.no_route"])
        }
        let files = inputs.compactMap(\.format)
        if files.isEmpty { return unavailable("error.unsupported_source", loc["error.unsupported_source"]) }
        let merge = preset.pdf.mergeIntoSingle && preset.targetFormat == "pdf"
        func runnable(_ f: FileFormat, _ p: RoutePlanner) -> Bool { (merge && f.id == "pdf") || p.canConvert(f.id, preset.targetFormat == BuiltInData.sameAsSource ? f.id : preset.targetFormat) }
        var seen = Set<String>(); let formats = files.filter { seen.insert($0.id).inserted }
        let can = Set(formats.filter { runnable($0, planner) }.map(\.id)), count = files.filter { can.contains($0.id) }.count
        if count > 0 { return available(count) }
        for package in EngineDownloads.packages {
            if package.converterIds.allSatisfy({ id in catalog.all.first { $0.id == id }.map { catalog.statusOf($0).isAvailable } == true }) { continue }
            let withPackage = catalog.createPlanner(package.converterIds)
            if !formats.contains(where: { runnable($0, withPackage) }) { continue }
            let name = loc["engines.package.\(package.id).name"]
            var result = unavailable("engine.reason.needs_package", loc.format("engine.reason.needs_package", name))
            let canDownload = EngineDownloads.canDownload(package)
            result["needsPackage"] = package.id; result["canDownload"] = canDownload
            if !canDownload { let key = "engines.guidance.macos.\(package.id)"; result["guidanceKey"] = loc.has(key) ? key : "engines.guidance.macos" }
            return result
        }
        return unavailable("error.no_route", loc["error.no_route"])
    }
    private func available(_ count: Int) -> [String: Any] { ["available": count > 0, "reasonKey": NSNull(), "reasonText": NSNull(), "runnableCount": count, "needsPackage": NSNull(), "canDownload": false, "guidanceKey": NSNull()] }
    private func unavailable(_ key: String, _ text: String) -> [String: Any] { ["available": false, "reasonKey": key, "reasonText": text, "runnableCount": 0, "needsPackage": NSNull(), "canDownload": false, "guidanceKey": NSNull()] }
}
