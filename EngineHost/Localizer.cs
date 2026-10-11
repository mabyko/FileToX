using System.Globalization;
using System.Text.Json;
using Filee.Core.Localization;

namespace FileToX.EngineHost;

/// <summary>Filee's translations plus FileToX Japanese strings; falls back to English, then the key.</summary>
internal sealed class Localizer : ILocalizer
{
    public static readonly string[] Languages = ["en", "ko", "ja", "zh-CN"];

    private readonly Dictionary<string, string> _english = Load("en");
    private Dictionary<string, string> _current;

    public Localizer(string language)
    {
        Language = Resolve(language);
        _current = Language == "en" ? _english : Load(Language);
    }

    public string Language { get; private set; }

    public event EventHandler? LanguageChanged;

    public string this[string key] =>
        _current.TryGetValue(key, out var text) || _english.TryGetValue(key, out text) ? text : key;

    public bool Has(string key) => _current.ContainsKey(key) || _english.ContainsKey(key);

    public string Format(string key, params object[] args)
    {
        try
        {
            return string.Format(CultureInfo.InvariantCulture, this[key], args);
        }
        catch (FormatException)
        {
            return this[key];
        }
    }

    public void SetLanguage(string language)
    {
        var resolved = Resolve(language);
        if (resolved == Language)
            return;
        Language = resolved;
        _current = resolved == "en" ? _english : Load(resolved);
        LanguageChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Regional variants map to a shipped language; automatic and unknown codes use English.</summary>
    public static string Resolve(string? language)
    {
        language = language?.Trim();
        if (language?.Equals("ko", StringComparison.OrdinalIgnoreCase) == true || language?.StartsWith("ko-", StringComparison.OrdinalIgnoreCase) == true)
            return "ko";
        if (language?.Equals("ja", StringComparison.OrdinalIgnoreCase) == true || language?.Equals("ja-JP", StringComparison.OrdinalIgnoreCase) == true)
            return "ja";
        if (language?.Equals("zh", StringComparison.OrdinalIgnoreCase) == true || language?.StartsWith("zh-", StringComparison.OrdinalIgnoreCase) == true)
            return "zh-CN";
        return "en";
    }

    private static Dictionary<string, string> Load(string language)
    {
        using var stream = typeof(Localizer).Assembly.GetManifestResourceStream($"i18n.{language}.json")
                           ?? throw new InvalidOperationException($"Missing translations for {language}.");
        var values = JsonSerializer.Deserialize<Dictionary<string, string>>(stream,
                   new JsonSerializerOptions { ReadCommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true })
               ?? [];
        using var extras = typeof(Localizer).Assembly.GetManifestResourceStream($"i18n.{language}.extras.json");
        if (extras is not null)
            foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, string>>(extras) ?? [])
                values[pair.Key] = pair.Value;
        return values;
    }
}
