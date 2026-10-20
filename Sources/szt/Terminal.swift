import CoreFoundation
import Darwin

enum ColorMode { case auto, always, never }

struct RGB {
    var r, g, b: Double

    init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    func mixed(with other: RGB, _ t: Double) -> RGB {
        RGB(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t)
    }

    /// Nearest color in the xterm 256-color palette (6×6×6 cube or gray ramp).
    var xterm256: Int {
        func level(_ v: Double) -> Int { v < 48 ? 0 : v < 115 ? 1 : min(5, Int((v - 35) / 40)) }
        let levels = [0.0, 95, 135, 175, 215, 255]
        let (cr, cg, cb) = (level(r), level(g), level(b))
        let cube = RGB(levels[cr], levels[cg], levels[cb])
        let gray = max(0, min(23, Int(((r + g + b) / 3 - 8) / 10)))
        let grayValue = Double(8 + gray * 10)
        func distance(_ c: RGB) -> Double { (c.r - r) * (c.r - r) + (c.g - g) * (c.g - g) + (c.b - b) * (c.b - b) }
        return distance(RGB(grayValue, grayValue, grayValue)) < distance(cube)
            ? 232 + gray
            : 16 + 36 * cr + 6 * cg + cb
    }
}

/// What the output is going to and what it can do.
struct Terminal {
    enum Colors { case none, palette256, truecolor }

    var colors = Colors.none
    var lightBackground = false
    /// Width of stdout in columns, if it is a terminal.
    var width: Int?
    var height: Int?
    /// Width of stderr in columns, if it is a terminal (progress goes there).
    var progressWidth: Int?

    static func detect(_ mode: ColorMode) -> Terminal {
        var terminal = Terminal()
        if let size = windowSize(STDOUT_FILENO) {
            terminal.width = size.columns
            terminal.height = size.rows
        }
        terminal.progressWidth = windowSize(STDERR_FILENO)?.columns

        let wanted: Bool
        switch mode {
        case .always: wanted = true
        case .never: wanted = false
        case .auto:
            let noColor = environment("NO_COLOR").map { !$0.isEmpty } ?? false
            wanted = terminal.width != nil && !noColor && environment("TERM") != "dumb"
        }
        if wanted {
            let colorTerm = environment("COLORTERM") ?? ""
            terminal.colors = colorTerm.contains("truecolor") || colorTerm.contains("24bit") ? .truecolor : .palette256
            terminal.lightBackground = guessLightBackground()
        }
        return terminal
    }

    /// Terminals don't say what their background is, so guess: COLORFGBG if the
    /// terminal sets it ("15;0" is light on dark), otherwise the macOS appearance,
    /// which Terminal.app's default profile follows. SZT_THEME=light|dark wins.
    private static func guessLightBackground() -> Bool {
        if let theme = environment("SZT_THEME") { return theme == "light" }
        if let fgbg = environment("COLORFGBG"), let field = fgbg.split(separator: ";").last,
           let background = Int(field) {
            return background == 7 || (9...15).contains(background)
        }
        let key = CFStringCreateWithCString(nil, "AppleInterfaceStyle", CFStringBuiltInEncodings.UTF8.rawValue)
        guard let value = CFPreferencesCopyAppValue(key!, kCFPreferencesAnyApplication) else { return true }
        guard CFGetTypeID(value) == CFStringGetTypeID() else { return true }
        let dark = CFStringCreateWithCString(nil, "Dark", CFStringBuiltInEncodings.UTF8.rawValue)
        return CFStringCompare(unsafeDowncast(value, to: CFString.self), dark, []) != .compareEqualTo
    }

    private static func windowSize(_ fd: Int32) -> (columns: Int, rows: Int)? {
        guard isatty(fd) != 0 else { return nil }
        var size = winsize()
        let TIOCGWINSZ: UInt = 0x4008_7468
        guard ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
        return (Int(size.ws_col), Int(size.ws_row))
    }
}

func environment(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

/// ANSI escape sequences, or empty strings when colors are off.
struct Paint {
    let colors: Terminal.Colors
    let lightBackground: Bool

    init(_ terminal: Terminal) {
        colors = terminal.colors
        lightBackground = terminal.lightBackground
    }

    var on: Bool { colors != .none }
    var reset: String { on ? "\u{1B}[0m" : "" }
    var bold: String { on ? "\u{1B}[1m" : "" }
    var faint: String { on ? "\u{1B}[2m" : "" }
    var italic: String { on ? "\u{1B}[3m" : "" }

    func color(_ c: RGB) -> String {
        switch colors {
        case .none: return ""
        case .palette256: return "\u{1B}[38;5;\(c.xterm256)m"
        case .truecolor: return "\u{1B}[38;2;\(Int(c.r.rounded()));\(Int(c.g.rounded()));\(Int(c.b.rounded()))m"
        }
    }

    var directory: RGB { lightBackground ? RGB(37, 99, 235) : RGB(96, 165, 250) }
    var guide: RGB { lightBackground ? RGB(160, 168, 184) : RGB(100, 108, 128) }
    var warning: RGB { lightBackground ? RGB(202, 138, 4) : RGB(234, 179, 8) }

    /// Cool to hot by share of the total, on a log scale: 0.1% or less is slate,
    /// 1% blue, 10% green, 30% yellow, 100% red. Deeper shades on light backgrounds.
    func heat(_ fraction: Double) -> RGB {
        let stops: [(Double, RGB)] = lightBackground
            ? [(0.00, RGB(100, 116, 139)), (0.30, RGB(2, 132, 199)), (0.50, RGB(13, 148, 136)),
               (0.66, RGB(22, 163, 74)), (0.80, RGB(217, 119, 6)), (0.90, RGB(234, 88, 12)),
               (1.00, RGB(225, 29, 72))]
            : [(0.00, RGB(100, 116, 139)), (0.30, RGB(56, 189, 248)), (0.50, RGB(45, 212, 191)),
               (0.66, RGB(132, 204, 22)), (0.80, RGB(250, 204, 21)), (0.90, RGB(251, 146, 60)),
               (1.00, RGB(244, 63, 94))]
        let t = fraction > 0 ? max(0, min(1, (log10(fraction) + 3) / 3)) : 0
        for (lower, upper) in zip(stops, stops.dropFirst()) where t <= upper.0 {
            return lower.1.mixed(with: upper.1, (t - lower.0) / (upper.0 - lower.0))
        }
        return stops[stops.count - 1].1
    }
}

enum Console {
    static func write(_ text: String, to fd: Int32 = STDOUT_FILENO) {
        var text = text
        text.withUTF8 { bytes in
            guard var pointer = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return
                }
                pointer += written
                remaining -= written
            }
        }
    }

    static func error(_ message: String) {
        write("szt: \(message)\n", to: STDERR_FILENO)
    }
}

// MARK: - Display width

/// Columns `text` occupies in a terminal: wide East Asian characters and emoji
/// take two, combining marks none.
func displayWidth(_ text: String) -> Int {
    if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.utf8.count }
    return text.reduce(0) { $0 + displayWidth($1) }
}

func displayWidth(_ character: Character) -> Int {
    if let ascii = character.asciiValue { return ascii < 0x20 || ascii == 0x7F ? 0 : 1 }
    let scalars = character.unicodeScalars
    guard let first = scalars.first else { return 0 }
    if first.properties.isEmojiPresentation || scalars.contains(where: { $0.value == 0xFE0F }) { return 2 }
    switch first.value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
        return 2
    default:
        switch first.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format, .control: return 0
        default: return 1
        }
    }
}

/// Replaces control characters (newlines in file names, escape sequences...)
/// so a name can't break the layout or mess with the terminal.
func sanitized(_ name: String) -> String {
    guard name.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else {
        return name
    }
    return String(String.UnicodeScalarView(name.unicodeScalars.map {
        $0.value < 0x20 || (0x7F...0x9F).contains($0.value) ? "?" : $0
    }))
}

/// Shortens `text` to at most `width` columns by cutting out its middle.
func truncatedMiddle(_ text: String, to width: Int) -> String {
    guard displayWidth(text) > width else { return text }
    guard width > 1 else { return width == 1 ? "…" : "" }
    let characters = Array(text)
    let budget = width - 1
    var head = "", headWidth = 0, front = 0
    while front < characters.count {
        let w = displayWidth(characters[front])
        if headWidth + w > budget / 2 { break }
        head.append(characters[front])
        headWidth += w
        front += 1
    }
    // The end gets the rest of the room: that's where extensions and versions are.
    var tail: [Character] = [], tailWidth = 0, back = characters.count - 1
    while back >= front {
        let w = displayWidth(characters[back])
        if headWidth + tailWidth + w > budget { break }
        tail.append(characters[back])
        tailWidth += w
        back -= 1
    }
    return head + "…" + String(tail.reversed())
}
