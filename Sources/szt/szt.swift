import Darwin

@main
struct Szt {
    static func main() {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            Console.error("\(error.message)\nTry 'szt --help' for more information.")
            exit(2)
        }
        if options.showHelp {
            Console.write(Options.help + "\n")
            exit(0)
        }
        if options.showVersion {
            Console.write("szt \(Options.version)\n")
            exit(0)
        }

        // Looking must not make iCloud Drive, Dropbox & co. download anything:
        // placeholders then fail with EDEADLK instead of being fetched.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                       IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let terminal = Terminal.detect(options.color)
        var status: Int32 = 0
        for (index, path) in options.paths.enumerated() {
            if index > 0 { Console.write("\n") }
            if !report(on: path, options: options, terminal: terminal) { status = 1 }
        }
        // Skip tearing down a tree of possibly millions of nodes.
        exit(status)
    }

    private static func report(on path: String, options: Options, terminal: Terminal) -> Bool {
        guard let resolved = realpath(path, nil) else {
            Console.error("\(path): \(String(cString: strerror(errno)))")
            return false
        }
        let absolute = String(cString: resolved)
        free(resolved)
        let name = abbreviatingHome(absolute)

        var info = stat()
        guard stat(absolute, &info) == 0 else {
            Console.error("\(path): \(String(cString: strerror(errno)))")
            return false
        }
        if info.st_mode & S_IFMT != S_IFDIR {
            reportFile(name: name, info: info, options: options, terminal: terminal)
            return true
        }

        // Without -n the report fills the screen: the command line, the tree, the
        // summary and the next prompt. Its exact height depends on how many
        // warnings the summary ends up with, so settle that after the scan.
        let screenLines = terminal.height.map { height in
            { (footer: Int) in max(10, height - 2 - footer) }
        }
        let maxLines: Int? = options.lines == 0 ? nil : options.lines ?? screenLines?(2) ?? 50

        var scanOptions = ScanOptions()
        scanOptions.apparentSize = options.apparentSize
        scanOptions.crossMounts = options.crossMounts
        scanOptions.threads = options.threads ?? defaultThreadCount()
        // Only files that can make it onto the screen need their names kept.
        scanOptions.keepFiles = maxLines.map { $0 * 3 + 16 } ?? .max
        scanOptions.keepFilesDepth = Int32(clamping: options.depth)

        let progress = ProgressLine(name: name, width: terminal.progressWidth,
                                    format: ByteFormat(binary: options.binaryUnits))
        let scan = Scanner.scan(path: absolute, name: name, options: scanOptions, progress: progress.update)
        progress.clear()

        if scan.root.error != 0 {
            Console.error("\(path): \(String(cString: strerror(scan.root.error)))")
            return false
        }

        var reportOptions = ReportOptions()
        reportOptions.maxLines = maxLines
        if options.lines == nil, let screenLines {
            reportOptions.maxLines = screenLines(Report.footerHeight(scan))
        }
        reportOptions.maxDepth = options.depth
        reportOptions.minSize = options.minSize
        if case .none = options.minSize, options.lines != 0 {
            // Anything under 0.1% is noise when hunting for space ("-m 0" shows it).
            reportOptions.minSize = .percent(0.1)
        }
        reportOptions.apparentSize = options.apparentSize
        reportOptions.binaryUnits = options.binaryUnits
        Console.write(Report(scan: scan, options: reportOptions, terminal: terminal).render())
        return true
    }

    private static func reportFile(name: String, info: stat, options: Options, terminal: Terminal) {
        let format = ByteFormat(binary: options.binaryUnits)
        let paint = Paint(terminal)
        let onDisk = UInt64(info.st_blocks) * 512
        let apparent = UInt64(clamping: info.st_size)
        let (main, other) = options.apparentSize ? (apparent, onDisk) : (onDisk, apparent)
        let otherLabel = options.apparentSize ? "on disk" : "apparent size"
        Console.write(" \(paint.bold)\(format.string(main))\(paint.reset)  \(sanitized(name))"
            + "  \(paint.faint)(\(format.string(other)) \(otherLabel))\(paint.reset)\n")
    }

    private static func abbreviatingHome(_ path: String) -> String {
        guard let home = environment("HOME"), home.count > 1 else { return path }
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == trimmed { return "~" }
        if path.hasPrefix(trimmed + "/") { return "~" + path.dropFirst(trimmed.count) }
        return path
    }

    /// One thread per performance core, at most eight. Measured on an M2 Ultra:
    /// - Opening a directory goes through vnode and name-cache locks the whole
    ///   kernel shares, so past eight threads they mostly wait on each other
    ///   (10 threads are 5% slower than 8, 12 are 55% slower, 24 are 4× slower).
    /// - Efficiency cores don't help: 4 performance + 4 efficiency threads
    ///   finish no sooner than the 4 performance threads alone.
    /// - Oversubscribing hurts a little, so hyperthreads on Intel don't count.
    private static func defaultThreadCount() -> Int {
        let performanceCores = sysctlValue("hw.perflevel0.physicalcpu")  // Apple silicon
            ?? sysctlValue("hw.physicalcpu")                              // Intel
            ?? 4
        return max(1, min(8, performanceCores))
    }

    private static func sysctlValue(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }
}

/// "⠹ Scanning ~/Library · 412,331 files · 23.4 GB · 1.2 s" on stderr while we work.
final class ProgressLine {
    private let name: String
    private let width: Int?
    private let format: ByteFormat
    private var frame = 0
    private var visible = false

    init(name: String, width: Int?, format: ByteFormat) {
        self.name = name
        self.width = width
        self.format = format
        guard width != nil else { return }
        // Don't leave a half-drawn progress line behind on Ctrl-C.
        signal(SIGINT) { _ in
            let clear: StaticString = "\r\u{1B}[2K"
            _ = write(STDERR_FILENO, clear.utf8Start, clear.utf8CodeUnitCount)
            _exit(130)
        }
    }

    func update(_ progress: ScanProgress) {
        // Small scans finish before a progress line would be worth seeing.
        guard let width, progress.seconds >= 0.25 else { return }
        let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        frame += 1
        let counts = " · \(Format.grouped(progress.files)) files · \(format.string(progress.bytes))"
            + " · \(Format.duration(progress.seconds))"
        let room = width - 1 - displayWidth(counts) - 11
        let line = "\(spinner[frame % spinner.count]) Scanning \(truncatedMiddle(sanitized(name), to: max(8, room)))\(counts)"
        Console.write("\r\u{1B}[2K" + line, to: STDERR_FILENO)
        visible = true
    }

    func clear() {
        if visible { Console.write("\r\u{1B}[2K", to: STDERR_FILENO) }
        visible = false
    }
}
