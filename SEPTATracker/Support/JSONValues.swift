import Foundation

/// SEPTA's JSON is loosely typed: the same field can arrive as a string, a number,
/// or null depending on the endpoint and the day. These helpers read a field
/// without caring which.
enum JSONValues {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String:
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "null" || trimmed.lowercased() == "none" {
                return nil
            }
            return trimmed
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        double(value).map { Int($0.rounded()) }
    }

    /// First non-nil string among several possible key spellings.
    static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys { if let s = string(dict[key]) { return s } }
        return nil
    }

    static func double(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys { if let d = double(dict[key]) { return d } }
        return nil
    }

    static func int(_ dict: [String: Any], _ keys: String...) -> Int? {
        for key in keys { if let i = int(dict[key]) { return i } }
        return nil
    }
}
