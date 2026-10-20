import Darwin

enum SizeThreshold {
    case none
    case bytes(UInt64)
    /// A percentage of the scanned total.
    case percent(Double)
}

struct Options {
    static let version = "1.0.0"

    var paths: [String] = []
    /// Lines of tree to print; nil fits the terminal, 0 means no limit.
    var lines: Int?
    var depth = Int.max
    var minSize = SizeThreshold.none
    var apparentSize = false
    var binaryUnits = false
    var crossMounts = false
    var threads: Int?
    var color = ColorMode.auto
    var showHelp = false
    var showVersion = false

    static let help = """
    szt (sizetree) \(version) - find out what is taking up your disk space

    USAGE
      szt [options] [path ...]

      Scans each path (default: the current directory) on several threads and
      prints a tree of its biggest folders and files, largest first. Every
      folder shows the total size of everything inside it.

    OPTIONS
      -n, --lines N        Print at most N lines (default: fit the terminal)
          --all            Print every entry (same as --lines 0)
      -d, --depth N        Don't show entries more than N levels down
      -m, --min-size SIZE  Hide entries smaller than SIZE, e.g. 500M, 2G or 1%
                           (default 0.1% of the total; -m 0 hides nothing)
      -a, --apparent       Count file lengths instead of space used on disk
      -b, --binary         Use KiB, MiB, GiB instead of Finder's KB, MB, GB
      -X, --cross-mounts   Also scan other volumes mounted inside the path
      -j, --threads N      Scanner threads (default: performance cores, at most 8)
          --color WHEN     auto, always or never (default auto; honors NO_COLOR)
          --no-color       Same as --color never
      -h, --help           Show this help
      -V, --version        Show the version

    SIZES
      Sizes are space used on disk, like du: sparse files, compressed files and
      cloud files that aren't downloaded count only what they actually occupy.
      Hard-linked files are counted once. Other mounted volumes are skipped
      unless you pass -X.

    EXAMPLES
      szt                  What's big in the current folder?
      szt ~ -n 80          The 80 biggest things in your home folder
      szt ~/Library -d 2   Only two levels deep
      sudo szt / -X        Everything on the startup disk, system volumes too
    """

    static func parse(_ arguments: [String]) throws(UsageError) -> Options {
        var options = Options()
        var queue = arguments[...]
        var onlyPaths = false

        func value(for flag: String, attached: String?) throws(UsageError) -> String {
            if let attached { return attached }
            guard let next = queue.popFirst() else { throw UsageError("\(flag) needs a value") }
            return next
        }
        func number(_ text: String, for flag: String) throws(UsageError) -> Int {
            guard let value = Int(text), value >= 0 else { throw UsageError("\(flag) expects a number, got '\(text)'") }
            return value
        }

        while let argument = queue.popFirst() {
            if onlyPaths || argument == "-" || !argument.hasPrefix("-") {
                options.paths.append(argument)
                continue
            }
            if argument == "--" {
                onlyPaths = true
                continue
            }

            // Split "--lines=40" and "-n40" into flag and attached value; expand "-ab".
            var flag = argument
            var attached: String?
            if argument.hasPrefix("--") {
                if let equals = argument.firstIndex(of: "=") {
                    flag = String(argument[..<equals])
                    attached = String(argument[argument.index(after: equals)...])
                }
            } else if argument.count > 2 {
                flag = String(argument.prefix(2))
                let rest = String(argument.dropFirst(2))
                if ["-n", "-d", "-m", "-j"].contains(flag) {
                    attached = rest
                } else {
                    queue.insert("-" + rest, at: queue.startIndex)
                }
            }

            switch flag {
            case "-n", "--lines": options.lines = try number(try value(for: flag, attached: attached), for: flag)
            case "--all": options.lines = 0
            case "-d", "--depth":
                let depth = try number(try value(for: flag, attached: attached), for: flag)
                guard depth > 0 else { throw UsageError("\(flag) must be at least 1") }
                options.depth = depth
            case "-m", "--min-size": options.minSize = try parseThreshold(try value(for: flag, attached: attached))
            case "-a", "--apparent", "--apparent-size": options.apparentSize = true
            case "-b", "--binary": options.binaryUnits = true
            case "-X", "--cross-mounts": options.crossMounts = true
            case "-j", "--threads":
                let threads = try number(try value(for: flag, attached: attached), for: flag)
                guard threads > 0 else { throw UsageError("\(flag) must be at least 1") }
                options.threads = threads
            case "--color", "--colour":
                switch try value(for: flag, attached: attached) {
                case "auto": options.color = .auto
                case "always", "yes", "force": options.color = .always
                case "never", "no", "none": options.color = .never
                case let other: throw UsageError("--color expects auto, always or never, got '\(other)'")
                }
            case "--no-color", "--no-colour": options.color = .never
            case "-h", "--help": options.showHelp = true
            case "-V", "--version": options.showVersion = true
            default: throw UsageError("unknown option '\(argument)'")
            }
        }
        if options.paths.isEmpty { options.paths = ["."] }
        return options
    }

    /// "500M", "1.5G", "2GiB", "4096", "1%"
    static func parseThreshold(_ text: String) throws(UsageError) -> SizeThreshold {
        let invalid = UsageError("can't understand size '\(text)' (try 500M, 2G or 1%)")
        if text.hasSuffix("%") {
            guard let percent = Double(text.dropLast()), percent >= 0, percent <= 100 else { throw invalid }
            return .percent(percent)
        }
        var unit = text.drop { $0.isNumber || $0 == "." }.uppercased()
        let number = text.prefix(text.count - unit.count)
        guard let value = Double(number) else { throw invalid }
        if unit.hasSuffix("B") { unit.removeLast() }
        let binary = unit.hasSuffix("I")
        if binary { unit.removeLast() }
        guard let power = ["": 0, "K": 1, "M": 2, "G": 3, "T": 4, "P": 5].first(where: { $0.key == unit })?.value
        else { throw invalid }
        let bytes = value * pow(binary ? 1024 : 1000, Double(power))
        return .bytes(UInt64(min(bytes, Double(UInt64.max / 2))))
    }
}

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
