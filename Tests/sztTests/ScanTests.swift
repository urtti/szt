import Darwin
import Foundation
import Testing
@testable import szt

/// A throwaway directory tree with known contents.
private final class Fixture {
    let path: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("szt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        path = String(cString: realpath(base.path, nil))
    }

    deinit {
        chmod(path + "/locked", 0o755)
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path + "/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    func directory(_ name: String) throws {
        try FileManager.default.createDirectory(atPath: path + "/" + name, withIntermediateDirectories: true)
    }

    func scan(apparent: Bool = true, keepFiles: Int = 100) -> ScanResult {
        var options = ScanOptions()
        options.apparentSize = apparent
        options.threads = 4
        options.keepFiles = keepFiles
        return Scanner.scan(path: path, name: "fixture", options: options) { _ in }
    }
}

@Suite struct ScanTests {
    @Test func countsEveryByteOnce() throws {
        let fixture = try Fixture()
        try fixture.file("a/one.bin", bytes: 1000)
        try fixture.file("a/two.bin", bytes: 2000)
        try fixture.file("b/c/d/deep.bin", bytes: 5000)
        try fixture.directory("empty")
        #expect(link(fixture.path + "/a/one.bin", fixture.path + "/hardlink.bin") == 0)
        #expect(symlink("a", fixture.path + "/to-a") == 0)

        let scan = fixture.scan()
        let root = scan.root
        // The hard link adds nothing; the symlink is one entry whose length is
        // that of its target, "a", and it is not followed.
        #expect(root.size == 1000 + 2000 + 5000 + 1)
        #expect(scan.files == 4)
        #expect(root.totalFiles == 4)
        #expect(root.totalDirs == 5)
        #expect(scan.apparentBytes == 8001)
        #expect(scan.unreadable.isEmpty)

        // Whichever of the two hard links the scan reaches first gets the bytes.
        let a = try #require(root.subdirs.first { $0.name == "a" })
        #expect(a.fileCount + root.fileCount == 3)
        #expect(a.size + root.fileBytes == 3001)
        #expect(a.files.map(\.name).contains("two.bin"))
        let d = try #require(root.subdirs.first { $0.name == "b" }?.subdirs.first?.subdirs.first)
        #expect(d.name == "d")
        #expect(d.depth == 3)
        #expect(d.path == "fixture/b/c/d")
    }

    @Test func onDiskSizeIsWhatIsAllocated() throws {
        let fixture = try Fixture()
        try fixture.file("data.bin", bytes: 100_000)
        // 1 GiB long but nothing written: sparse, so it takes no space.
        let sparse = open(fixture.path + "/sparse.img", O_CREAT | O_WRONLY, 0o644)
        #expect(ftruncate(sparse, 1 << 30) == 0)
        close(sparse)

        let scan = fixture.scan(apparent: false)
        var info = stat()
        stat(fixture.path + "/data.bin", &info)
        #expect(scan.root.size >= UInt64(info.st_blocks) * 512)
        #expect(scan.root.size < 1 << 20)
        #expect(scan.apparentBytes == 100_000 + (1 << 30))
    }

    @Test func remembersOnlyTheLargestFiles() throws {
        let fixture = try Fixture()
        for index in 1...20 { try fixture.file("many/f\(index).bin", bytes: index * 100) }
        let scan = fixture.scan(keepFiles: 3)
        let kept = scan.root.subdirs[0].files.map(\.size).sorted()
        #expect(kept == [1800, 1900, 2000])
        #expect(scan.root.size == (1...20).reduce(0) { $0 + UInt64($1 * 100) })
    }

    @Test func reportsWhatItCannotRead() throws {
        guard getuid() != 0 else { return }  // root reads everything
        let fixture = try Fixture()
        try fixture.file("locked/secret.bin", bytes: 4000)
        try fixture.file("open.bin", bytes: 10)
        chmod(fixture.path + "/locked", 0)
        let scan = fixture.scan()
        #expect(scan.unreadable.map(\.name) == ["locked"])
        #expect(scan.root.subdirs[0].error == EACCES)
        #expect(scan.root.size == 10)
    }

    @Test func pathsLongerThanPathMax() throws {
        let fixture = try Fixture()
        // 12 levels of 100-character names: well past PATH_MAX (1024).
        var fd = open(fixture.path, O_RDONLY)
        for level in 0..<12 {
            let name = String(format: "%02d", level) + String(repeating: "x", count: 98)
            #expect(mkdirat(fd, name, 0o755) == 0)
            let next = openat(fd, name, O_RDONLY)
            close(fd)
            fd = next
        }
        let file = openat(fd, "bottom.bin", O_CREAT | O_WRONLY, 0o644)
        #expect(write(file, [UInt8](repeating: 1, count: 777), 777) == 777)
        close(file)
        close(fd)

        let scan = fixture.scan()
        #expect(scan.root.size == 777)
        #expect(scan.unreadable.isEmpty)
    }
}

@Suite struct ReportTests {
    @Test func drawsATree() throws {
        let fixture = try Fixture()
        try fixture.file("big/movie.mov", bytes: 600_000)
        try fixture.file("big/other.bin", bytes: 200_000)
        try fixture.file("chain/a/b/payload.dat", bytes: 150_000)
        for index in 0..<50 { try fixture.file("small/f\(index).txt", bytes: 1000) }

        var options = ReportOptions()
        options.maxLines = 20
        options.minSize = .percent(1)
        options.apparentSize = true
        let text = Report(scan: fixture.scan(), options: options, terminal: Terminal()).render()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines[0].hasPrefix(" 1.00 MB"))
        #expect(lines[0].hasSuffix("100%  fixture"))
        #expect(lines.contains { $0.hasSuffix("├─ big/") && $0.contains("80.0%") })
        #expect(lines.contains { $0.hasSuffix("│  ├─ movie.mov") })
        // A folder holding nothing but one other thing shares its line.
        #expect(lines.contains { $0.hasSuffix("chain/a/b/payload.dat") })
        #expect(lines.contains { $0.contains("small/  50 files") })
        #expect(lines.contains { $0.hasPrefix(" 1.00 MB on disk") || $0.hasPrefix(" 1.00 MB apparent size") })
        #expect(!text.contains("\u{1B}"))
    }

    @Test func fitsTheLineBudget() throws {
        let fixture = try Fixture()
        for folder in 0..<30 {
            for file in 0..<5 { try fixture.file("d\(folder)/f\(file).bin", bytes: 1000 * (folder + 1) + file) }
        }
        for budget in [3, 8, 15, 40] {
            var options = ReportOptions()
            options.maxLines = budget
            options.apparentSize = true
            let text = Report(scan: fixture.scan(), options: options, terminal: Terminal()).render()
            let tree = text.components(separatedBy: "\n\n")[0].split(separator: "\n")
            #expect(tree.count <= budget, "budget \(budget)")
            #expect(tree.count >= min(budget, 2))
        }
    }
}
