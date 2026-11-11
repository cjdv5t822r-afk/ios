import Foundation

/// How lists of names are ordered and searched. The app speaks Polish, so by the Polish alphabet.
/// Port of `content/NameOrder.kt`.
public enum NameOrder {

    private static let polish = Locale(identifier: "pl_PL")

    /// Compares two names the way a Polish dictionary does: Ł after L and Ś after S, not both after Z.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [], range: nil, locale: polish)
    }

    /// `items` ordered by `name`. Items whose names compare as equal keep the order they came in.
    public static func sorted<T>(_ items: [T], by name: (T) -> String) -> [T] {
        var keyed: [(offset: Int, name: String, item: T)] = []
        keyed.reserveCapacity(items.count)
        for (offset, item) in items.enumerated() {
            keyed.append((offset: offset, name: name(item), item: item))
        }
        keyed.sort { first, second in
            let order = compare(first.name, second.name)
            if order == .orderedSame { return first.offset < second.offset }
            return order == .orderedAscending
        }
        return keyed.map { $0.item }
    }

    /// `text` as a search compares it: without letter case and diacritics, so that "lucznik" finds "Łucznik".
    public static func searchKey(_ text: String) -> String {
        var bare = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars where !isMark(scalar) {
            bare.append(scalar)
        }
        // Ł has no decomposition: it is a letter of its own, not an L with a mark.
        return String(bare).lowercased(with: polish).replacingOccurrences(of: "ł", with: "l")
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: return true
        default: return false
        }
    }
}
