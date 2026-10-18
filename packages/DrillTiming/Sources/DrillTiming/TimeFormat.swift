import Foundation

/// Locale-independent formatting and parsing for timestamps. Saved data
/// never depends on the user's decimal separator.
public enum TimeFormat {
    /// `mm:ss.mmm`, with a leading minus sign for pre-roll.
    public static func clock(_ seconds: Double) -> String {
        let sign = seconds < 0 ? "-" : ""
        let totalMillis = Int64((abs(seconds) * 1000).rounded())
        let minutes = totalMillis / 60_000
        let secs = (totalMillis / 1000) % 60
        let millis = totalMillis % 1000
        return sign + pad(minutes, 2) + ":" + pad(secs, 2) + "." + pad(millis, 3)
    }

    /// `1.200 s`
    public static func seconds(_ seconds: Double) -> String {
        decimal(seconds, places: 3) + " s"
    }

    /// Fixed-point decimal with a period separator regardless of locale.
    public static func decimal(_ value: Double, places: Int) -> String {
        let scale = pow(10.0, Double(places))
        let scaled = Int64((abs(value) * scale).rounded())
        let whole = scaled / Int64(scale)
        let fraction = scaled % Int64(scale)
        let sign = value < 0 && scaled != 0 ? "-" : ""
        return places == 0 ? sign + String(whole) : sign + String(whole) + "." + pad(fraction, places)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    /// Parses `44.6`, `0:44.600`, `1:02:03.5` or `-0:01.250`. Commas are rejected
    /// so a value typed in one locale cannot be misread in another.
    public static func parseClock(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("s") { s = String(s.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard !s.isEmpty, !s.contains(",") else { return nil }
        var negative = false
        if s.hasPrefix("-") { negative = true; s.removeFirst() }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for (i, part) in parts.enumerated() {
            let isLast = i == parts.count - 1
            guard !part.isEmpty,
                  part.allSatisfy({ $0.isASCII && ($0.isNumber || (isLast && $0 == ".")) }),
                  part.filter({ $0 == "." }).count <= 1,
                  let value = Double(part) else { return nil }
            if i > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return negative ? -total : total
    }
}
