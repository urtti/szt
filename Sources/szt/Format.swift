/// Human-readable sizes with three significant digits: "512 B", "9.84 MB", "123 GB".
struct ByteFormat {
    /// Powers of 1024 (KiB, MiB, ...) instead of 1000 (KB, MB, ...) like Finder.
    let binary: Bool

    var unitWidth: Int { binary ? 3 : 2 }

    func parts(_ bytes: UInt64) -> (number: String, unit: String) {
        let units = binary
            ? ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
            : ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        let base: Double = binary ? 1024 : 1000
        if Double(bytes) < base { return (String(bytes), "B") }
        // The nudge makes exact halves round up even after inexact divisions,
        // so 999.5 MB is "1.00 GB" and never "0.99 GB".
        var value = Double(bytes) * (1 + 1e-12)
        var unit = 0
        while value >= 999.5 && unit < units.count - 1 {
            value /= base
            unit += 1
        }
        return (Self.threeDigits(value), units[unit])
    }

    func string(_ bytes: UInt64) -> String {
        let (number, unit) = parts(bytes)
        return "\(number) \(unit)"
    }

    private static func threeDigits(_ value: Double) -> String {
        if value < 9.995 {
            let hundredths = Int((value * 100).rounded())
            let fraction = hundredths % 100
            return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction)"
        }
        if value < 99.95 {
            let tenths = Int((value * 10).rounded())
            return "\(tenths / 10).\(tenths % 10)"
        }
        return String(Int(value.rounded()))
    }
}

enum Format {
    /// 1284312 -> "1,284,312"
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = value < 0 ? "-" : ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(digit)
        }
        return result
    }

    /// 48231 -> "48k", 1234 -> "1.2k", 3_400_000 -> "3.4M"
    static func compact(_ value: Int) -> String {
        func scaled(_ divisor: Double, _ suffix: String) -> String {
            let scaled = Double(value) / divisor
            if scaled < 9.95 {
                let tenths = Int((scaled * 10).rounded())
                return "\(tenths / 10).\(tenths % 10)\(suffix)"
            }
            return "\(Int(scaled.rounded()))\(suffix)"
        }
        if value < 1000 { return String(value) }
        if value < 999_500 { return scaled(1e3, "k") }
        if value < 999_500_000 { return scaled(1e6, "M") }
        return scaled(1e9, "G")
    }

    /// Share of the total: "100%", "44.3%", "0.4%", "<0.1%".
    static func percent(_ fraction: Double) -> String {
        let percent = fraction * 100
        if percent >= 99.95 { return "100%" }
        if percent > 0 && percent < 0.05 { return "<0.1%" }
        let tenths = Int((percent * 10).rounded())
        return "\(tenths / 10).\(tenths % 10)%"
    }

    /// "8 ms", "0.84 s", "12.3 s", "2 m 05 s"
    static func duration(_ seconds: Double) -> String {
        if seconds < 0.0995 {
            return "\(max(1, Int((seconds * 1000).rounded()))) ms"
        }
        if seconds < 9.995 {
            let hundredths = Int((seconds * 100).rounded())
            let fraction = hundredths % 100
            return "\(hundredths / 100).\(fraction < 10 ? "0" : "")\(fraction) s"
        }
        if seconds < 59.95 {
            let tenths = Int((seconds * 10).rounded())
            return "\(tenths / 10).\(tenths % 10) s"
        }
        let total = Int(seconds.rounded())
        let remainder = total % 60
        return "\(total / 60) m \(remainder < 10 ? "0" : "")\(remainder) s"
    }

    static func plural(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(grouped(count)) \(count == 1 ? singular : plural)"
    }
}
