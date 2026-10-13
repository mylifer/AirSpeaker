import Foundation

/// "0.3.1" veya "v0.3.1" biçimindeki sürüm numarası. Eksik bileşenler 0 sayılır
/// ("1.2" == "1.2.0").
public struct AppVersion: Comparable, CustomStringConvertible {
    public let components: [Int]

    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "v" || text.first == "V" {
            text = text.dropFirst()
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    private func component(_ index: Int) -> Int {
        index < components.count ? components[index] : 0
    }

    public static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        return (0..<count).allSatisfy { lhs.component($0) == rhs.component($0) }
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count where lhs.component(index) != rhs.component(index) {
            return lhs.component(index) < rhs.component(index)
        }
        return false
    }
}
