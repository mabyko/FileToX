using Filee.Core.Conversion;
using Filee.Core.Formats;
using Filee.Core.Platform;
using Filee.Core.Presets;
using Filee.Core.Profiles;
using Filee.Core.Settings;

namespace FileToX.EngineHost;

/// <summary>Checks what the app sends, with the ranges of Filee's own editors.</summary>
internal static class Validation
{
    public const int MaxPaths = 10_000;

    /// <summary>Absolute POSIX paths without NUL, de-duplicated in order.</summary>
    public static List<string> Paths(IReadOnlyList<string> paths)
    {
        if (paths.Count == 0)
            throw Invalid("paths is empty.");
        if (paths.Count > MaxPaths)
            throw Invalid($"At most {MaxPaths} paths are accepted.");
        var seen = new HashSet<string>(FileSystemPaths.Comparer);
        var result = new List<string>();
        foreach (var path in paths)
        {
            if (path.Length == 0 || path[0] != '/' || path.Contains('\0'))
                throw Invalid($"Not an absolute path: {path}");
            if (seen.Add(path))
                result.Add(path);
        }
        return result;
    }

    public static bool IsTarget(string format) =>
        format == BuiltInData.SameAsSource || format == FormatRegistry.Folder
        || FormatRegistry.FindById(format) is { Writable: true };

    public static void Preset(Preset p)
    {
        if (string.IsNullOrWhiteSpace(p.Id))
            throw Invalid("A preset needs an id.");
        if (!IsTarget(p.TargetFormat))
            throw Invalid($"Preset {p.Id}: {p.TargetFormat} is not a target format.");
        Range(p.Image.Quality, 1, 100, "image.quality");
        Range(p.Image.ResizePercent, 1, 1000, "image.resizePercent");
        Range(p.Image.LongEdge, 16, 20000, "image.longEdge");
        if (p.Image.Dpi is { } dpi)
            Range(dpi, 36, 2400, "image.dpi");
        if (p.Image.IcoSizes.Any(s => s is < 16 or > 256))
            throw Invalid($"Preset {p.Id}: image.icoSizes must be 16-256.");
        Range(p.Pdf.RenderDpi, 36, 1200, "pdf.renderDpi");
        if (p.Pdf.MarginMm is < 0 or > 100 || double.IsNaN(p.Pdf.MarginMm))
            throw Invalid($"Preset {p.Id}: pdf.marginMm must be 0-100.");
        if (p.Pdf.PageRange.Any(c => !(char.IsAsciiDigit(c) || c is ',' or '-' or ' ')))
            throw Invalid($"Preset {p.Id}: pdf.pageRange may only hold digits, commas, dashes and spaces.");
        Range(p.Media.MaxHeight, 0, 10000, "media.maxHeight");
        Range(p.Media.AudioBitrateKbps, 0, 2000, "media.audioBitrateKbps");
        Range(p.Media.AudioChannels, 0, 2, "media.audioChannels");
        if (p.Media.AudioSampleRate != 0)
            Range(p.Media.AudioSampleRate, 8000, 48000, "media.audioSampleRate");
        Output(p.Output, $"Preset {p.Id}");

        void Range(int value, int min, int max, string name)
        {
            if (value < min || value > max)
                throw Invalid($"Preset {p.Id}: {name} must be {min}-{max}.");
        }
    }

    public static void Output(OutputRule rule, string owner)
    {
        if (!string.IsNullOrEmpty(rule.CustomFolder) && !Path.IsPathFullyQualified(rule.CustomFolder))
            throw Invalid($"{owner}: output.customFolder must be an absolute path.");
        Renames(rule.Renames, owner);
    }

    public static void Renames(IEnumerable<RenameStep> steps, string owner)
    {
        foreach (var step in steps.Where(s => s.Kind == RenameKind.Regex))
            if (OutputPathResolver.RenameError(step.Find) is { } error)
                throw Invalid($"{owner}: invalid regular expression: {error}");
    }

    public static void Library(List<Preset> presets, List<ToolbarProfile> profiles)
    {
        foreach (var preset in presets)
            Preset(preset);
        Unique(presets.Select(p => p.Id), "preset");
        Unique(profiles.Select(p => p.Id), "profile");
        foreach (var profile in profiles)
        {
            if (string.IsNullOrWhiteSpace(profile.Id))
                throw Invalid("A profile needs an id.");
            if (profile.PresetIds.Count > ToolbarProfile.MaxSlices)
                throw Invalid($"Profile {profile.Id}: at most {ToolbarProfile.MaxSlices} presets.");
        }
    }

    public static void Settings(AppSettings s)
    {
        if (s.SchemaVersion != AppSettings.CurrentSchemaVersion)
            throw Invalid($"settings.schemaVersion must be {AppSettings.CurrentSchemaVersion}.");
        if (s.Language != "auto" && !Localizer.Languages.Contains(s.Language))
            throw Invalid($"Unknown language {s.Language}.");
        if (s.DefaultOutput.Location == OutputLocation.Default)
            throw Invalid("settings.defaultOutput.location can't be default.");
        if (!string.IsNullOrEmpty(s.DefaultOutput.CustomFolder) && !Path.IsPathFullyQualified(s.DefaultOutput.CustomFolder))
            throw Invalid("settings.defaultOutput.customFolder must be an absolute path.");
        foreach (var rule in s.WatchFolders)
        {
            if (!string.IsNullOrEmpty(rule.Folder) && !Path.IsPathFullyQualified(rule.Folder))
                throw Invalid("A watch folder must be an absolute path.");
            if (!string.IsNullOrEmpty(rule.OutputFolder) && !Path.IsPathFullyQualified(rule.OutputFolder))
                throw Invalid("A watch folder's output folder must be an absolute path.");
            Renames(rule.Renames, "Watch folder");
        }
        // A blank entry is "not set" (the app's field was cleared): Host.SaveSettings drops it.
        foreach (var (_, program) in s.EngineOwnCopies.Where(e => !string.IsNullOrWhiteSpace(e.Value)))
            if (!Path.IsPathFullyQualified(program))
                throw Invalid("settings.engineOwnCopies must hold absolute paths.");
    }

    private static void Unique(IEnumerable<string> ids, string what)
    {
        var seen = new HashSet<string>();
        foreach (var id in ids)
            if (!seen.Add(id))
                throw Invalid($"Duplicate {what} id {id}.");
    }

    private static WireException Invalid(string message) => new("invalid_input", message);
}
