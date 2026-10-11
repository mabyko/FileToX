using System.Runtime.InteropServices;

namespace FileToX.EngineHost;

/// <summary>libc calls for descriptor isolation and the process group.</summary>
internal static partial class Native
{
    private const int F_DUPFD_CLOEXEC = 67; // macOS
    private const int O_RDWR = 0x2;

    // fcntl is variadic: on Apple arm64 variadic arguments go on the stack, after the eight register arguments.
    [LibraryImport("libc", SetLastError = true, EntryPoint = "fcntl")] private static partial int fcntl_x64(int fd, int cmd, int arg);
    [LibraryImport("libc", SetLastError = true, EntryPoint = "fcntl")]
    private static partial int fcntl_arm64(int fd, int cmd, nint r2, nint r3, nint r4, nint r5, nint r6, nint r7, int arg);

    private static int fcntl(int fd, int cmd, int arg) => RuntimeInformation.ProcessArchitecture == Architecture.Arm64
        ? fcntl_arm64(fd, cmd, 0, 0, 0, 0, 0, 0, arg)
        : fcntl_x64(fd, cmd, arg);
    [LibraryImport("libc", SetLastError = true)] private static partial int dup2(int from, int to);
    [LibraryImport("libc", SetLastError = true)] private static partial int close(int fd);
    [LibraryImport("libc", SetLastError = true)] private static partial int setpgid(int pid, int pgid);
    [LibraryImport("libc", SetLastError = true, StringMarshalling = StringMarshalling.Utf8)] private static partial int open(string path, int flags);
    [LibraryImport("libc", SetLastError = true)] public static partial nint write(int fd, byte[] buffer, nint count);

    /// <summary>
    /// Moves the protocol pipes off fd 0/1 onto close-on-exec descriptors: fd 1 becomes stderr (so managed and native
    /// writes to stdout can't corrupt the protocol) and fd 0 becomes /dev/null (child processes inherit neither pipe).
    /// </summary>
    public static (int In, int Out) IsolateProtocol()
    {
        var output = fcntl(1, F_DUPFD_CLOEXEC, 3);
        var input = fcntl(0, F_DUPFD_CLOEXEC, 3);
        if (output < 0 || input < 0)
            throw new IOException($"fcntl failed: errno {Marshal.GetLastPInvokeError()}");
        if (dup2(2, 1) < 0)
            throw new IOException($"dup2 failed: errno {Marshal.GetLastPInvokeError()}");
        var devNull = open("/dev/null", O_RDWR);
        if (devNull < 0 || dup2(devNull, 0) < 0)
            throw new IOException($"/dev/null failed: errno {Marshal.GetLastPInvokeError()}");
        close(devNull);
        return (input, output);
    }

    /// <summary>Becomes a process group leader so the app can stop the host and every engine it started at once.</summary>
    public static void BecomeGroupLeader() => setpgid(0, 0); // fails harmlessly when already a session leader
}
