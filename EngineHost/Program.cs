using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using Filee.Core.Conversion;
using Filee.Core.Settings;
using Filee.Engines;
using Filee.Engines.Infrastructure;
using Microsoft.Win32.SafeHandles;

namespace FileToX.EngineHost;

internal static class Program
{
    public const int Protocol = 1;

    public static async Task<int> Main(string[] args)
    {
        if (args.Contains("--selftest"))
            return await SelfTest.RunAsync();

        // 1. Before anything can print: the protocol leaves fd 0/1, which become /dev/null and stderr.
        var (inFd, outFd) = Native.IsolateProtocol();
        // 2. One process group for the host and every engine it starts.
        Native.BecomeGroupLeader();

        var protoOut = new FileStream(new SafeFileHandle(outFd, ownsHandle: true), FileAccess.Write, 1);
        var protoIn = new FileStream(new SafeFileHandle(inFd, ownsHandle: true), FileAccess.Read, 1);
        var wire = new WireWriter(protoOut);
        try
        {
            return await RunAsync(args, wire, protoIn);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[host] fatal: {ex}");
            wire.Event("fatal", new JsonObject { ["code"] = "internal", ["message"] = ex.Message });
            await wire.CompleteAsync(TimeSpan.FromSeconds(2));
            return 1;
        }
    }

    internal static void ApplyDefaults(UserDataStore store)
    {
        var marker = Path.Combine(store.Directory, ".filetox-defaults-v1");
        var firstMigration = !File.Exists(marker);
        var changed = false;
        if (string.IsNullOrWhiteSpace(store.Settings.Language) || store.Settings.Language.Equals("auto", StringComparison.OrdinalIgnoreCase))
        {
            store.Settings.Language = "en";
            changed = true;
        }
        if (firstMigration && store.Settings.Theme is { } theme && string.Equals(theme.Accent, "#7F77DD", StringComparison.OrdinalIgnoreCase))
        {
            theme.Accent = "#3478F6";
            changed = true;
        }
        if (changed)
            store.SaveSettings();
        // Later choices of the former default purple are user customizations.
        if (firstMigration)
            File.WriteAllText(marker, "1\n");
    }

    private static async Task<int> RunAsync(string[] args, WireWriter wire, Stream input)
    {
        var support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "FileToX");
        var dataDir = Option(args, "--data") ?? Path.Combine(support, "core");
        var enginesDir = Option(args, "--engines") ?? Path.Combine(Path.GetDirectoryName(dataDir)!, "engines");
        var tmpDir = Option(args, "--tmp") ?? Path.Combine(Path.GetDirectoryName(dataDir)!, "tmp");
        var language = Option(args, "--lang");
        foreach (var dir in new[] { dataDir, enginesDir, tmpDir })
            if (!Path.IsPathFullyQualified(dir))
                throw new ArgumentException($"Not an absolute path: {dir}");
        Directory.CreateDirectory(dataDir);
        Directory.CreateDirectory(enginesDir);
        Directory.CreateDirectory(tmpDir);
        // Work folders (Path.GetTempPath()/Filee/<job>) and engines' temp files stay out of Filee's own temp folder.
        Environment.SetEnvironmentVariable("TMPDIR", tmpDir.EndsWith('/') ? tmpDir : tmpDir + "/");

        // 3. One host per data folder.
        FileStream lockFile;
        try
        {
            lockFile = new FileStream(Path.Combine(dataDir, ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException ex)
        {
            Console.Error.WriteLine($"[host] data folder is in use: {ex.Message}");
            wire.Event("fatal", new JsonObject { ["code"] = "data_locked", ["message"] = dataDir });
            await wire.CompleteAsync(TimeSpan.FromSeconds(2));
            return 3;
        }

        using (lockFile)
        {
            // 4. Staging folders a crash left behind.
            var journal = new StagingJournal(Path.Combine(dataDir, "staging.journal"));
            journal.CleanUp();

            // 5. Filee: engine locations, user data, converters, queue.
            EngineEnvironment.DownloadRoot = enginesDir;
            var store = new UserDataStore(dataDir, new StderrLogger<UserDataStore>());
            store.Load();
            ApplyDefaults(store);
            var loc = new Localizer(language ?? store.Settings.Language);
            var converters = args.Contains("--fake-engines")
                ? SelfTest.FakeEngines()
                : EngineRegistry.CreateAll(new EngineEnvironment(dataDir));
            await using var host = new Host(wire, store, converters, loc, languageFixed: language is not null, journal.Append);

            var stop = new CancellationTokenSource();
            wire.Broken += () => stop.Cancel();

            // 6. Ready.
            wire.Event("hello", new JsonObject
            {
                ["protocol"] = Protocol,
                ["hostVersion"] = typeof(Program).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0] ?? "0",
                ["fileeCommit"] = typeof(Program).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>().FirstOrDefault(a => a.Key == "FileeCommit")?.Value,
                ["rid"] = RuntimeInformation.RuntimeIdentifier,
                ["dataDir"] = dataDir,
            });

            await ServeAsync(host, wire, new WireReader(input), stop.Token);

            // stdin closed or the app stopped reading: cancel, give jobs a moment to report, then leave.
            await host.CancelAllAsync(TimeSpan.FromSeconds(5));
            await wire.CompleteAsync(TimeSpan.FromSeconds(2));
            return 0;
        }
    }

    /// <summary>Reads requests one by one until the input ends.</summary>
    private static async Task ServeAsync(Host host, WireWriter wire, WireReader reader, CancellationToken stop)
    {
        while (!stop.IsCancellationRequested)
        {
            (string? Line, bool Oversized)? next;
            try
            {
                next = await reader.ReadLineAsync().WaitAsync(stop);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (System.Text.DecoderFallbackException)
            {
                wire.Error(null, "bad_request", "The line is not UTF-8.");
                continue;
            }
            catch (IOException ex)
            {
                Console.Error.WriteLine($"[host] protocol input failed: {ex.Message}");
                return;
            }
            if (next is not { } item)
                return;
            if (item.Oversized)
            {
                wire.Error(null, "bad_request", $"The line is longer than {WireJson.MaxLine} bytes.");
                continue;
            }
            if (string.IsNullOrWhiteSpace(item.Line))
                continue;
            Dispatch(host, wire, item.Line!);
        }
    }

    internal static void Dispatch(Host host, WireWriter wire, string line)
    {
        string? id = null;
        try
        {
            if (JsonNode.Parse(line) is not JsonObject request)
                throw new WireException("bad_request", "A request is a JSON object.");
            if (request["id"] is JsonValue idValue && idValue.TryGetValue<string>(out var text))
                id = text;
            if (id is null)
                throw new WireException("bad_request", "id must be a string.");
            if (request["v"] is not JsonValue v || !v.TryGetValue<int>(out var version) || version != Protocol)
                throw new WireException("bad_request", $"v must be {Protocol}.");
            if (request["method"] is not JsonValue m || !m.TryGetValue<string>(out var method))
                throw new WireException("bad_request", "method must be a string.");
            if (request["params"] is not JsonObject parameters)
                throw new WireException("bad_request", "params must be an object.");

            var result = host.Handle(id, method, parameters);
            if (!ReferenceEquals(result, Host.Sent))
                wire.Response(id, result);
        }
        catch (WireException ex)
        {
            wire.Error(id, ex.Code, ex.Message);
        }
        catch (JsonException ex)
        {
            wire.Error(id, "bad_request", ex.Message);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[host] request {id} failed: {ex}");
            wire.Error(id, "internal", ex.Message);
        }
    }

    private static string? Option(string[] args, string name)
    {
        var index = Array.IndexOf(args, name);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }
}

/// <summary>
/// Staging folders (see Filee's OutputCommit) are recorded before anything is written into them; the next start
/// deletes those still there (the host was killed mid-conversion) and starts a new journal.
/// </summary>
internal sealed class StagingJournal(string path)
{
    private readonly object _lock = new();

    public void Append(string stagingFolder)
    {
        lock (_lock)
        {
            using var stream = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
            var bytes = System.Text.Encoding.UTF8.GetBytes(stagingFolder + "\n");
            stream.Write(bytes);
            stream.Flush(flushToDisk: true);
        }
    }

    public void CleanUp()
    {
        if (!File.Exists(path))
            return;
        foreach (var line in File.ReadAllLines(path))
        {
            // Only folders Filee's staging made: never anything else a damaged journal might name.
            if (!Path.IsPathFullyQualified(line) || !OutputCommit.IsStagingFolderName(Path.GetFileName(line)))
                continue;
            var info = new DirectoryInfo(line);
            if (info.Exists && info.LinkTarget is null)
                OutputCommit.TryDelete(line);
        }
        File.Delete(path);
    }
}
