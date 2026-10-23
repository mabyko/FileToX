// Entry point of the helper executable. Replaced by the host port (Sources/Engine/Host).
import Foundation

public enum EngineHostMain {
    public static func run(_ arguments: [String]) -> Int32 {
        FileHandle.standardError.write(Data("FileToXEngine: host not ported yet\n".utf8))
        return 1
    }
}
