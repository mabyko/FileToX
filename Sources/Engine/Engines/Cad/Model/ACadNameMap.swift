// The keyed collections of ACadSharp are .NET `Dictionary<string, T>` instances; tables, dictionaries and the
// writers enumerate them, so their order is part of the output. This reproduces that order.

import Foundation

extension ACad {
    /// `Dictionary<string, Value>` with `StringComparer.OrdinalIgnoreCase`, enumerated in .NET slot order: an
    /// insertion reuses the most recently freed slot before appending.
    struct NameMap<Value> {
        private var slots: [(key: String, value: Value)?] = []
        private var freeSlots: [Int] = []
        private var index: [String: Int] = [:]

        var count: Int { index.count }
        var isEmpty: Bool { index.isEmpty }

        subscript(key: String) -> Value? {
            index[NameMap.fold(key)].flatMap { slots[$0]?.value }
        }

        func containsKey(_ key: String) -> Bool { index[NameMap.fold(key)] != nil }

        /// The key the entry was added with.
        func storedKey(_ key: String) -> String? { index[NameMap.fold(key)].flatMap { slots[$0]?.key } }

        /// `Dictionary.Add`; false where .NET throws for a duplicate key.
        @discardableResult
        mutating func add(_ key: String, _ value: Value) -> Bool {
            let folded = NameMap.fold(key)
            guard index[folded] == nil else { return false }
            let slot: Int
            if let free = freeSlots.popLast() {
                slot = free
                slots[slot] = (key, value)
            } else {
                slot = slots.count
                slots.append((key, value))
            }
            index[folded] = slot
            return true
        }

        @discardableResult
        mutating func remove(_ key: String) -> Value? {
            guard let slot = index.removeValue(forKey: NameMap.fold(key)) else { return nil }
            let value = slots[slot]?.value
            slots[slot] = nil
            freeSlots.append(slot)
            return value
        }

        mutating func removeAll() {
            slots.removeAll()
            freeSlots.removeAll()
            index.removeAll()
        }

        var pairs: [(key: String, value: Value)] { slots.compactMap { $0 } }
        var keys: [String] { slots.compactMap { $0?.key } }
        var values: [Value] { slots.compactMap { $0?.value } }

        /// `OrdinalIgnoreCase`: per-character simple upper-casing.
        static func fold(_ key: String) -> String {
            if key.utf8.allSatisfy({ $0 < 0x80 }) {
                return String(decoding: key.utf8.map { $0 >= 0x61 && $0 <= 0x7A ? $0 - 0x20 : $0 }, as: UTF8.self)
            }
            var scalars = String.UnicodeScalarView()
            for scalar in key.unicodeScalars {
                let upper = scalar.properties.uppercaseMapping.unicodeScalars
                if upper.count == 1, let single = upper.first { scalars.append(single) } else { scalars.append(scalar) }
            }
            return String(scalars)
        }
    }
}
