import Foundation

extension KeyedDecodingContainer {
    func relayString(forKey key: Key, default defaultValue: String = "") -> String {
        relayStringIfPresent(forKey: key) ?? defaultValue
    }

    func relayStringIfPresent(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return String(value)
        }
        return nil
    }

    func relayBool(forKey key: Key, default defaultValue: Bool = false) -> Bool {
        relayBoolIfPresent(forKey: key) ?? defaultValue
    }

    func relayBoolIfPresent(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        guard let rawValue = relayStringIfPresent(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }
        switch rawValue {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    func relayInt(forKey key: Key, default defaultValue: Int = 0) -> Int {
        relayIntIfPresent(forKey: key) ?? defaultValue
    }

    func relayIntIfPresent(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        return relayStringIfPresent(forKey: key).flatMap(Int.init)
    }

    func relayUInt64IfPresent(forKey key: Key) -> UInt64? {
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value >= 0 ? UInt64(value) : nil
        }
        return relayStringIfPresent(forKey: key).flatMap(UInt64.init)
    }

    func relayDouble(forKey key: Key, default defaultValue: Double = 0) -> Double {
        relayDoubleIfPresent(forKey: key) ?? defaultValue
    }

    func relayDoubleIfPresent(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return Double(value)
        }
        return relayStringIfPresent(forKey: key).flatMap(Double.init)
    }

    func relayValue<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        try? decodeIfPresent(type, forKey: key)
    }

    func relayArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        (try? decodeIfPresent([T].self, forKey: key)) ?? []
    }
}
