import Darwin

struct ReportOptions {
    /// Lines of tree to print, the root's included; nil means no limit.
    var maxLines: Int?
    var maxDepth = Int.max
    var minSize = SizeThreshold.none
    var apparentSize = false
    var binaryUnits = false
}

/// Turns a scanned tree into the printed report.
///
/// Entries are picked largest-first: a folder enters the race only once its
/// parent has been picked, so the result is always a connected tree that
/// drills straight into wherever the space is. Within each folder, whatever
/// didn't make the cut is summed up in one "… N files, M folders" line.
struct Report {
    let scan: ScanResult
    let options: ReportOptions
    let terminal: Terminal

    private var root: DirNode { scan.root }
    private var format: ByteFormat { ByteFormat(binary: options.binaryUnits) }
    private var paint: Paint { Paint(terminal) }

    func render() -> String {
        let footer = footerLines()
        let minBytes: UInt64 = switch options.minSize {
        case .none: 0
        case .bytes(let bytes): bytes
        case .percent(let percent): UInt64(Double(root.size) * percent / 100)
        }

        let rows: [Row]
        if let maxLines = options.maxLines {
            // Chains of single folders fold into one line, so rank a few extra
            // entries and keep the largest prefix that still fits.
            let budget = max(1, maxLines)
            let ranked = rank(limit: budget * 3 + 16, minBytes: minBytes)
            var low = 0, high = ranked.entries.count
            while low < high {
                let mid = (low + high + 1) / 2
                if buildRows(ranked, count: mid, minBytes: minBytes).count <= budget { low = mid } else { high = mid - 1 }
            }
            rows = buildRows(ranked, count: low, minBytes: minBytes)
        } else {
            let ranked = rank(limit: .max, minBytes: minBytes)
            rows = buildRows(ranked, count: ranked.entries.count, minBytes: minBytes)
        }
        return draw(rows) + footer.joined(separator: "\n") + "\n"
    }

    /// Lines printed below the tree, so the caller can budget for them.
    static func footerHeight(_ scan: ScanResult) -> Int {
        2 + (scan.unreadable.isEmpty ? 0 : 1) + (scan.mountPoints.isEmpty ? 0 : 1) + (scan.dataless == 0 ? 0 : 1)
    }

    // MARK: - Choosing entries

    private enum Entry {
        case dir(DirNode)
        case file(FileNode)

        var size: UInt64 {
            switch self {
            case .dir(let dir): dir.size
            case .file(let file): file.size
            }
        }

        var name: String {
            switch self {
            case .dir(let dir): dir.name
            case .file(let file): file.name
            }
        }

        var parent: DirNode {
            switch self {
            case .dir(let dir): dir.parent!
            case .file(let file): file.parent
            }
        }

        var isDir: Bool {
            if case .dir = self { true } else { false }
        }
    }

    private struct Ranking {
        var entries: [Entry] = []
        /// True if entries ran out before the limit did.
        var exhausted = false
    }

    private func rank(limit: Int, minBytes: UInt64) -> Ranking {
        var heap = Heap<Entry> { a, b in
            a.size != b.size ? a.size > b.size : a.name < b.name
        }
        func offerChildren(of dir: DirNode) {
            guard Int(dir.depth) < options.maxDepth else { return }
            for child in dir.subdirs {
                // Folders we couldn't look into get a line (last) whatever their size:
                // they may be hiding something big.
                let flagged = (child.error != 0 && child.error != EDEADLK) || child.skip == .mountPoint
                if flagged || (child.size > 0 && child.size >= minBytes) { heap.push(.dir(child)) }
            }
            for file in dir.files where file.size >= minBytes && file.size > 0 {
                heap.push(.file(file))
            }
        }
        offerChildren(of: root)
        var ranking = Ranking()
        while ranking.entries.count < limit {
            guard let entry = heap.pop() else {
                ranking.exhausted = true
                break
            }
            ranking.entries.append(entry)
            if case .dir(let dir) = entry { offerChildren(of: dir) }
        }
        return ranking
    }

    // MARK: - Laying out rows

    private struct Row {
        enum Kind { case root, dir, file, rest }

        var kind: Kind
        /// Path components; several when a chain of folders was folded together.
        var names: [String]
        var size: UInt64
        /// Tree guides and connector, e.g. "│  ├─ ".
        var lead = ""
        var note: String?
        var warning = false
    }

    private func buildRows(_ ranking: Ranking, count: Int, minBytes: UInt64) -> [Row] {
        let shown = ranking.entries.prefix(count)
        var children: [ObjectIdentifier: [Entry]] = [:]
        for entry in shown { children[ObjectIdentifier(entry.parent), default: []].append(entry) }
        for key in children.keys {
            children[key]!.sort { a, b in a.size != b.size ? a.size > b.size : a.name < b.name }
        }
        // Leftovers are worth a line if they'd have been big enough to be picked.
        // Rankings come out largest first, so the last nonzero one is the smallest.
        var cutoff = max(minBytes, 1)
        if count < ranking.entries.count || !ranking.exhausted {
            cutoff = max(cutoff, shown.last(where: { $0.size > 0 })?.size ?? root.size)
        }

        var builder = RowBuilder(children: children, cutoff: cutoff, format: format)
        builder.rows.append(Row(kind: .root, names: [root.name], size: root.size))
        builder.addChildren(of: root, guides: "")
        return builder.rows
    }

    private struct RowBuilder {
        let children: [ObjectIdentifier: [Entry]]
        let cutoff: UInt64
        let format: ByteFormat
        var rows: [Row] = []

        mutating func addChildren(of dir: DirNode, guides: String) {
            let shown = children[ObjectIdentifier(dir)] ?? []
            let rest = leftovers(of: dir, shown: shown)
            for (index, entry) in shown.enumerated() {
                let last = index == shown.count - 1 && rest == nil
                add(entry, guides: guides, last: last)
            }
            if let rest {
                rows.append(Row(kind: .rest, names: [rest.label], size: rest.size, lead: guides + "╰─ "))
            }
        }

        private mutating func add(_ entry: Entry, guides: String, last: Bool) {
            var names = [entry.name]
            var current = entry
            // Fold a folder into its only child when that changes nothing on
            // screen: "Containers/com.docker.docker/Data/vms/0" on one line.
            while case .dir(let dir) = current,
                  let only = children[ObjectIdentifier(dir)], only.count == 1,
                  leftovers(of: dir, shown: only) == nil,
                  format.string(only[0].size) == format.string(dir.size) {
                current = only[0]
                names.append(current.name)
            }

            var row = Row(kind: current.isDir ? .dir : .file, names: names, size: entry.size,
                          lead: guides + (last ? "╰─ " : "├─ "))
            if case .dir(let dir) = current {
                if dir.error == EDEADLK {
                    row.note = "in the cloud, not downloaded"
                } else if dir.error != 0 {
                    row.note = "can't read: \(String(cString: strerror(dir.error)).lowercased())"
                    row.warning = true
                } else if dir.skip == .mountPoint {
                    row.note = "another volume, not scanned"
                } else if dir.skip == .alreadyCounted {
                    row.note = "already counted elsewhere"
                } else if children[ObjectIdentifier(dir)] == nil && dir.totalFiles > 0 {
                    row.note = Format.compact(dir.totalFiles) + (dir.totalFiles == 1 ? " file" : " files")
                }
            }
            rows.append(row)
            if case .dir(let dir) = current {
                addChildren(of: dir, guides: guides + (last ? "   " : "│  "))
            }
        }

        /// The part of an expanded folder that isn't shown entry by entry.
        private func leftovers(of dir: DirNode, shown: [Entry]) -> (label: String, size: UInt64)? {
            guard !shown.isEmpty else { return nil }
            var bytes: UInt64 = 0
            var dirs = 0
            for entry in shown {
                bytes &+= entry.size
                if entry.isDir { dirs += 1 }
            }
            let hiddenDirs = dir.subdirs.count - dirs
            let hiddenFiles = Int(dir.fileCount) - (shown.count - dirs)
            let size = dir.size &- bytes
            guard size > 0, size >= cutoff, hiddenDirs + hiddenFiles > 0 else { return nil }
            var parts: [String] = []
            if hiddenFiles > 0 { parts.append(Format.plural(hiddenFiles, "file", "files")) }
            if hiddenDirs > 0 { parts.append(Format.plural(hiddenDirs, "folder", "folders")) }
            return ("… " + parts.joined(separator: ", "), size)
        }
    }

    // MARK: - Drawing

    private func draw(_ rows: [Row]) -> String {
        let paint = paint
        let numberWidth = 4
        let percentWidth = 6
        // " 12.3 GB  ███████▌      44.3%  ├─ name"
        let fixed = 1 + numberWidth + 1 + format.unitWidth + 2 + 1 + percentWidth + 2
        let labels = rows.map(plainLabel)
        let treeWidth = zip(rows, labels).map { row, label in
            displayWidth(row.lead) + displayWidth(label) + (row.note.map { 2 + displayWidth($0) } ?? 0)
        }.max() ?? 0

        var barWidth = 20
        var labelLimit = Int.max
        if let columns = terminal.width {
            // A quarter of the room for bars, more if the names leave it unused;
            // names that still don't fit get shortened instead.
            let room = columns - fixed - 1
            barWidth = max(min(30, max(10, room / 4)), min(30, room - treeWidth))
            labelLimit = room - barWidth
        }

        var output = ""
        for (row, label) in zip(rows, labels) {
            let fraction = root.size > 0 ? Double(row.size) / Double(root.size) : 0
            let heat = paint.heat(fraction)
            let (number, unit) = format.parts(row.size)

            output += " "
            switch row.kind {
            case .root: output += paint.bold
            case .rest: output += paint.faint
            case .dir, .file: output += paint.color(heat)
            }
            output += pad(number, numberWidth) + " " + unit + String(repeating: " ", count: format.unitWidth - unit.count)
            output += paint.reset + "  "

            switch row.kind {
            case .root: output += paint.color(paint.directory)
            case .rest: output += paint.faint
            case .dir, .file: output += paint.color(heat)
            }
            output += bar(fraction, width: barWidth) + paint.reset
            output += " " + paint.faint + pad(Format.percent(fraction), percentWidth) + paint.reset + "  "

            // Tree and name, shortened if the line would wrap.
            var note = row.note.map { "  " + $0 } ?? ""
            let room = labelLimit - displayWidth(row.lead)
            if displayWidth(label) + displayWidth(note) > room { note = "" }
            let fitted = displayWidth(label) > room ? truncatedMiddle(label, to: max(8, room)) : nil
            output += paint.color(paint.guide) + row.lead + paint.reset
            output += styledLabel(row, plain: label, fitted: fitted)
            if !note.isEmpty {
                output += (row.warning ? paint.color(paint.warning) : paint.faint) + note + paint.reset
            }
            output += "\n"
        }
        return output
    }

    private func plainLabel(_ row: Row) -> String {
        let names = row.names.map(sanitized)
        switch row.kind {
        case .root, .rest, .file: return names.joined(separator: "/")
        case .dir: return names.joined(separator: "/") + "/"
        }
    }

    private func styledLabel(_ row: Row, plain: String, fitted: String?) -> String {
        let paint = paint
        let directory = paint.bold + paint.color(paint.directory)
        switch row.kind {
        case .root:
            return paint.bold + (fitted ?? plain) + paint.reset
        case .rest:
            return paint.faint + paint.italic + (fitted ?? plain) + paint.reset
        case .dir, .file:
            if let fitted {
                return (row.kind == .dir ? directory : "") + fitted + paint.reset
            }
            var text = ""
            for (index, name) in row.names.enumerated() {
                let isFile = row.kind == .file && index == row.names.count - 1
                text += isFile ? sanitized(name) : directory + sanitized(name) + paint.reset
                if !isFile { text += paint.faint + "/" + paint.reset }
            }
            return text
        }
    }

    private func bar(_ fraction: Double, width: Int) -> String {
        let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var eighths = Int((fraction * Double(width * 8)).rounded())
        if eighths == 0 && fraction > 0 { eighths = 1 }
        eighths = min(eighths, width * 8)
        let full = eighths / 8
        let partial = partials[eighths % 8]
        return String(repeating: "█", count: full) + partial
            + String(repeating: " ", count: width - full - (partial.isEmpty ? 0 : 1))
    }

    private func pad(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - text.count)) + text
    }

    // MARK: - Summary

    /// Summary and warnings, one line each, never wider than the terminal.
    private func footerLines() -> [String] {
        let paint = paint
        let room = (terminal.width ?? .max) - 4
        func fit(_ text: String) -> String { displayWidth(text) > room ? truncatedMiddle(text, to: room) : text }

        var main = format.string(scan.allocatedBytes), mainLabel = "on disk"
        var other = format.string(scan.apparentBytes), otherLabel = "apparent size"
        if options.apparentSize { swap(&main, &other); swap(&mainLabel, &otherLabel) }
        var details = [mainLabel, "\(other) \(otherLabel)", Format.plural(scan.files, "file", "files"),
                       Format.plural(root.totalDirs, "folder", "folders"), Format.duration(scan.seconds)]
        // On narrow terminals drop the least interesting parts rather than wrap.
        for drop in [1, 2, 1] where displayWidth(main + " " + details.joined(separator: " · ")) > room {
            details.remove(at: drop)
        }
        var lines = [" \(paint.bold)\(main)\(paint.reset) \(paint.faint)\(fit(details.joined(separator: " · ")))\(paint.reset)"]

        // The most helpful version that fits: two example folders, one, none,
        // then shorter wording.
        func firstFitting(_ candidates: [String]) -> String {
            candidates.first { displayWidth($0) <= room } ?? fit(candidates[candidates.count - 1])
        }
        func examples(_ nodes: [DirNode], _ count: Int) -> String {
            guard count > 0 else { return "" }
            let sorted = nodes.sorted { ($0.depth, $0.name) < ($1.depth, $1.name) }
            let paths = sorted.prefix(count).map { sanitized($0.path) }
            return " (" + paths.joined(separator: ", ") + (nodes.count > count ? ", …" : "") + ")"
        }
        if !scan.unreadable.isEmpty {
            let folders = Format.plural(scan.unreadable.count, "folder", "folders")
            let text = firstFitting([2, 1, 0].map {
                "Couldn't read \(folders)\(examples(scan.unreadable, $0)). Give your terminal Full Disk Access, or use sudo."
            } + ["Couldn't read \(folders); try sudo."])
            lines.append(" \(paint.color(paint.warning))⚠\(paint.reset) \(paint.faint)\(text)\(paint.reset)")
        }
        if !scan.mountPoints.isEmpty {
            let volumes = Format.plural(scan.mountPoints.count, "mounted volume", "mounted volumes")
            let text = firstFitting([2, 1, 0].map {
                "Skipped \(volumes)\(examples(scan.mountPoints, $0)); add -X to include them."
            } + ["Skipped \(volumes) (see -X)."])
            lines.append(" \(paint.faint)↳ \(text)\(paint.reset)")
        }
        if scan.dataless > 0 {
            let text = "\(Format.plural(scan.dataless, "cloud folder isn't", "cloud folders aren't")) downloaded, "
                + "so \(scan.dataless == 1 ? "it takes" : "they take") no space here."
            lines.append(" \(paint.faint)☁ \(fit(text))\(paint.reset)")
        }
        return [""] + lines
    }
}
