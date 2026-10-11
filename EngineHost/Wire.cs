using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using System.Threading.Channels;

namespace FileToX.EngineHost;

/// <summary>A request error sent as <c>{"error":{code,message}}</c>.</summary>
internal sealed class WireException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

internal static class WireJson
{
    public const int MaxLine = 4 * 1024 * 1024;

    /// <summary>Everything the host sends: camelCase names and enums, nulls written out.</summary>
    public static readonly JsonSerializerOptions Write = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
        TypeInfoResolver = new DefaultJsonTypeInfoResolver(),
    };

    /// <summary>
    /// Filee objects coming from the app (presets, profiles, settings): every settable property must be present, no
    /// unknown property, no null where Filee doesn't allow one, enums only as names. Nothing is silently defaulted.
    /// </summary>
    public static readonly JsonSerializerOptions Strict = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        RespectNullableAnnotations = true,
        TypeInfoResolver = new DefaultJsonTypeInfoResolver { Modifiers = { RequireEverySettableProperty } },
    };

    private static void RequireEverySettableProperty(JsonTypeInfo info)
    {
        if (info.Kind != JsonTypeInfoKind.Object)
            return;
        foreach (var property in info.Properties)
            if (property.Set is not null)
                property.IsRequired = true;
    }

    public static JsonNode? ToNode<T>(T value) => JsonSerializer.SerializeToNode(value, Write);

    /// <summary>Reads a Filee object strictly; any mismatch is a <c>bad_request</c>.</summary>
    public static T ReadStrict<T>(JsonNode? node, string what) where T : class
    {
        if (node is null)
            throw new WireException("bad_request", $"{what} is missing.");
        try
        {
            var value = node.Deserialize<T>(Strict) ?? throw new WireException("bad_request", $"{what} is null.");
            NoNullElements(value, what);
            return value;
        }
        catch (JsonException ex)
        {
            throw new WireException("bad_request", $"{what}: {ex.Message}");
        }
    }

    /// <summary>Lists inside Filee objects must not hold nulls (nullable annotations don't cover type arguments).</summary>
    private static void NoNullElements(object value, string what)
    {
        if (value is string || value.GetType().IsPrimitive || value.GetType().IsEnum)
            return;
        if (value is System.Collections.IDictionary map)
        {
            foreach (System.Collections.DictionaryEntry entry in map)
                if (entry.Value is null)
                    throw new WireException("bad_request", $"{what}: null value in a map.");
            return;
        }
        if (value is System.Collections.IEnumerable list)
        {
            foreach (var item in list)
            {
                if (item is null)
                    throw new WireException("bad_request", $"{what}: null element in a list.");
                NoNullElements(item, what);
            }
            return;
        }
        if (value.GetType().Namespace?.StartsWith("Filee", StringComparison.Ordinal) != true)
            return;
        foreach (var property in value.GetType().GetProperties())
            if (property.CanRead && property.CanWrite && property.GetIndexParameters().Length == 0 && property.GetValue(value) is { } child)
                NoNullElements(child, what);
    }
}

/// <summary>
/// The only writer of the protocol descriptor: messages are queued (bounded) and written by one task, in queue order.
/// </summary>
internal sealed class WireWriter
{
    private readonly Channel<byte[]> _queue = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(4096)
    {
        SingleReader = true,
        FullMode = BoundedChannelFullMode.Wait,
    });
    private readonly Stream _output;
    private readonly Task _pump;

    public WireWriter(Stream output)
    {
        _output = output;
        _pump = Task.Run(PumpAsync);
    }

    /// <summary>Raised once when the app stopped reading (broken pipe).</summary>
    public event Action? Broken;

    /// <summary>Sends a result; one over the line limit becomes an <c>internal</c> error for the same id.</summary>
    public void Response(string? id, object? result)
    {
        if (!Send(new JsonObject { ["v"] = 1, ["id"] = id, ["result"] = result as JsonNode ?? WireJson.ToNode(result) ?? new JsonObject() }))
            Error(id, "internal", $"The result is larger than {WireJson.MaxLine} bytes.");
    }

    /// <summary>
    /// Ends the protocol after a message that must not be lost could not be sent: a <c>fatal</c> event, then the
    /// output is closed and <see cref="Broken"/> stops the host (the app treats it as a crash, nothing waits forever).
    /// </summary>
    public void Fatal(string code, string message)
    {
        Send(new JsonObject { ["v"] = 1, ["event"] = "fatal", ["data"] = new JsonObject { ["code"] = code, ["message"] = message } });
        _queue.Writer.TryComplete();
        Task.Run(async () =>
        {
            await Task.WhenAny(_pump, Task.Delay(2000));
            Broken?.Invoke();
        });
    }

    public void Error(string? id, string code, string message) =>
        Send(new JsonObject { ["v"] = 1, ["id"] = id, ["error"] = new JsonObject { ["code"] = code, ["message"] = message } });

    public void Event(string name, JsonNode? data) =>
        Send(new JsonObject { ["v"] = 1, ["event"] = name, ["data"] = data });

    /// <summary>
    /// Queues one line. Blocks while the queue is full (the app reads too slowly). False when the line is over the
    /// limit (nothing is sent) or the output is closed.
    /// </summary>
    public bool Send(JsonObject message)
    {
        var bytes = Encoding.UTF8.GetBytes(message.ToJsonString(WireJson.Write) + "\n");
        if (bytes.Length > WireJson.MaxLine)
        {
            Console.Error.WriteLine($"[host] dropping a {bytes.Length}-byte message (limit {WireJson.MaxLine})");
            return false;
        }
        if (_queue.Writer.TryWrite(bytes))
            return true;
        try
        {
            _queue.Writer.WriteAsync(bytes).AsTask().GetAwaiter().GetResult();
            return true;
        }
        catch (ChannelClosedException)
        {
            return false;
        }
    }

    /// <summary>Writes what is queued, then stops.</summary>
    public async Task CompleteAsync(TimeSpan timeout)
    {
        _queue.Writer.TryComplete();
        await Task.WhenAny(_pump, Task.Delay(timeout));
    }

    private async Task PumpAsync()
    {
        try
        {
            await foreach (var line in _queue.Reader.ReadAllAsync())
            {
                await _output.WriteAsync(line);
                await _output.FlushAsync();
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Console.Error.WriteLine($"[host] protocol output closed: {ex.Message}");
            _queue.Writer.TryComplete();
            Broken?.Invoke();
            // Keep draining so senders never block on a dead pipe.
            await foreach (var _ in _queue.Reader.ReadAllAsync()) { }
        }
    }
}

/// <summary>Splits the input into lines of at most <see cref="WireJson.MaxLine"/> bytes.</summary>
internal sealed class WireReader(Stream input)
{
    private readonly byte[] _buffer = new byte[64 * 1024];
    private int _start, _end;

    /// <summary>The next line; <c>Oversized</c> for a line over the limit (skipped to its end); null at end of input.</summary>
    public async Task<(string? Line, bool Oversized)?> ReadLineAsync()
    {
        var line = new MemoryStream();
        var oversized = false;
        while (true)
        {
            if (_start == _end)
            {
                _start = 0;
                _end = await input.ReadAsync(_buffer);
                if (_end == 0)
                    return line.Length > 0 || oversized ? (oversized ? null : Decode(line), oversized) : null;
            }
            var newline = Array.IndexOf(_buffer, (byte)'\n', _start, _end - _start);
            var stop = newline < 0 ? _end : newline;
            if (!oversized)
            {
                line.Write(_buffer, _start, stop - _start);
                if (line.Length > WireJson.MaxLine)
                {
                    oversized = true;
                    line = new MemoryStream();
                }
            }
            _start = newline < 0 ? _end : newline + 1;
            if (newline >= 0)
                return (oversized ? null : Decode(line), oversized);
        }
    }

    private static string Decode(MemoryStream line)
    {
        var span = line.GetBuffer().AsSpan(0, (int)line.Length);
        if (span.Length > 0 && span[^1] == '\r')
            span = span[..^1];
        return new UTF8Encoding(false, throwOnInvalidBytes: true).GetString(span);
    }
}
