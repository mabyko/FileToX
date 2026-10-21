using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using Filee.Core.Conversion;
using Filee.Core.Presets;
using Filee.Core.Profiles;
using Filee.Core.Settings;

namespace FileToX.EngineHost;

/// <summary>
/// <c>FileToXEngine --selftest</c>: checks the host without test frameworks. The protocol checks start this executable
/// again as a real host (<c>--fake-engines</c>) on a temporary data folder.
/// </summary>
internal static class SelfTest
{
    private static int _failures;

    /// <summary>Engines of <c>--fake-engines</c>: instant txt → md / txt → txt that also write to stdout natively.</summary>
    public static IReadOnlyList<IConverter> FakeEngines() => [new NoisyConverter()];

    private sealed class NoisyConverter : IConverter
    {
        public string Id => "fake";
        public string DisplayName => "Fake";
        public IReadOnlyList<ConversionEdge> Edges { get; } = [new("txt", "md"), new("txt", "txt")];
        public int MaxParallelism => 0;
        public EngineStatus GetStatus() => EngineStatus.Available(version: "1");

        public Task<IReadOnlyList<string>> ConvertAsync(ConversionStep step, IProgress<double>? progress, CancellationToken cancellationToken)
        {
            // Both must end up on stderr, never in the protocol.
            var noise = Encoding.UTF8.GetBytes("native-noise-without-newline");
            Native.write(1, noise, noise.Length);
            Console.Write("managed-noise");
            var output = step.Output.Allocate(step.To);
            if (output is null)
                return Task.FromResult<IReadOnlyList<string>>([]);
            File.WriteAllText(output, "converted " + Path.GetFileName(step.InputPath));
            progress?.Report(1);
            return Task.FromResult<IReadOnlyList<string>>([output]);
        }
    }

    public static async Task<int> RunAsync()
    {
        Section("localizer", Localization);
        Section("FileToX defaults", SettingsDefaults);
        Section("strict json", StrictJson);
        Section("validation", ValidationRanges);
        await SectionAsync("protocol", Protocol);
        await SectionAsync("language settings protocol", LanguageProtocol);
        Console.WriteLine(_failures == 0 ? "SELFTEST PASSED" : $"SELFTEST FAILED ({_failures})");
        return _failures == 0 ? 0 : 1;
    }

    private static void Localization()
    {
        Check(new Localizer("ko")["error.no_route"] != new Localizer("en")["error.no_route"], "ko differs from en");
        Check(new Localizer("zh-CN").Language == "zh-CN" && new Localizer("zh-TW").Language == "zh-CN", "zh resolves to zh-CN");
        Check(new Localizer("fr").Language == "en", "unknown language falls back to en");
        Check(Localizer.Resolve("auto") == "en" && Localizer.Resolve(null) == "en" && Localizer.Resolve(" ") == "en", "automatic and blank language default to en");
        var japanese = new Localizer("ja-JP");
        Check(japanese.Language == "ja" && japanese["preset.half_size"] == "サイズを半分に", "ja-JP uses Japanese preset names");
        Check(japanese["presets.same_as_source"] == "元のファイルと同じ形式", "same-format preset is Japanese");
        Check(japanese["app.tagline"] == new Localizer("en")["app.tagline"], "unused Avalonia strings fall back to English");
        Check(new Localizer("ja-unknown").Language == "en" && new Localizer("jaunknown").Language == "en", "unknown Japanese-like codes fall back to English");
        using (var englishStream = typeof(Localizer).Assembly.GetManifestResourceStream("i18n.en.json")!)
        using (var japaneseStream = typeof(Localizer).Assembly.GetManifestResourceStream("i18n.ja.json")!)
        {
            var englishKeys = JsonNode.Parse(englishStream)!.AsObject();
            var japaneseKeys = JsonNode.Parse(japaneseStream)!.AsObject();
            string[] prefixes = ["error.", "engine.", "engines.", "preset.", "profile.", "format.", "donut.", "toast.", "common."];
            Check(englishKeys.All(pair => !prefixes.Any(pair.Key.StartsWith) && pair.Key != "presets.same_as_source" || japaneseKeys.ContainsKey(pair.Key)), "Japanese covers every helper translation key");
            Check(japaneseKeys.All(pair => !englishKeys.ContainsKey(pair.Key) ||
                System.Text.RegularExpressions.Regex.Matches(pair.Value!.GetValue<string>(), @"\{\d+[^}]*\}").Select(m => m.Value).Order().SequenceEqual(
                    System.Text.RegularExpressions.Regex.Matches(englishKeys[pair.Key]!.GetValue<string>(), @"\{\d+[^}]*\}").Select(m => m.Value).Order())), "Japanese format placeholders match English");
        }
        Check(new Localizer("ko")["no.such.key"] == "no.such.key", "missing key returns the key");
        Check(new Localizer("en").Format("engine.reason.needs_package", "Pandoc").Contains("Pandoc"), "format arguments");
        var loc = new Localizer("ko");
        Check(Filee.Core.Localization.LocalizerExtensions.DisplayName(loc, BuiltInData.CreatePresets()[0]) is { Length: > 0 } n && !n.StartsWith("preset."),
            "built-in preset names translate");
    }

    private static void SettingsDefaults()
    {
        var root = Path.Combine(Path.GetTempPath(), "ftx-defaults-" + Guid.NewGuid().ToString("N")[..8]);
        try
        {
            var store = new UserDataStore(root);
            store.Load();
            Program.ApplyDefaults(store);
            Check(store.Settings.Language == "en" && store.Settings.Theme.Accent == "#3478F6", "fresh FileToX defaults are English and blue");
            store.Settings.Language = "ko";
            store.Settings.Theme.Accent = "#7F77DD";
            store.SaveSettings();
            store.Load();
            Program.ApplyDefaults(store);
            Check(store.Settings.Language == "ko" && store.Settings.Theme.Accent == "#7F77DD", "later custom purple and explicit Korean survive restart");
            store.Settings.Language = "auto";
            store.Settings.Theme.Accent = "#C4603A";
            store.SaveSettings();
            store.Load();
            Program.ApplyDefaults(store);
            Check(store.Settings.Language == "en" && store.Settings.Theme.Accent == "#C4603A", "automatic language migrates without changing custom accent");
            var old = new UserDataStore(Path.Combine(root, "old"));
            old.Load();
            old.Settings.Language = "ko";
            old.SaveSettings();
            Program.ApplyDefaults(old);
            Check(old.Settings.Language == "ko" && old.Settings.Theme.Accent == "#3478F6", "first migration updates old default purple and preserves explicit Korean");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static void StrictJson()
    {
        // Every built-in object goes through the wire unchanged.
        var presets = WireJson.ToNode(BuiltInData.CreatePresets())!;
        var back = WireJson.ToNode(WireJson.ReadStrict<List<Preset>>(presets, "presets"))!;
        Check(JsonNode.DeepEquals(presets, back), "built-in presets round-trip");
        var profiles = WireJson.ToNode(BuiltInData.CreateProfiles())!;
        Check(JsonNode.DeepEquals(profiles, WireJson.ToNode(WireJson.ReadStrict<List<ToolbarProfile>>(profiles, "profiles"))), "profiles round-trip");
        var settings = new AppSettings { WatchFolders = [new() { Folder = "/tmp/w", Renames = [new() { Kind = RenameKind.Regex, Find = "a", Replace = "b" }] }] };
        var settingsNode = WireJson.ToNode(settings)!;
        Check(JsonNode.DeepEquals(settingsNode, WireJson.ToNode(WireJson.ReadStrict<AppSettings>(settingsNode, "settings"))), "settings round-trip");

        var one = presets[0]!.DeepClone();
        Check(one["image"]!["dpi"] is null && one["image"]!.AsObject().ContainsKey("dpi"), "dpi null is written");
        Check(WireJson.ReadStrict<Preset>(one, "preset").Image.Dpi is null, "dpi null is read");
        one["image"]!["icoSizes"] = new JsonArray(16, 256, 32);
        Check(WireJson.ReadStrict<Preset>(one, "preset").Image.IcoSizes.SequenceEqual([16, 256, 32]), "array order kept");

        Rejects(n => n.AsObject().Remove("targetFormat"), "missing property");
        Rejects(n => n["image"]!.AsObject().Remove("quality"), "missing nested property");
        Rejects(n => n["surprise"] = 1, "unknown property");
        Rejects(n => n["image"]!["surprise"] = 1, "unknown nested property");
        Rejects(n => n["image"] = null, "null object");
        Rejects(n => n["name"] = null, "null string");
        Rejects(n => n["output"]!["conflict"] = 1, "enum as number");
        Rejects(n => n["output"]!["conflict"] = "explode", "unknown enum name");
        Rejects(n => n["output"]!["renames"] = new JsonArray((JsonNode?)null), "null list element");
        Rejects(n => n["image"]!["quality"] = "90", "number as string");

        void Rejects(Action<JsonNode> change, string what)
        {
            var node = presets[0]!.DeepClone();
            change(node);
            try
            {
                WireJson.ReadStrict<Preset>(node, "preset");
                Fail($"accepted {what}");
            }
            catch (WireException ex) when (ex.Code == "bad_request")
            {
                Pass($"rejects {what}");
            }
        }
    }

    private static void ValidationRanges()
    {
        Validation.Library(BuiltInData.CreatePresets(), BuiltInData.CreateProfiles());
        Pass("built-in library is valid");
        Validation.Settings(new AppSettings());
        Validation.Settings(new AppSettings { Language = "ja" });
        Pass("default settings are valid");
        Invalid(() => Validation.Preset(new Preset { TargetFormat = "heic" }), "read-only target");
        Invalid(() => Validation.Preset(new Preset { Image = { Quality = 0 } }), "quality 0");
        Invalid(() => Validation.Preset(new Preset { Image = { Dpi = 10 } }), "dpi 10");
        Invalid(() => Validation.Preset(new Preset { Output = { CustomFolder = "relative" } }), "relative custom folder");
        Invalid(() => Validation.Preset(new Preset { Output = { Renames = [new() { Kind = RenameKind.Regex, Find = "(" }] } }), "bad regex");
        Invalid(() => Validation.Paths(["relative.txt"]), "relative path");
        Invalid(() => Validation.Paths(["/a\0b"]), "NUL in path");
        Check(Validation.Paths(["/a", "/b", "/a"]).SequenceEqual(["/a", "/b"]), "paths de-duplicated in order");
        Check(Validation.IsTarget("folder") && Validation.IsTarget("*") && Validation.IsTarget("pdf"), "virtual targets");

        static void Invalid(Action action, string what)
        {
            try
            {
                action();
                Fail($"accepted {what}");
            }
            catch (WireException ex) when (ex.Code == "invalid_input")
            {
                Pass($"rejects {what}");
            }
        }
    }

    private static async Task LanguageProtocol()
    {
        var root = Path.Combine(Path.GetTempPath(), "ftx-language-selftest-" + Guid.NewGuid().ToString("N")[..8]);
        var data = Path.Combine(root, "core");
        var png = Path.Combine(root, "image.png");
        Directory.CreateDirectory(root);
        File.WriteAllText(png, "selection-only fixture");
        JsonNode? expectedPresets = null, expectedProfiles = null;
        try
        {
            await using (var host = await Child.StartAsync(data, root, language: null))
            {
                await host.NextEventAsync("hello");
                var library = await host.CallAsync("library.get", new JsonObject());
                Check(library["settings"]!["language"]!.GetValue<string>() == "en" && library["settings"]!["theme"]!["accent"]!.GetValue<string>() == "#3478F6", "live fresh defaults are English and blue");
                var settings = library["settings"]!.DeepClone();
                settings["language"] = "ja";
                settings["theme"]!["accent"] = "#C4603A";
                library = await host.CallAsync("settings.save", new JsonObject { ["baseRevision"] = library["revision"]!.GetValue<int>(), ["settings"] = settings });
                var selection = await host.CallAsync("selection.resolve", new JsonObject { ["paths"] = new JsonArray(png) });
                Check(selection["slices"]!.AsArray().Any(s => s!["displayName"]?.GetValue<string>() == "サイズを半分に"), "live language save updates Japanese slices without restart");
                var tools = selection["tools"]!.AsArray();
                Check(tools.Any(s => s!["presetId"]?.GetValue<string>() == "half-size") &&
                      tools.Any(s => s!["presetId"]?.GetValue<string>() == "grayscale"), "image tools include resize and grayscale");
                Check(tools.Count <= 12 && !tools.Any(s => s!["presetId"]?.GetValue<string>() == "mp4-720"), "image tools are bounded and exclude media-only tools");
                var presetOptions = selection["presetOptions"]!.AsArray();
                Check(presetOptions.Count == library["presets"]!.AsArray().Count &&
                      presetOptions.Any(s => s!["presetId"]?.GetValue<string>() == "to-mp4"), "all presets carry availability for custom tool menus");
                Check(tools.First(s => s!["presetId"]?.GetValue<string>() == "half-size")!["reasonKey"] is not null,
                    "unavailable tools retain engine reasons");
                var presets = library["presets"]!.DeepClone();
                presets.AsArray().First(p => p!["id"]!.GetValue<string>() == "half-size")!["name"] = "My preset 이름 テスト";
                var profiles = library["profiles"]!.DeepClone();
                profiles[0]!["name"] = "My profile プロファイル";
                library = await host.CallAsync("library.save", new JsonObject { ["baseRevision"] = library["revision"]!.GetValue<int>(), ["presets"] = presets, ["profiles"] = profiles });
                expectedPresets = library["presets"]!.DeepClone();
                expectedProfiles = library["profiles"]!.DeepClone();
                foreach (var language in new[] { "ko", "en", "ja" })
                {
                    settings = library["settings"]!.DeepClone();
                    settings["language"] = language;
                    library = await host.CallAsync("settings.save", new JsonObject { ["baseRevision"] = library["revision"]!.GetValue<int>(), ["settings"] = settings });
                    var catalog = await host.CallAsync("catalog.get", new JsonObject());
                    Check(catalog["formats"]!.AsArray().First(f => f!["id"]!.GetValue<string>() == "folder")!["displayName"]!.GetValue<string>() == new Localizer(language)["format.folder"], $"catalog folder updates to {language}");
                    Check(JsonNode.DeepEquals(expectedPresets, library["presets"]) && JsonNode.DeepEquals(expectedProfiles, library["profiles"]), $"{language} settings save preserves raw names and built-in keys");
                }
                selection = await host.CallAsync("selection.resolve", new JsonObject { ["paths"] = new JsonArray(png) });
                Check(selection["slices"]!.AsArray().First(s => s!["presetId"]!.GetValue<string>() == "half-size")!["displayName"]!.GetValue<string>() == "My preset 이름 テスト", "custom preset display name is never translated");
            }
            await using (var restarted = await Child.StartAsync(data, root, language: null))
            {
                await restarted.NextEventAsync("hello");
                var persisted = await restarted.CallAsync("library.get", new JsonObject());
                Check(persisted["settings"]!["language"]!.GetValue<string>() == "ja" && persisted["settings"]!["theme"]!["accent"]!.GetValue<string>() == "#C4603A", "language and custom accent survive a live host restart");
                Check(JsonNode.DeepEquals(expectedPresets, persisted["presets"]) && JsonNode.DeepEquals(expectedProfiles, persisted["profiles"]), "restart preserves raw library names and keys");
            }
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, true);
        }
    }

    private static async Task Protocol()
    {
        var root = Path.Combine(Path.GetTempPath(), "ftx-selftest-" + Guid.NewGuid().ToString("N")[..8]);
        var data = Path.Combine(root, "core");
        var files = Directory.CreateDirectory(Path.Combine(root, "files")).FullName;
        try
        {
            // A staging folder left by a crash is removed on start; anything else named in the journal is not.
            Directory.CreateDirectory(data);
            var leftover = Directory.CreateDirectory(Path.Combine(files, ".filee-out-0123abcd")).FullName;
            var bystander = Directory.CreateDirectory(Path.Combine(files, "keep-me")).FullName;
            File.WriteAllLines(Path.Combine(data, "staging.journal"), [leftover, bystander]);

            await using var host = await Child.StartAsync(data, root);
            var hello = await host.NextEventAsync("hello");
            Check(hello?["data"]?["protocol"]?.GetValue<int>() == 1 && hello["data"]!["dataDir"]!.GetValue<string>() == data, "hello");
            Check(!Directory.Exists(leftover) && Directory.Exists(bystander), "journal cleanup");

            await using (var second = await Child.StartAsync(data, root))
            {
                var fatal = await second.NextEventAsync("fatal");
                Check(fatal?["data"]?["code"]?.GetValue<string>() == "data_locked", "second host: data_locked");
            }

            Check(await host.ErrorCodeAsync(null, "{not json") == "bad_request", "bad json");
            Check(await host.ErrorCodeAsync("u", """{"v":1,"id":"u","method":"nope","params":{}}""") == "unknown_method", "unknown method");
            Check(await host.ErrorCodeAsync("p", """{"v":1,"id":"p","method":"catalog.get"}""") == "bad_request", "missing params");
            Check(await host.ErrorCodeAsync("w", """{"v":2,"id":"w","method":"catalog.get","params":{}}""") == "bad_request", "wrong version");
            Check(await host.ErrorCodeAsync(null, "{\"pad\":\"" + new string('x', WireJson.MaxLine + 10) + "\"}") == "bad_request", "line over 4 MiB");

            var catalog = await host.CallAsync("catalog.get", new JsonObject());
            Check(catalog["formats"]!.AsArray().Count == 172, "catalog has 171 formats + folder");
            Check(catalog["engines"]!.AsArray().Any(e => e!["id"]!.GetValue<string>() == "fake"), "catalog lists engines");

            var a = Path.Combine(files, "a.txt");
            File.WriteAllText(a, "original");
            var unknown = Path.Combine(files, "x.unknownext");
            File.WriteAllText(unknown, "?");
            var selection = await host.CallAsync("selection.resolve", new JsonObject
            {
                ["paths"] = new JsonArray(a, unknown, Path.Combine(files, "missing.txt"), bystander),
            });
            Check(selection["formats"]!.ToJsonString() == "[\"txt\"]", "resolve formats");
            Check(selection["unknown"]!.AsArray().Count == 2 && selection["rejected"]!.AsArray().Count == 1, "resolve unknown and rejected");
            var md = selection["targets"]!.AsArray().First(t => t!["formatId"]!.GetValue<string>() == "md")!;
            Check(md["available"]!.GetValue<bool>() && md["runnableCount"]!.GetValue<int>() == 1, "target md runnable");
            var png = selection["targets"]!.AsArray().First(t => t!["formatId"]!.GetValue<string>() == "png")!;
            Check(!png["available"]!.GetValue<bool>() && png["reasonKey"] is not null, "target png has a reason");
            var zip = selection["slices"]!.AsArray().FirstOrDefault(t => t!["presetId"]!.GetValue<string>() == "zip-all");
            Check(zip is null || zip["runnableCount"]!.GetValue<int>() == 0, "zip-all counts nothing without an archive engine");
            Check(selection["tools"]!.AsArray().Any(t => t!["presetId"]?.GetValue<string>() == "zip-all"),
                "mixed and unknown files still offer archive tools");

            // Library round trip and revisions.
            var library = await host.CallAsync("library.get", new JsonObject());
            var saved = await host.CallAsync("library.save", new JsonObject
            {
                ["baseRevision"] = library["revision"]!.GetValue<int>(),
                ["presets"] = library["presets"]!.DeepClone(),
                ["profiles"] = library["profiles"]!.DeepClone(),
            });
            Check(JsonNode.DeepEquals(saved["presets"], library["presets"]) && saved["revision"]!.GetValue<int>() == 2, "library.save keeps everything");
            Check(await host.ErrorCodeAsync("c", new JsonObject
            {
                ["v"] = 1, ["id"] = "c", ["method"] = "settings.save",
                ["params"] = new JsonObject { ["baseRevision"] = 1, ["settings"] = library["settings"]!.DeepClone() },
            }.ToJsonString()) == "conflict", "stale revision conflicts");

            // A cleared engine path field arrives as "" and means "not set".
            var withBlank = library["settings"]!.DeepClone();
            withBlank["engineOwnCopies"] = new JsonObject { ["pandoc"] = "" };
            var blankSaved = await host.CallAsync("settings.save", new JsonObject { ["baseRevision"] = 2, ["settings"] = withBlank });
            Check(blankSaved["settings"]!["engineOwnCopies"]!.AsObject().Count == 0 && blankSaved["revision"]!.GetValue<int>() == 3,
                "settings.save drops blank engine paths");

            // Overwrite through a linked folder must not replace the source.
            var alias = Path.Combine(root, "alias");
            Directory.CreateSymbolicLink(alias, files);
            var preset = library["presets"]![0]!.DeepClone();
            preset["targetFormat"] = "*";
            preset["output"]!["location"] = "customFolder";
            preset["output"]!["customFolder"] = alias;
            preset["output"]!["conflict"] = "overwrite";
            var job = await host.StartJobAsync(new JsonObject { ["paths"] = new JsonArray(a), ["preset"] = preset });
            var finished = await host.FinishedAsync(job);
            var file = finished["data"]!["files"]![0]!;
            Check(file["errorKey"]?.GetValue<string>() == "error.output_is_source" && File.ReadAllText(a) == "original",
                "overwrite never replaces the source");
            Check(finished["data"]!["retrySources"]!.AsArray().Count == 1, "failed file offered for retry");

            // 1,000 instant jobs: response first, then updates, then exactly one finished each.
            const int count = 1000;
            var ids = new List<string>();
            int start;
            lock (host.Lines) start = host.Lines.Count;
            for (var i = 0; i < count; i++)
                host.Send(new JsonObject
                {
                    ["v"] = 1, ["id"] = "j" + i, ["method"] = "job.start",
                    ["params"] = new JsonObject { ["paths"] = new JsonArray(a), ["targetFormat"] = "md" },
                }.ToJsonString());
            await host.WaitAsync(() => host.Lines.Skip(start).Count(l => l["event"]?.GetValue<string>() == "job.finished") >= count,
                TimeSpan.FromSeconds(120));
            List<JsonObject> lines;
            lock (host.Lines) lines = host.Lines.Skip(start).ToList();
            var ok = true;
            var responded = new HashSet<string>();
            var done = new HashSet<string>();
            foreach (var line in lines)
            {
                if (line["result"]?["jobId"] is { } id)
                    ok &= responded.Add(id.GetValue<string>());
                else if (line["event"]?.GetValue<string>() is "job.updated" or "job.finished")
                {
                    var jobId = line["data"]!["jobId"]!.GetValue<string>();
                    ok &= responded.Contains(jobId) && !done.Contains(jobId);
                    if (line["event"]!.GetValue<string>() == "job.finished")
                        done.Add(jobId);
                }
            }
            Check(ok && responded.Count == count && done.Count == count, "1,000 jobs: response → updates → one finished");
            var history = await host.CallAsync("history.get", new JsonObject());
            Check(history["entries"]!.AsArray().Count == 200, "history keeps the newest 200");
            Check(history["entries"]![0]!["finishedAt"]!.GetValue<string>().Contains('T'), "finishedAt is ISO 8601");
            Check(File.ReadAllText(a) == "original", "source untouched");
            Check(Directory.GetFileSystemEntries(files, ".filee-out-*").Length == 0, "no staging folders left");
            Check(host.Invalid == 0, $"every protocol line is JSON ({host.Invalid} were not), native writes went to stderr");
            Check(host.Stderr.ToString().Contains("native-noise-without-newline"), "native stdout noise reached stderr");
        }
        finally
        {
            try { Directory.Delete(root, true); } catch (IOException) { }
        }
    }

    /// <summary>A host started as a child process, with its protocol lines collected in the background.</summary>
    private sealed class Child : IAsyncDisposable
    {
        private readonly Process _process;
        private readonly Task _reader;
        private int _next;

        private Child(Process process)
        {
            _process = process;
            _process.ErrorDataReceived += (_, e) => { lock (Stderr) Stderr.AppendLine(e.Data); };
            _process.BeginErrorReadLine();
            _reader = Task.Run(async () =>
            {
                while (await _process.StandardOutput.ReadLineAsync() is { } line)
                {
                    try
                    {
                        if (JsonNode.Parse(line) is JsonObject o && o["v"]?.GetValue<int>() == 1)
                        {
                            lock (Lines) Lines.Add(o);
                            continue;
                        }
                    }
                    catch (System.Text.Json.JsonException) { }
                    Interlocked.Increment(ref Invalid);
                }
            });
        }

        public List<JsonObject> Lines { get; } = [];
        public StringBuilder Stderr { get; } = new();
        public int Invalid;

        public static Task<Child> StartAsync(string data, string root, string? language = "en")
        {
            var info = new ProcessStartInfo
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                StandardOutputEncoding = Encoding.UTF8,
            };
            var self = Environment.ProcessPath!;
            info.FileName = self;
            if (Path.GetFileNameWithoutExtension(self) == "dotnet")
                info.ArgumentList.Add(typeof(SelfTest).Assembly.Location);
            foreach (var arg in new[] { "--fake-engines", "--data", data, "--engines", Path.Combine(root, "engines"), "--tmp", Path.Combine(root, "tmp") })
                info.ArgumentList.Add(arg);
            if (language is not null)
            {
                info.ArgumentList.Add("--lang");
                info.ArgumentList.Add(language);
            }
            return Task.FromResult(new Child(Process.Start(info)!));
        }

        public void Send(string line)
        {
            _process.StandardInput.WriteLine(line);
            _process.StandardInput.Flush();
        }

        public async Task WaitAsync(Func<bool> condition, TimeSpan timeout)
        {
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                lock (Lines)
                    if (condition())
                        return;
                await Task.Delay(20);
            }
            throw new TimeoutException("The host did not answer in time.");
        }

        public async Task<JsonObject?> NextEventAsync(string name)
        {
            JsonObject? found = null;
            await WaitAsync(() => (found = Lines.FirstOrDefault(l => l["event"]?.GetValue<string>() == name)) is not null, TimeSpan.FromSeconds(30));
            return found;
        }

        private async Task<JsonObject> ReplyAsync(string id)
        {
            JsonObject? found = null;
            await WaitAsync(() => (found = Lines.FirstOrDefault(l => l["id"]?.GetValue<string>() == id)) is not null, TimeSpan.FromSeconds(30));
            return found!;
        }

        public async Task<JsonObject> CallAsync(string method, JsonObject parameters)
        {
            var id = "r" + Interlocked.Increment(ref _next);
            Send(new JsonObject { ["v"] = 1, ["id"] = id, ["method"] = method, ["params"] = parameters }.ToJsonString());
            var reply = await ReplyAsync(id);
            return reply["result"] as JsonObject ?? throw new InvalidOperationException($"{method}: {reply["error"]?.ToJsonString()}");
        }

        /// <summary>Sends a raw line and returns the error code of the reply (by id, or the next id-less error).</summary>
        public async Task<string?> ErrorCodeAsync(string? id, string line)
        {
            int before;
            lock (Lines) before = Lines.Count;
            Send(line);
            JsonObject? found = null;
            await WaitAsync(() => (found = Lines.Skip(before).FirstOrDefault(l => l.ContainsKey("error")
                && (id is null ? l["id"] is null : l["id"]?.GetValue<string>() == id))) is not null, TimeSpan.FromSeconds(30));
            return found!["error"]!["code"]!.GetValue<string>();
        }

        public async Task<string> StartJobAsync(JsonObject parameters) =>
            (await CallAsync("job.start", parameters))["jobId"]!.GetValue<string>();

        public async Task<JsonObject> FinishedAsync(string jobId)
        {
            JsonObject? found = null;
            await WaitAsync(() => (found = Lines.FirstOrDefault(l => l["event"]?.GetValue<string>() == "job.finished"
                && l["data"]!["jobId"]!.GetValue<string>() == jobId)) is not null, TimeSpan.FromSeconds(30));
            return found!;
        }

        public async ValueTask DisposeAsync()
        {
            _process.StandardInput.Close(); // EOF = shut down
            if (!_process.WaitForExit(10_000))
                _process.Kill(entireProcessTree: true);
            await _reader;
            _process.Dispose();
        }
    }

    private static void Section(string name, Action test)
    {
        Console.WriteLine($"== {name}");
        try { test(); }
        catch (Exception ex) { Fail($"{name} threw {ex}"); }
    }

    private static async Task SectionAsync(string name, Func<Task> test)
    {
        Console.WriteLine($"== {name}");
        try { await test(); }
        catch (Exception ex) { Fail($"{name} threw {ex}"); }
    }

    private static void Check(bool condition, string what)
    {
        if (condition) Pass(what);
        else Fail(what);
    }

    private static void Pass(string what) => Console.WriteLine($"  ok   {what}");

    private static void Fail(string what)
    {
        _failures++;
        Console.WriteLine($"  FAIL {what}");
    }
}
