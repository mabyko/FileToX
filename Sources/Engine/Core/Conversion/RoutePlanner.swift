import Foundation

public struct RouteStep { public let converter: Converter; public let from: String; public let to: String }
public struct Route { public let steps: [RouteStep]; public let cost: Int }
public final class RoutePlanner {
    public static let maxSteps = 3
    private let converters: [Converter]
    private let penalty: (Converter) -> Int
    public init(_ converters: [Converter], priorityPenalty: @escaping (Converter) -> Int = { _ in 0 }) { self.converters = converters; penalty = priorityPenalty }
    public func canConvert(_ from: String, _ to: String) -> Bool { plan(from, to) != nil }
    public func plan(_ from: String, _ to: String, textExtraction: Bool = true) -> Route? {
        let from = from.lowercased(), to = to.lowercased()
        if Self.sourceLacksContent(from, to) { return nil }
        let all = converters.flatMap { c in c.edges.map { (c, ConversionEdge($0.from.lowercased(), $0.to.lowercased(), $0.cost + penalty(c), isTextExtraction: $0.isTextExtraction)) } }
        if from == to {
            guard let best = all.filter({ $0.1.from == from && $0.1.to == to }).min(by: { $0.1.cost < $1.1.cost }) else { return nil }
            return Route(steps: [RouteStep(converter: best.0, from: from, to: to)], cost: best.1.cost)
        }
        let edges = all.filter { $0.1.from != $0.1.to }
        var dist = [from: 0], hops = [from: 0], prev: [String: (String, RouteStep)] = [:]
        var queue = DotNetPriorityQueue<String>(); queue.enqueue(from, 0)
        while let (node, cost) = queue.dequeue() {
            if cost > dist[node]! { continue }
            if node == to { break }
            if hops[node]! >= Self.maxSteps { continue }
            for (converter, edge) in edges where edge.from == node {
                // Do not discard a rendered page just to bridge between formats. Reading an original PDF's text
                // or explicitly requesting TXT keeps the existing extraction route, unless a re-plan turns it off.
                if edge.isTextExtraction, !textExtraction || (node != from && edge.to != to) { continue }
                let next = cost + edge.cost
                if let known = dist[edge.to], known <= next { continue }
                dist[edge.to] = next; hops[edge.to] = hops[node]! + 1
                prev[edge.to] = (node, RouteStep(converter: converter, from: edge.from, to: edge.to)); queue.enqueue(edge.to, next)
            }
        }
        guard prev[to] != nil else { return nil }
        var steps: [RouteStep] = [], node = to
        while node != from { let p = prev[node]!; steps.append(p.1); node = p.0 }
        return Route(steps: steps.reversed(), cost: dist[to]!)
    }

    /// Routes that cannot give the target's content are never offered: only video and audio files carry sound, and a
    /// video's text would be what OCR reads in one still frame (pictures and scans reach TXT through PDF and OCR).
    static func sourceLacksContent(_ from: String, _ to: String) -> Bool {
        guard let source = FormatRegistry.find(id: from)?.category, let target = FormatRegistry.find(id: to) else { return false }
        if target.category == .audio { return source != .video && source != .audio }
        return target.id == "txt" && source == .video
    }
}

/// .NET's quaternary heap: equal-priority entries do not bubble up, and removal chooses the first minimum child.
struct DotNetPriorityQueue<Element> {
    private var nodes: [(Element, Int)] = []
    mutating func enqueue(_ element: Element, _ priority: Int) {
        var index = nodes.count; nodes.append((element, priority))
        while index > 0 {
            let parent = (index - 1) / 4
            if priority >= nodes[parent].1 { break }
            nodes[index] = nodes[parent]; index = parent
        }
        nodes[index] = (element, priority)
    }
    mutating func dequeue() -> (Element, Int)? {
        guard let root = nodes.first else { return nil }
        let last = nodes.removeLast()
        if nodes.isEmpty { return root }
        var index = 0
        while index * 4 + 1 < nodes.count {
            let first = index * 4 + 1
            var child = first
            for c in (first + 1)..<min(first + 4, nodes.count) where nodes[c].1 < nodes[child].1 { child = c }
            if last.1 <= nodes[child].1 { break }
            nodes[index] = nodes[child]; index = child
        }
        nodes[index] = last
        return root
    }
}
