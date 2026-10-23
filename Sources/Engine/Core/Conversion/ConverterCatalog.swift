import Foundation

public final class ConverterCatalog {
    public let all: [Converter]
    private let lock = NSRecursiveLock()
    private var cache: [String: EngineStatus]?
    public var changed: (() -> Void)?
    private var preferred: [String] = []
    public var priority: [String] {
        get { lock.withLock { preferred } }
        set { lock.withLock { preferred = newValue }; changed?() }
    }
    public init(_ converters: [Converter]) { all = converters }
    public var ordered: [Converter] { all.enumerated().sorted { (priorityIndex($0.element), $0.offset) < (priorityIndex($1.element), $1.offset) }.map(\.element) }
    public func statusOf(_ converter: Converter) -> EngineStatus {
        lock.withLock {
            if cache == nil { cache = Dictionary(all.map { ($0.id, $0.status()) }, uniquingKeysWith: { a, _ in a }) }
            return cache![converter.id] ?? .unavailable("engine.reason.error")
        }
    }
    public func refresh() { lock.withLock { cache = nil }; changed?() }
    public func createPlanner(_ assumeInstalled: [String] = []) -> RoutePlanner {
        RoutePlanner(all.filter { statusOf($0).isAvailable || assumeInstalled.contains($0.id) }, priorityPenalty: { min(self.priorityIndex($0), 9) })
    }
    private func priorityIndex(_ converter: Converter) -> Int { lock.withLock { preferred.firstIndex { $0.caseInsensitiveCompare(converter.id) == .orderedSame } ?? preferred.count } }
}
