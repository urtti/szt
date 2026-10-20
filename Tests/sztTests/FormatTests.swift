import Testing
@testable import szt

@Suite struct FormatTests {
    @Test func decimalSizes() {
        let format = ByteFormat(binary: false)
        #expect(format.string(0) == "0 B")
        #expect(format.string(999) == "999 B")
        #expect(format.string(1000) == "1.00 KB")
        #expect(format.string(1_234_567) == "1.23 MB")
        #expect(format.string(12_345_678) == "12.3 MB")
        #expect(format.string(999_499_999) == "999 MB")
        #expect(format.string(999_500_000) == "1.00 GB")
        #expect(format.string(122_400_000_000) == "122 GB")
        #expect(format.string(.max) == "18.4 EB")
    }

    @Test func binarySizes() {
        let format = ByteFormat(binary: true)
        #expect(format.string(1023) == "1023 B")
        #expect(format.string(1024) == "1.00 KiB")
        #expect(format.string(1_048_575) == "1.00 MiB")
        #expect(format.string(5 << 30) == "5.00 GiB")
        #expect(format.parts(1536).unit == "KiB")
    }

    @Test func numbers() {
        #expect(Format.grouped(0) == "0")
        #expect(Format.grouped(999) == "999")
        #expect(Format.grouped(1000) == "1,000")
        #expect(Format.grouped(1_284_312) == "1,284,312")
        #expect(Format.compact(999) == "999")
        #expect(Format.compact(1234) == "1.2k")
        #expect(Format.compact(48_231) == "48k")
        #expect(Format.compact(3_400_000) == "3.4M")
        #expect(Format.plural(1, "file", "files") == "1 file")
        #expect(Format.plural(2048, "file", "files") == "2,048 files")
    }

    @Test func percentages() {
        #expect(Format.percent(1) == "100%")
        #expect(Format.percent(0.4434) == "44.3%")
        #expect(Format.percent(0.004) == "0.4%")
        #expect(Format.percent(0.0001) == "<0.1%")
        #expect(Format.percent(0) == "0.0%")
    }

    @Test func durations() {
        #expect(Format.duration(0.0004) == "1 ms")
        #expect(Format.duration(0.012) == "12 ms")
        #expect(Format.duration(0.84) == "0.84 s")
        #expect(Format.duration(12.34) == "12.3 s")
        #expect(Format.duration(125) == "2 m 05 s")
    }

    @Test func displayWidths() {
        #expect(displayWidth("plain") == 5)
        #expect(displayWidth("日本語") == 6)
        #expect(displayWidth("🎉") == 2)
        #expect(displayWidth("e\u{301}") == 1)  // e + combining acute accent
        #expect(displayWidth("├─ ") == 3)
    }

    @Test func truncation() {
        #expect(truncatedMiddle("short", to: 10) == "short")
        let cut = truncatedMiddle("a-very-long-file-name.mov", to: 12)
        #expect(displayWidth(cut) == 12)
        #expect(cut.hasPrefix("a-ver"))
        #expect(cut.hasSuffix(".mov"))
        #expect(displayWidth(truncatedMiddle("日本語のファイル名.txt", to: 9)) <= 9)
    }

    @Test func controlCharactersAreReplaced() {
        #expect(sanitized("line\nbreak") == "line?break")
        #expect(sanitized("esc\u{1B}[31m") == "esc?[31m")
        #expect(sanitized("fine.txt") == "fine.txt")
    }
}

@Suite struct OptionsTests {
    @Test func defaults() throws {
        let options = try Options.parse([])
        #expect(options.paths == ["."])
        #expect(options.lines == nil)
        #expect(options.depth == .max)
        #expect(!options.apparentSize && !options.crossMounts && !options.binaryUnits)
    }

    @Test func flagsAndValues() throws {
        let options = try Options.parse(["-n", "40", "--depth=3", "-aX", "-j4", "--color", "never", "~/x", "y"])
        #expect(options.lines == 40)
        #expect(options.depth == 3)
        #expect(options.apparentSize && options.crossMounts)
        #expect(options.threads == 4)
        #expect(options.paths == ["~/x", "y"])
        if case .never = options.color {} else { Issue.record("expected --color never") }
    }

    @Test func allAndDoubleDash() throws {
        let options = try Options.parse(["--all", "--", "-weird-name"])
        #expect(options.lines == 0)
        #expect(options.paths == ["-weird-name"])
    }

    @Test func rejectsNonsense() {
        #expect(throws: UsageError.self) { try Options.parse(["--frobnicate"]) }
        #expect(throws: UsageError.self) { try Options.parse(["-n"]) }
        #expect(throws: UsageError.self) { try Options.parse(["-n", "lots"]) }
        #expect(throws: UsageError.self) { try Options.parse(["-d", "0"]) }
        #expect(throws: UsageError.self) { try Options.parse(["--color", "sometimes"]) }
    }

    @Test func sizeThresholds() throws {
        func bytes(_ text: String) throws -> UInt64? {
            if case .bytes(let value) = try Options.parseThreshold(text) { return value }
            return nil
        }
        #expect(try bytes("4096") == 4096)
        #expect(try bytes("500M") == 500_000_000)
        #expect(try bytes("1.5G") == 1_500_000_000)
        #expect(try bytes("2GiB") == 2 << 30)
        #expect(try bytes("10kb") == 10_000)
        if case .percent(let percent) = try Options.parseThreshold("2.5%") {
            #expect(percent == 2.5)
        } else {
            Issue.record("expected a percentage")
        }
        #expect(throws: UsageError.self) { try Options.parseThreshold("12Q") }
        #expect(throws: UsageError.self) { try Options.parseThreshold("150%") }
    }
}
