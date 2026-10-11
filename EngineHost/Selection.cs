using System.Text.Json.Nodes;
using Filee.Core.Conversion;
using Filee.Core.Formats;
using Filee.Core.Localization;
using Filee.Core.Presets;
using Filee.Core.Profiles;
using Filee.Engines.Infrastructure;

namespace FileToX.EngineHost;

/// <summary>
/// selection.resolve: the donut profile for dropped paths, each slice's availability (Filee.App's
/// PresetAvailability.Check, plus how many inputs it can run and which optional engine would help) and the same for
/// every target format.
/// </summary>
internal sealed class Selection(ConverterCatalog catalog, IReadOnlyList<ToolbarProfile> profiles, IReadOnlyList<Preset> library, Localizer loc)
{
    private sealed record Input(string Path, bool IsFolder, FileFormat? Format);

    public JsonNode Resolve(List<string> paths)
    {
        var inputs = new List<Input>();
        var rejected = new JsonArray();
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
                inputs.Add(new Input(path, true, null));
            else if (File.Exists(path))
                inputs.Add(new Input(path, false, FormatRegistry.Detect(path)));
            else
                rejected.Add(new JsonObject { ["path"] = path, ["reason"] = "not_found" });
        }

        // Drops deliver files; folders and unknown types go to the mixed-files donut (as an unknown extension).
        var profile = ProfileSelector.Select(profiles, inputs.Select(i => i.IsFolder ? i.Path + "/" : i.Path).ToList());
        var presetIds = profile?.PresetIds ?? [];
        var presets = library.GroupBy(p => p.Id).ToDictionary(g => g.Key, g => g.First());

        var planner = catalog.CreatePlanner();
        var slices = new JsonArray();
        foreach (var id in presetIds)
        {
            if (!presets.TryGetValue(id, out var preset))
                continue;
            var slice = Check(preset, inputs, planner);
            slice["presetId"] = preset.Id;
            slice["displayName"] = loc.DisplayName(preset);
            slice["targetFormat"] = preset.TargetFormat;
            slices.Add(slice);
        }

        var targets = new JsonArray();
        foreach (var format in FormatRegistry.Known.Where(f => f.Writable).Select(f => f.Id).Append(BuiltInData.SameAsSource))
        {
            var target = Check(new Preset { TargetFormat = format }, inputs, planner);
            var node = new JsonObject { ["formatId"] = format };
            foreach (var key in new[] { "available", "reasonKey", "reasonText", "runnableCount" })
                node[key] = target[key]?.DeepClone();
            targets.Add(node);
        }

        return new JsonObject
        {
            ["profileId"] = profile?.Id,
            ["formats"] = new JsonArray(inputs.Where(i => i.Format is not null).Select(i => i.Format!.Id).Distinct()
                .Select(f => (JsonNode)JsonValue.Create(f)).ToArray()),
            ["unknown"] = new JsonArray(inputs.Where(i => i.Format is null).Select(i => (JsonNode)JsonValue.Create(i.Path)).ToArray()),
            ["rejected"] = rejected,
            ["slices"] = slices,
            ["targets"] = targets,
        };
    }

    /// <summary>Availability of <paramref name="preset"/> for the inputs.</summary>
    private JsonObject Check(Preset preset, IReadOnlyList<Input> inputs, RoutePlanner planner)
    {
        // "Compress into one archive" packs everything as it is, folders and unknown types included.
        if (preset.Archive.CombineIntoOne
            && FormatRegistry.FindById(preset.TargetFormat) is { Category: FormatCategory.Archive } archive
            && archive.Id != FormatRegistry.Folder)
        {
            var can = catalog.All.OfType<IFileCombiner>().Any(c => c.CanCombineInto(archive.Id));
            return can ? Available(inputs.Count) : Unavailable("error.no_route", loc["error.no_route"]);
        }

        var files = inputs.Where(i => i.Format is not null).Select(i => i.Format!).ToList();
        if (files.Count == 0)
            return Unavailable("error.unsupported_source", loc["error.unsupported_source"]);

        var merge = preset.Pdf.MergeIntoSingle && preset.TargetFormat == "pdf";
        bool Runnable(FileFormat f, RoutePlanner p) =>
            (merge && f.Id == "pdf") || p.CanConvert(f.Id, preset.TargetFormat == BuiltInData.SameAsSource ? f.Id : preset.TargetFormat);

        // Routes depend only on the format: plan each once.
        var formats = files.Distinct().ToList();
        var runnable = formats.Where(f => Runnable(f, planner)).ToHashSet();
        var count = files.Count(runnable.Contains);
        if (count > 0)
            return Available(count);

        // Like EngineDownloadService.PackageEnabling: the first missing optional engine that would make it possible.
        foreach (var package in EngineDownloads.Packages)
        {
            if (package.ConverterIds.All(IsAvailable))
                continue;
            var withPackage = catalog.CreatePlanner(package.ConverterIds);
            if (!formats.Any(f => Runnable(f, withPackage)))
                continue;
            var name = loc[$"engines.package.{package.Id}.name"];
            var result = Unavailable("engine.reason.needs_package", loc.Format("engine.reason.needs_package", name));
            var canDownload = EngineDownloads.CanDownload(package);
            result["needsPackage"] = package.Id;
            result["canDownload"] = canDownload;
            if (!canDownload)
            {
                var specific = $"engines.guidance.macos.{package.Id}";
                result["guidanceKey"] = loc.Has(specific) ? specific : "engines.guidance.macos";
            }
            return result;
        }
        return Unavailable("error.no_route", loc["error.no_route"]);
    }

    private bool IsAvailable(string converterId) =>
        catalog.All.FirstOrDefault(c => c.Id == converterId) is { } c && catalog.StatusOf(c).IsAvailable;

    private static JsonObject Available(int count) => new()
    {
        ["available"] = count > 0,
        ["reasonKey"] = null,
        ["reasonText"] = null,
        ["runnableCount"] = count,
        ["needsPackage"] = null,
        ["canDownload"] = false,
        ["guidanceKey"] = null,
    };

    private static JsonObject Unavailable(string key, string text) => new()
    {
        ["available"] = false,
        ["reasonKey"] = key,
        ["reasonText"] = text,
        ["runnableCount"] = 0,
        ["needsPackage"] = null,
        ["canDownload"] = false,
        ["guidanceKey"] = null,
    };
}
