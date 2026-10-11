using System.Text.Json.Nodes;
using Filee.Core.Conversion;
using Filee.Core.Formats;
using Filee.Core.History;
using Filee.Core.Localization;
using Filee.Core.Presets;
using Filee.Core.Profiles;
using Filee.Core.Settings;
using Filee.Engines;
using Filee.Engines.Infrastructure;

namespace FileToX.EngineHost;

/// <summary>Filee's store, catalog and queue behind the NDJSON methods of host-wire-v1.</summary>
internal sealed class Host : IAsyncDisposable
{
    private sealed class Tracked(ConversionJob job)
    {
        public ConversionJob Job { get; } = job;
        public bool Dirty;
    }

    /// <summary>Orders job.start responses before the job's events, and serializes every store change.</summary>
    private readonly object _gate = new();
    private readonly Dictionary<string, Tracked> _jobs = [];
    private readonly WireWriter _wire;
    private readonly UserDataStore _store;
    private readonly ConverterCatalog _catalog;
    private readonly JobQueue _queue;
    private readonly Localizer _loc;
    private readonly bool _languageFixed;
    private readonly Timer _flush;
    private int _revision = 1;

    public Host(WireWriter wire, UserDataStore store, IReadOnlyList<IConverter> converters, Localizer loc, bool languageFixed,
        Action<string> onStaging)
    {
        _wire = wire;
        _store = store;
        _loc = loc;
        _languageFixed = languageFixed;
        _catalog = new ConverterCatalog(converters) { Priority = store.Settings.EnginePriority };
        EngineEnvironment.OwnCopies = new Dictionary<string, string>(store.Settings.EngineOwnCopies);
        _queue = new JobQueue(_catalog, EngineRegistry.FindPdfMerger(converters), new StderrLogger<JobQueue>(),
            EngineRegistry.FindFileCombiner(converters), EngineRegistry.FindTiffMerger(converters), onStaging);
        _queue.JobUpdated += OnJobUpdated;
        _queue.JobFinished += OnJobFinished;
        _flush = new Timer(_ => FlushUpdates(), null, 100, 100);
    }

    /// <summary>Handles one request; the result is sent by the caller unless the method sent it itself.</summary>
    public JsonNode? Handle(string? id, string method, JsonObject p) => method switch
    {
        "catalog.get" => Catalog(),
        "selection.resolve" => Resolve(Validation.Paths(Strings(p, "paths"))),
        "job.start" => StartJob(id, p),
        "job.cancel" => CancelJob(Text(p, "jobId")),
        "history.get" => Locked(() => new JsonObject { ["entries"] = WireJson.ToNode(_store.History) }),
        "history.clear" => Locked(() => { _store.ClearHistory(); return new JsonObject(); }),
        "library.get" => Locked(Library),
        "library.save" => Locked(() => SaveLibrary(p)),
        "settings.save" => SaveSettings(p),
        _ => throw new WireException("unknown_method", $"Unknown method {method}."),
    };

    /// <summary>Marker result: the response was already sent.</summary>
    public static readonly JsonObject Sent = new();

    private JsonNode Catalog()
    {
        _catalog.Refresh();
        var formats = new JsonArray();
        foreach (var f in FormatRegistry.Known)
            formats.Add(new JsonObject
            {
                ["id"] = f.Id,
                ["displayName"] = f.Id == FormatRegistry.Folder ? _loc["format.folder"] : f.DisplayName,
                ["category"] = WireJson.ToNode(f.Category),
                ["extensions"] = WireJson.ToNode(f.Id == FormatRegistry.Folder ? [] : f.Extensions),
                ["writable"] = f.Writable,
                ["isVirtual"] = f.Id == FormatRegistry.Folder,
            });
        var engines = new JsonArray();
        foreach (var c in _catalog.Ordered)
        {
            var s = _catalog.StatusOf(c);
            engines.Add(new JsonObject
            {
                ["id"] = c.Id,
                ["displayName"] = c.DisplayName,
                ["available"] = s.IsAvailable,
                ["reasonKey"] = s.ReasonKey,
                ["detail"] = s.Detail,
                ["version"] = s.Version,
            });
        }
        return new JsonObject { ["formats"] = formats, ["engines"] = engines };
    }

    private JsonNode Resolve(List<string> paths)
    {
        List<ToolbarProfile> profiles;
        List<Preset> presets;
        lock (_gate)
        {
            profiles = _store.Profiles.Select(x => x.Clone()).ToList();
            presets = _store.Presets.Select(x => x.Clone()).ToList();
        }
        return new Selection(_catalog, profiles, presets, _loc).Resolve(paths);
    }

    private JsonNode StartJob(string? id, JsonObject p)
    {
        var paths = Validation.Paths(Strings(p, "paths"));
        var given = new[] { "presetId", "targetFormat", "preset" }.Where(k => p[k] is not null).ToList();
        if (given.Count != 1)
            throw new WireException("bad_request", "Give exactly one of presetId, targetFormat and preset.");

        Preset preset;
        switch (given[0])
        {
            case "presetId":
                var presetId = Text(p, "presetId");
                lock (_gate)
                    preset = _store.FindPreset(presetId)?.Clone() ?? throw new WireException("not_found", $"No preset {presetId}.");
                break;
            case "targetFormat":
                var target = Text(p, "targetFormat");
                if (!Validation.IsTarget(target))
                    throw new WireException("invalid_input", $"{target} is not a target format.");
                // Filee's default options; conflicts get " (2)" like every built-in preset.
                preset = new Preset { TargetFormat = target, Output = { Conflict = ConflictPolicy.Rename } };
                break;
            default:
                preset = WireJson.ReadStrict<Preset>(p["preset"], "preset");
                Validation.Preset(preset);
                break;
        }

        lock (_gate)
        {
            var name = _loc.DisplayName(preset);
            // Like ConversionService.Start: a preset on "Default" saves where Settings > General says.
            var job = _queue.Enqueue(paths, _store.Settings.WithDefaultOutput(preset), name);
            _jobs[job.Id] = new Tracked(job) { Dirty = true };
            _wire.Response(id, new JsonObject { ["jobId"] = job.Id });
        }
        return Sent;
    }

    private JsonNode CancelJob(string jobId)
    {
        lock (_gate)
            if (_jobs.TryGetValue(jobId, out var tracked))
                tracked.Job.Cancel();
        return new JsonObject();
    }

    /// <summary>Cancels every job and waits (up to <paramref name="timeout"/>) until they finished.</summary>
    public async Task CancelAllAsync(TimeSpan timeout)
    {
        lock (_gate)
            foreach (var t in _jobs.Values)
                t.Job.Cancel();
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            lock (_gate)
                if (_jobs.Count == 0)
                    return;
            await Task.Delay(50);
        }
    }

    private void OnJobUpdated(object? sender, ConversionJob job)
    {
        lock (_gate)
            if (_jobs.TryGetValue(job.Id, out var t))
                t.Dirty = true;
    }

    private void FlushUpdates()
    {
        lock (_gate)
            foreach (var t in _jobs.Values.Where(t => t.Dirty))
            {
                t.Dirty = false;
                var data = JobData(t.Job, StateOf(t.Job), finished: false);
                if (!_wire.Send(Event("job.updated", data)))
                {
                    // Progress only: without the per-file list it still fits; job.finished carries the files.
                    data["files"] = new JsonArray();
                    _wire.Send(Event("job.updated", data));
                }
            }
    }

    private void OnJobFinished(object? sender, ConversionJob job)
    {
        lock (_gate)
        {
            try
            {
                var state = StateOf(job);
                var entry = HistoryEntry.From(job);
                entry.State = state;
                List<string>? retry = null;
                if (entry.Failures.Count > 0)
                    retry = entry.Failures.Select(f => f.Source).ToList();
                else if (state is JobState.Failed or JobState.Cancelled)
                {
                    // A job-level failure (a merger threw, a cancel) has no failed file: keep everything to retry it.
                    retry = [.. job.Sources];
                    entry.Preset = job.Preset.Clone();
                }
                try
                {
                    _store.AddHistory(entry);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    Console.Error.WriteLine($"[host] could not save the history: {ex.Message}");
                }

                var data = JobData(job, state, finished: true);
                data["historyEntry"] = WireJson.ToNode(entry);
                data["retrySources"] = retry is null ? null : WireJson.ToNode(retry);
                data["preset"] = retry is null ? null : WireJson.ToNode(entry.Preset ?? job.Preset);
                // The history is saved before this point, so even a failed delivery loses nothing on disk.
                if (!_wire.Send(Event("job.finished", data)))
                    _wire.Fatal("message_too_large", $"job.finished of {job.Id} is larger than {WireJson.MaxLine} bytes.");
            }
            catch (Exception ex)
            {
                // Never let an exception reach Filee's worker loop; the app still learns the job ended.
                Console.Error.WriteLine($"[host] reporting job {job.Id} failed: {ex}");
                if (!_wire.Send(Event("job.finished", JobData(job, StateOf(job), finished: false))))
                    _wire.Fatal("internal", $"Could not report job {job.Id}.");
            }
            finally
            {
                _jobs.Remove(job.Id);
            }
        }

    }

    private static JsonObject Event(string name, JsonObject data) =>
        new() { ["v"] = 1, ["event"] = name, ["data"] = data.DeepClone() };

    /// <summary>
    /// The state to report: a merge that threw because it was cancelled ends "failed" in Filee, but the user
    /// cancelled it.
    /// </summary>
    private static JobState StateOf(ConversionJob job) =>
        job.State == JobState.Failed && job.CancellationToken.IsCancellationRequested ? JobState.Cancelled : job.State;

    /// <summary>
    /// Snapshot of a job. Running jobs: only scalar fields that workers write atomically; outputs and details only once
    /// finished, when no worker touches the job any more.
    /// </summary>
    private static JsonObject JobData(ConversionJob job, JobState state, bool finished)
    {
        var files = new JsonArray();
        foreach (var f in job.Files)
        {
            var file = new JsonObject
            {
                ["source"] = f.SourcePath,
                ["state"] = WireJson.ToNode(f.State),
                ["progress"] = f.Progress,
                ["errorKey"] = f.ErrorKey,
            };
            if (finished)
            {
                file["outputs"] = new JsonArray(f.Outputs.Select(o => (JsonNode)new JsonObject
                {
                    ["path"] = o,
                    ["isDirectory"] = Directory.Exists(o),
                }).ToArray());
                file["errorDetail"] = f.ErrorDetail;
            }
            files.Add(file);
        }
        return new JsonObject
        {
            ["jobId"] = job.Id,
            ["state"] = WireJson.ToNode(state),
            ["progress"] = job.Files.Count == 0 ? 1 : job.Files.Sum(f => f.Progress) / job.Files.Count,
            ["presetName"] = job.PresetDisplayName,
            ["files"] = files,
        };
    }

    private JsonNode Library() => new JsonObject
    {
        ["revision"] = _revision,
        ["settings"] = WireJson.ToNode(_store.Settings),
        ["presets"] = WireJson.ToNode(_store.Presets),
        ["profiles"] = WireJson.ToNode(_store.Profiles),
    };

    private JsonNode SaveLibrary(JsonObject p)
    {
        CheckRevision(p);
        var presets = WireJson.ReadStrict<List<Preset>>(p["presets"], "presets");
        var profiles = WireJson.ReadStrict<List<ToolbarProfile>>(p["profiles"], "profiles");
        Validation.Library(presets, profiles);
        _store.Presets.Clear();
        _store.Presets.AddRange(presets);
        _store.Profiles.Clear();
        _store.Profiles.AddRange(profiles);
        _store.SaveLibrary();
        _revision++;
        return Library();
    }

    private JsonNode SaveSettings(JsonObject p)
    {
        JsonNode library;
        lock (_gate)
        {
            CheckRevision(p);
            var settings = WireJson.ReadStrict<AppSettings>(p["settings"], "settings");
            Validation.Settings(settings);
            // A cleared path field arrives as "": not set.
            foreach (var blank in settings.EngineOwnCopies.Where(e => string.IsNullOrWhiteSpace(e.Value)).Select(e => e.Key).ToList())
                settings.EngineOwnCopies.Remove(blank);
            // The store's settings object is shared (WithDefaultOutput, KeepHistory): update it in place.
            foreach (var property in typeof(AppSettings).GetProperties().Where(x => x.CanRead && x.CanWrite))
                property.SetValue(_store.Settings, property.GetValue(settings));
            _store.SaveSettings();
            _revision++;

            _catalog.Priority = _store.Settings.EnginePriority;
            EngineEnvironment.OwnCopies = new Dictionary<string, string>(_store.Settings.EngineOwnCopies);
            EngineEnvironment.ForgetSystemCopies();
            if (!_languageFixed)
                _loc.SetLanguage(_store.Settings.Language);
            library = Library();
        }
        // Probing the engines can take seconds: not while the gate holds up job events and other requests.
        _catalog.Refresh();
        return library;
    }

    private void CheckRevision(JsonObject p)
    {
        if (p["baseRevision"] is not JsonValue v || !v.TryGetValue<int>(out var revision))
            throw new WireException("bad_request", "baseRevision must be an integer.");
        if (revision != _revision)
            throw new WireException("conflict", $"The library changed (revision {_revision}, not {revision}).");
    }

    private JsonNode Locked(Func<JsonNode> action)
    {
        lock (_gate)
            return action();
    }

    public static string Text(JsonObject p, string name) =>
        p[name] is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 0
            ? s : throw new WireException("bad_request", $"{name} must be a non-empty string.");

    public static List<string> Strings(JsonObject p, string name)
    {
        if (p[name] is not JsonArray array)
            throw new WireException("bad_request", $"{name} must be an array of strings.");
        return array.Select(n => n is JsonValue v && v.TryGetValue<string>(out var s)
            ? s : throw new WireException("bad_request", $"{name} must be an array of strings.")).ToList();
    }

    public async ValueTask DisposeAsync()
    {
        await _flush.DisposeAsync();
        await _queue.DisposeAsync();
    }
}

/// <summary>Writes warnings and errors of Filee's queue to stderr (the app keeps a log of it).</summary>
internal sealed class StderrLogger<T> : Microsoft.Extensions.Logging.ILogger<T>
{
    public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;
    public bool IsEnabled(Microsoft.Extensions.Logging.LogLevel level) => level >= Microsoft.Extensions.Logging.LogLevel.Warning;

    public void Log<TState>(Microsoft.Extensions.Logging.LogLevel level, Microsoft.Extensions.Logging.EventId eventId, TState state,
        Exception? exception, Func<TState, Exception?, string> formatter)
    {
        if (IsEnabled(level))
            Console.Error.WriteLine($"[{typeof(T).Name}] {level}: {formatter(state, exception)}{(exception is null ? "" : " — " + exception.Message)}");
    }
}
