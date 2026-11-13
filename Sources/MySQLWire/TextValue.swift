import Foundation

/// Typed decoding of text-protocol values (all values arrive as strings). Allocation-free parsers
/// used by the result grid, sorting and charts; every function returns `nil` instead of trapping.
public enum TextValue {
    public static func integer(_ text: String) -> Int64? {
        Int64(text)
    }

    /// Integers, decimals and floats, including exponents. `nil` for NaN/inf text and non-numbers.
    public static func double(_ text: String) -> Double? {
        guard let first = text.utf8.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+")
            || first == UInt8(ascii: ".") || (first >= UInt8(ascii: "0") && first <= UInt8(ascii: "9")) else { return nil }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// Parses `YYYY-MM-DD`, `YYYY-MM-DD HH:MM:SS[.ffffff]` (also with `T`) as a UTC instant.
    /// StarRocks DATE/DATETIME carry no zone, so UTC keeps charts free of DST artefacts.
    public static func dateTime(_ text: String) -> Date? {
        var utf8 = Array(text.utf8.prefix(32))
        while let last = utf8.last, last == UInt8(ascii: " ") { utf8.removeLast() }
        guard utf8.count >= 10, utf8[4] == UInt8(ascii: "-"), utf8[7] == UInt8(ascii: "-"),
              let year = number(utf8, 0, 4), let month = number(utf8, 5, 2), let day = number(utf8, 8, 2),
              (1...12).contains(month), (1...31).contains(day), (1...9999).contains(year) else { return nil }
        var seconds = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
        if utf8.count >= 19 {
            guard utf8[10] == UInt8(ascii: " ") || utf8[10] == UInt8(ascii: "T"), utf8[13] == UInt8(ascii: ":"), utf8[16] == UInt8(ascii: ":"),
                  let hour = number(utf8, 11, 2), let minute = number(utf8, 14, 2), let second = number(utf8, 17, 2),
                  hour < 24, minute < 60, second < 61 else { return nil }
            seconds += Double(hour * 3600 + minute * 60 + second)
            if utf8.count > 20, utf8[19] == UInt8(ascii: ".") {
                var fraction = 0.0
                var scale = 0.1
                for byte in utf8[20...] {
                    guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                    fraction += Double(byte - UInt8(ascii: "0")) * scale
                    scale /= 10
                }
                seconds += fraction
            } else if utf8.count != 19 {
                return nil
            }
        } else if utf8.count != 10 {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start + length <= bytes.count else { return nil }
        var value = 0
        for byte in bytes[start..<(start + length)] {
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
            value = value * 10 + Int(byte - UInt8(ascii: "0"))
        }
        return value
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let adjustedYear = month <= 2 ? year - 1 : year
        let era = (adjustedYear >= 0 ? adjustedYear : adjustedYear - 399) / 400
        let yearOfEra = adjustedYear - era * 400
        let shiftedMonth = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
