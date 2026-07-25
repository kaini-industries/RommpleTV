import XCTest
@testable import RommpleTVKit

/// Every rejection rule in `CueSheet.swift` gets its own assertion here, keyed on
/// the *specific* error the rule raises. A weakened rule therefore fails a named
/// test rather than quietly widening what the parser accepts.
///
/// All filenames are synthetic.
final class CueSheetTests: XCTestCase {

    // MARK: - Helpers

    /// A minimal one-track cue naming `reference`.
    private func cue(_ reference: String, quoted: Bool = true) -> String {
        let operand = quoted ? "\"\(reference)\"" : reference
        return """
        FILE \(operand) BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00

        """
    }

    private func assertRejects(_ text: String, _ expected: CueSheetError,
                               _ message: String = "",
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            let sheet = try CueSheet.parse(text)
            XCTFail("expected \(expected) \(message); parsed \(sheet.fileReferences)",
                    file: file, line: line)
        } catch let error as CueSheetError {
            XCTAssertEqual(error, expected, message, file: file, line: line)
        } catch {
            XCTFail("expected CueSheetError, got \(error)", file: file, line: line)
        }
    }

    /// Rejection of a single reference, expressed through a whole cue sheet.
    private func assertRejectsReference(_ reference: String, _ rejection: CueSheetError.Rejection,
                                        quoted: Bool = true,
                                        file: StaticString = #filePath, line: UInt = #line) {
        assertRejects(cue(reference, quoted: quoted),
                      .unsafeReference(reference, rejection: rejection),
                      reference, file: file, line: line)
    }

    private func assertAccepts(_ reference: String, quoted: Bool = true,
                               normalizedTo normalized: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) {
        do {
            let sheet = try CueSheet.parse(cue(reference, quoted: quoted))
            XCTAssertEqual(sheet.fileReferences, [normalized ?? reference], file: file, line: line)
        } catch {
            XCTFail("expected \(reference) to be accepted, threw \(error)", file: file, line: line)
        }
    }

    private func romFile(_ id: Int, _ fileName: String,
                         _ filePath: String = "psx/Vault Runner") -> RomFile {
        RomFile(id: id, fileName: fileName, filePath: filePath, sizeBytes: 4096,
                isTopLevel: true, crcHash: nil, md5Hash: nil, sha1Hash: nil,
                updatedAt: "2026-01-01T00:00:00")
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Directive scanning (rule 1)

    func testQuotedFileDirective() throws {
        let sheet = try CueSheet.parse(cue("track 01.bin"))
        XCTAssertEqual(sheet.fileReferences, ["track 01.bin"])
    }

    func testUnquotedFileDirective() throws {
        let sheet = try CueSheet.parse(cue("track01.bin", quoted: false))
        XCTAssertEqual(sheet.fileReferences, ["track01.bin"])
    }

    func testKeywordIsCaseInsensitive() throws {
        for keyword in ["FILE", "file", "FiLe", "fILE"] {
            let sheet = try CueSheet.parse("\(keyword) \"track01.bin\" BINARY\n")
            XCTAssertEqual(sheet.fileReferences, ["track01.bin"], keyword)
        }
    }

    func testMultipleFileDirectivesKeepSheetOrder() throws {
        let text = """
        FILE "Vault Runner (Track 01).bin" BINARY
          TRACK 01 MODE2/2352
            INDEX 01 00:00:00
        FILE "Vault Runner (Track 02).bin" BINARY
          TRACK 02 AUDIO
            INDEX 01 00:00:00
        FILE "Vault Runner (Track 03).bin" BINARY
          TRACK 03 AUDIO
            INDEX 01 00:00:00

        """
        XCTAssertEqual(try CueSheet.parse(text).fileReferences,
                       ["Vault Runner (Track 01).bin",
                        "Vault Runner (Track 02).bin",
                        "Vault Runner (Track 03).bin"])
    }

    func testIndentedFileDirectiveIsRecognized() throws {
        let sheet = try CueSheet.parse("\t  FILE \"track01.bin\" BINARY\n")
        XCTAssertEqual(sheet.fileReferences, ["track01.bin"])
    }

    func testCarriageReturnLineEndings() throws {
        let crlf = "FILE \"track01.bin\" BINARY\r\n  TRACK 01 MODE2/2352\r\n"
        let cr = "FILE \"track01.bin\" BINARY\r  TRACK 01 MODE2/2352\r"
        XCTAssertEqual(try CueSheet.parse(crlf).fileReferences, ["track01.bin"])
        XCTAssertEqual(try CueSheet.parse(cr).fileReferences, ["track01.bin"])
    }

    /// Rule 1: only a line whose *first* token is `FILE` is a file directive. A
    /// `FILE` inside a comment is comment text.
    func testFileInsideRemCommentIsIgnored() throws {
        let text = """
        REM FILE "../escape.bin" BINARY
        REM GENRE FILE "/etc/passwd" BINARY
        FILE "track01.bin" BINARY

        """
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["track01.bin"])
        assertRejects("REM FILE \"track01.bin\" BINARY\n", .noFileDirectives)
    }

    /// Rule 1: a quoted operand belonging to another directive is not a file
    /// reference, however file-like it looks.
    func testQuotedOperandsOfOtherDirectivesAreIgnored() throws {
        let text = """
        TITLE "../escape.bin"
        PERFORMER "/absolute.bin"
        SONGWRITER "C:\\payload.bin"
        CATALOG "0000000000000"
        FILE "track01.bin" BINARY

        """
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["track01.bin"])
    }

    func testKeywordPrefixIsNotAFileDirective() {
        assertRejects("FILENAME \"track01.bin\" BINARY\n", .noFileDirectives)
        assertRejects("FILE\"track01.bin\" BINARY\n", .noFileDirectives)
        assertRejects("XFILE \"track01.bin\" BINARY\n", .noFileDirectives)
    }

    func testFileDirectiveWithoutOperand() {
        assertRejects("FILE\n", .malformedDirective(line: 1, problem: .missingOperand))
        assertRejects("FILE   \t\n", .malformedDirective(line: 1, problem: .missingOperand))
        assertRejects("TITLE \"Vault Runner\"\nFILE\n",
                      .malformedDirective(line: 2, problem: .missingOperand))
    }

    func testUnterminatedQuoteIsRejected() {
        assertRejects("FILE \"track01.bin BINARY\n",
                      .malformedDirective(line: 1, problem: .unterminatedQuote))
    }

    func testUnquotedNameWithSpacesIsRejected() {
        assertRejects("FILE track 01.bin BINARY\n",
                      .malformedDirective(line: 1, problem: .unquotedNameWithSpaces))
    }

    func testTrailingJunkAfterQuotedNameIsRejected() {
        assertRejects("FILE \"track01.bin\" BINARY EXTRA\n",
                      .malformedDirective(line: 1, problem: .trailingJunk))
    }

    func testFileTypeMayBeOmitted() throws {
        XCTAssertEqual(try CueSheet.parse("FILE \"track01.bin\"\n").fileReferences,
                       ["track01.bin"])
    }

    func testCueWithoutAnyFileDirectiveIsRejected() {
        assertRejects("", .noFileDirectives)
        assertRejects("REM GENERATED BY NOTHING\nTRACK 01 MODE2/2352\n", .noFileDirectives)
    }

    func testTooManyFileDirectivesAreRejected() throws {
        let ninetyNine = (1...99).map { "FILE \"track\($0).bin\" BINARY" }.joined(separator: "\n")
        XCTAssertEqual(try CueSheet.parse(ninetyNine + "\n").fileReferences.count, 99)
        let hundred = (1...100).map { "FILE \"track\($0).bin\" BINARY" }.joined(separator: "\n")
        assertRejects(hundred + "\n", .tooManyFileDirectives(count: 100, limit: 99))
    }

    func testOversizedCueTextIsRejected() {
        let padding = String(repeating: "REM PADDING\n", count: 100_000)
        XCTAssertGreaterThan(padding.utf8.count, CueSheet.maximumByteCount)
        assertRejects(padding + cue("track01.bin"),
                      .cueTooLarge(byteCount: (padding + cue("track01.bin")).utf8.count,
                                   limit: CueSheet.maximumByteCount))
    }

    // MARK: - Decoding

    func testDecodesUTF8() throws {
        let text = try CueSheet.decode(Data(cue("caf\u{00E9} track.bin").utf8))
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["caf\u{00E9} track.bin"])
    }

    func testStripsUTF8ByteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("FILE \"track01.bin\" BINARY\n".utf8))
        let text = try CueSheet.decode(data)
        XCTAssertFalse(text.unicodeScalars.contains("\u{FEFF}"), "BOM must be stripped")
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["track01.bin"])
    }

    /// The BOM has to go before decoding, not after: the 8-bit fallbacks would
    /// otherwise render it as three characters glued to the first keyword, and the
    /// sheet would parse as having no `FILE` line at all.
    func testStripsUTF8ByteOrderMarkAheadOfAnEightBitFallback() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data("FILE \"".utf8))
        data.append(contentsOf: [0x93])                       // forces the CP1252 stage
        data.append(Data("track01".utf8))
        data.append(contentsOf: [0x94])
        data.append(Data(".bin\" BINARY\n".utf8))
        XCTAssertNil(String(data: data, encoding: .utf8))
        let text = try CueSheet.decode(data)
        XCTAssertTrue(text.hasPrefix("FILE"), "decoded as: \(text)")
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["\u{201C}track01\u{201D}.bin"])
    }

    /// Windows-1252 must be tried *before* ISO-8859-1: bytes 0x93/0x94 are curly
    /// quotes in CP1252 but C1 control characters in Latin-1, and control
    /// characters are a rejection. Order-swapping this chain fails here.
    func testWindows1252IsTriedBeforeISOLatin1() throws {
        var data = Data("FILE \"".utf8)
        data.append(contentsOf: [0x93])                       // “ in CP1252
        data.append(Data("track01".utf8))
        data.append(contentsOf: [0x94])                       // ” in CP1252
        data.append(Data(".bin\" BINARY\n".utf8))
        let text = try CueSheet.decode(data)
        XCTAssertTrue(text.unicodeScalars.contains("\u{201C}"), "CP1252 must win over Latin-1")
        XCTAssertEqual(try CueSheet.parse(text).fileReferences,
                       ["\u{201C}track01\u{201D}.bin"])
    }

    /// 0x81 is undefined in Windows-1252, so only the ISO-8859-1 stage can decode
    /// this sheet. It sits in a comment because 0x81 decodes to a C1 control,
    /// which a *reference* is not allowed to contain.
    func testFallsBackToISOLatin1() throws {
        var data = Data("REM ".utf8)
        data.append(contentsOf: [0x81])
        data.append(Data("\nFILE \"caf".utf8))
        data.append(contentsOf: [0xE9])                       // é in both encodings
        data.append(Data(".bin\" BINARY\n".utf8))
        XCTAssertNil(String(data: data, encoding: .utf8))
        XCTAssertNil(String(data: data, encoding: .windowsCP1252))
        let text = try CueSheet.decode(data)
        XCTAssertTrue(text.unicodeScalars.contains("\u{0081}"))
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["caf\u{00E9}.bin"])
    }

    func testOversizedDataIsRejectedBeforeDecoding() {
        let data = Data(repeating: 0x41, count: CueSheet.maximumByteCount + 1)
        XCTAssertThrowsError(try CueSheet.decode(data)) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .cueTooLarge(byteCount: CueSheet.maximumByteCount + 1,
                                        limit: CueSheet.maximumByteCount))
        }
    }

    /// A UTF-16 sheet decodes through the Latin-1 fallback into NUL-riddled text.
    /// Parsing NUL-bearing text is refused outright rather than half-understood.
    func testNulBytesAreRejected() throws {
        let utf16 = Data("FILE \"track01.bin\" BINARY\n".utf16LittleEndianBytes)
        let text = try CueSheet.decode(utf16)
        assertRejects(text, .nulByteInCue)
        assertRejects("FILE \"track\u{0000}01.bin\" BINARY\n", .nulByteInCue)
    }

    // MARK: - Path rejection (rule 3)

    func testEmptyReferenceIsRejected() {
        assertRejectsReference("", .empty)
    }

    func testAbsolutePathsAreRejected() {
        assertRejectsReference("/absolute.bin", .absolutePath)
        assertRejectsReference("\\absolute.bin", .absolutePath)
        assertRejectsReference("//fileserver/share/track01.bin", .absolutePath)
        assertRejectsReference("\\\\fileserver\\share\\track01.bin", .absolutePath)
    }

    func testParentDirectoryTraversalIsRejected() {
        assertRejectsReference("../escape.bin", .parentDirectory)
        assertRejectsReference("..\\escape.bin", .parentDirectory)
        assertRejectsReference("sub/../../escape.bin", .parentDirectory)
        assertRejectsReference("a\\..\\..\\escape.bin", .parentDirectory)
        assertRejectsReference("a/..\\b/../escape.bin", .parentDirectory)
        // Rejected even though it "cancels out" — this parser does no path arithmetic.
        assertRejectsReference("sub/../track01.bin", .parentDirectory)
        assertRejectsReference("..", .parentDirectory)
    }

    func testCurrentDirectoryComponentIsRejected() {
        assertRejectsReference("./track01.bin", .currentDirectory)
        assertRejectsReference("sub/./track01.bin", .currentDirectory)
        assertRejectsReference(".", .currentDirectory)
    }

    func testDotsOnlyComponentIsRejected() {
        assertRejectsReference(".../track01.bin", .dotsOnlyComponent)
        assertRejectsReference("....bin/track01.bin", .hiddenComponent)   // leading dot wins
        assertRejectsReference("...", .dotsOnlyComponent)
    }

    func testHiddenComponentIsRejected() {
        assertRejectsReference(".hidden.bin", .hiddenComponent)
        assertRejectsReference("sub/.hidden.bin", .hiddenComponent)
        assertRejectsReference(".bin", .hiddenComponent)
    }

    func testHomeDirectoryReferenceIsRejected() {
        assertRejectsReference("~/track01.bin", .homeDirectory)
        assertRejectsReference("~root/track01.bin", .homeDirectory)
        assertRejectsReference("~", .homeDirectory)
    }

    func testDriveLetterIsRejected() {
        assertRejectsReference("C:\\tracks\\track01.bin", .driveLetter)
        assertRejectsReference("c:track01.bin", .driveLetter)
        assertRejectsReference("Z:/track01.bin", .driveLetter)
    }

    func testURLSchemeIsRejected() {
        assertRejectsReference("http://example.invalid/track01.bin", .urlScheme)
        assertRejectsReference("file:///etc/passwd.bin", .urlScheme)
        assertRejectsReference("smb://host/share/track01.bin", .urlScheme)
    }

    func testOtherColonsAreRejected() {
        assertRejectsReference("volume:track01.bin", .colon)
        assertRejectsReference("track01.bin:stream", .colon)
    }

    func testControlAndFormatCharactersAreRejected() {
        assertRejectsReference("track\u{0007}01.bin", .controlCharacter)
        assertRejectsReference("track\u{007F}01.bin", .controlCharacter)
        assertRejectsReference("track\t01.bin", .controlCharacter)
        assertRejectsReference("nib.\u{202E}track01.bin", .controlCharacter)   // RTL override
        assertRejectsReference("track\u{200B}01.bin", .controlCharacter)       // zero width space
        assertRejectsReference("track\u{FEFF}01.bin", .controlCharacter)
        assertRejectsReference("track\u{2028}01.bin", .controlCharacter)       // line separator
        assertRejectsReference("track\u{2029}01.bin", .controlCharacter)
        assertRejectsReference("track\u{0085}01.bin", .controlCharacter)       // NEL
    }

    func testPercentEncodedTraversalIsRejected() {
        assertRejectsReference("%2e%2e%2fescape.bin", .percentEncoded)
        assertRejectsReference("..%2Fescape.bin", .percentEncoded)
        assertRejectsReference("track%00.bin", .percentEncoded)
    }

    /// The percent rule keys on an actual escape sequence, so an ordinary name
    /// containing a percent sign still works.
    func testPlainPercentSignIsAccepted() {
        assertAccepts("100% Cool (Track 01).bin")
    }

    func testLeadingHashComponentIsRejected() {
        assertRejectsReference("#EXTM3U.bin", .leadingHash)
        assertRejectsReference("sub/#track01.bin", .leadingHash)
        assertRejectsReference("#/track01.bin", .leadingHash)
    }

    func testEmptyPathComponentIsRejected() {
        assertRejectsReference("sub//track01.bin", .emptyComponent)
        assertRejectsReference("sub\\\\track01.bin", .emptyComponent)
        assertRejectsReference("track01.bin/", .emptyComponent)
    }

    func testWhitespacePaddedComponentIsRejected() {
        assertRejectsReference(" track01.bin", .whitespacePadding)
        assertRejectsReference("track01.bin ", .whitespacePadding)
        assertRejectsReference("sub /track01.bin", .whitespacePadding)
        assertRejectsReference("track01.bin\u{00A0}", .whitespacePadding)
    }

    func testOverlongComponentIsRejected() {
        let name = String(repeating: "a", count: 256) + ".bin"
        assertRejectsReference(name, .componentTooLong)
    }

    func testOverlongPathIsRejected() {
        let deep = (1...5).map { _ in String(repeating: "d", count: 250) }.joined(separator: "/")
        assertRejectsReference(deep + "/track01.bin", .pathTooLong)
    }

    // MARK: - Referenced extensions

    func testSupportedExtensionsAreAccepted() throws {
        let text = """
        FILE "track01.bin" BINARY
        FILE "TRACK02.BIN" BINARY
        FILE "sidecar.sbi" BINARY
        FILE "Vault Runner.Cue" BINARY

        """
        XCTAssertEqual(try CueSheet.parse(text).fileReferences,
                       ["track01.bin", "TRACK02.BIN", "sidecar.sbi", "Vault Runner.Cue"])
    }

    func testUnsupportedExtensionsAreRejected() {
        assertRejects(cue("track02.wav"),
                      .unsupportedTrackExtension("track02.wav", fileExtension: "wav"))
        assertRejects(cue("disc.iso"), .unsupportedTrackExtension("disc.iso", fileExtension: "iso"))
        assertRejects(cue("payload.exe"),
                      .unsupportedTrackExtension("payload.exe", fileExtension: "exe"))
        assertRejects(cue("track01.bin.exe"),
                      .unsupportedTrackExtension("track01.bin.exe", fileExtension: "exe"))
        assertRejects(cue("track01.mp3"),
                      .unsupportedTrackExtension("track01.mp3", fileExtension: "mp3"))
        assertRejects(cue("README"), .unsupportedTrackExtension("README", fileExtension: ""))
        assertRejects(cue("sub/track01.bin/README"),
                      .unsupportedTrackExtension("sub/track01.bin/README", fileExtension: ""))
    }

    // MARK: - Separator normalization (rule 2)

    func testBackslashSeparatorsNormalizeToSlash() {
        assertAccepts("tracks\\track01.bin", normalizedTo: "tracks/track01.bin")
        assertAccepts("tracks/track01.bin")
    }

    func testNestedDirectoriesAreAllowedWhenSafe() throws {
        let sheet = try CueSheet.parse(cue("tracks/side b/track02.bin"))
        XCTAssertEqual(sheet.fileReferences, ["tracks/side b/track02.bin"])
    }

    // MARK: - Destination collisions (rule 5)

    func testCaseFoldedDestinationCollisionIsRejected() {
        let text = "FILE \"Track01.BIN\" BINARY\nFILE \"track01.bin\" BINARY\n"
        assertRejects(text, .collidingReferences("Track01.BIN", "track01.bin",
                                                 collision: .foldedName))
    }

    /// Two spellings that differ only in Unicode normalization form are one file
    /// on a normalization-insensitive volume, and two different names to the
    /// emulator reading the cue. Neither outcome is safe, so the sheet is refused.
    func testUnicodeNormalizationCollisionIsRejected() {
        let nfc = "caf\u{00E9}.bin"
        let nfd = "cafe\u{0301}.bin"
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8), "fixtures must differ byte-wise")
        assertRejects("FILE \"\(nfc)\" BINARY\nFILE \"\(nfd)\" BINARY\n",
                      .collidingReferences(nfc, nfd, collision: .foldedName))
    }

    func testDirectoryOverFileCollisionIsRejected() {
        assertRejects("FILE \"track01.bin\" BINARY\nFILE \"track01.bin/inner.bin\" BINARY\n",
                      .collidingReferences("track01.bin", "track01.bin/inner.bin",
                                           collision: .directoryOverFile))
        assertRejects("FILE \"TRACK01.BIN/inner.bin\" BINARY\nFILE \"track01.bin\" BINARY\n",
                      .collidingReferences("TRACK01.BIN/inner.bin", "track01.bin",
                                           collision: .directoryOverFile))
    }

    func testIdenticalReferencesCollapseToOne() throws {
        let text = """
        FILE "track01.bin" BINARY
          TRACK 01 MODE2/2352
        FILE "track01.bin" BINARY
          TRACK 02 AUDIO

        """
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["track01.bin"])
    }

    func testSpellingsThatNormalizeIdenticallyCollapseToOne() throws {
        let text = "FILE \"tracks/track01.bin\" BINARY\nFILE \"tracks\\track01.bin\" BINARY\n"
        XCTAssertEqual(try CueSheet.parse(text).fileReferences, ["tracks/track01.bin"])
    }

    // MARK: - Resolution against the disc's files (rules 4, 5, 7)

    private var discFiles: [RomFile] {
        [romFile(9101, "Vault Runner.cue"),
         romFile(9102, "Vault Runner (Track 01).bin"),
         romFile(9103, "Vault Runner (Track 02).bin")]
    }

    func testResolvesExactMatches() throws {
        let sheet = try CueSheet.parse("""
        FILE "Vault Runner (Track 01).bin" BINARY
        FILE "Vault Runner (Track 02).bin" BINARY

        """)
        let resolved = try sheet.resolve(against: discFiles)
        XCTAssertEqual(resolved.map(\.id), [9102, 9103])
        XCTAssertEqual(resolved.map(\.relativeDestinationPath),
                       ["Vault Runner (Track 01).bin", "Vault Runner (Track 02).bin"])
    }

    /// Rule 7: the destination is spelled the way the *cue* spells it, never the
    /// way the server spells it — the cue is never rewritten, so the file on disk
    /// has to be the one the cue names.
    func testUniqueCaseInsensitiveMatchKeepsTheCueSpelling() throws {
        let sheet = try CueSheet.parse(cue("VAULT RUNNER (TRACK 01).BIN"))
        let resolved = try sheet.resolve(against: discFiles)
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved[0].file.id, 9102)
        XCTAssertEqual(resolved[0].file.fileName, "Vault Runner (Track 01).bin")
        XCTAssertEqual(resolved[0].relativeDestinationPath, "VAULT RUNNER (TRACK 01).BIN")
    }

    func testUnicodeNormalizationDifferenceStillMatchesAndKeepsCueSpelling() throws {
        let nfd = "cafe\u{0301}.bin"
        let nfc = "caf\u{00E9}.bin"
        let sheet = try CueSheet.parse(cue(nfc))
        let resolved = try sheet.resolve(against: [romFile(9200, nfd)])
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(Array(resolved[0].relativeDestinationPath.utf8), Array(nfc.utf8))
    }

    func testAmbiguousCaseInsensitiveMatchIsRejected() throws {
        let sheet = try CueSheet.parse(cue("TRACK01.BIN"))
        let files = [romFile(9301, "track01.bin"), romFile(9302, "Track01.Bin")]
        XCTAssertThrowsError(try sheet.resolve(against: files)) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .ambiguousReference("TRACK01.BIN",
                                               matches: ["Track01.Bin", "track01.bin"]))
        }
    }

    func testDuplicateServerEntriesAreAmbiguous() throws {
        let sheet = try CueSheet.parse(cue("track01.bin"))
        let files = [romFile(9401, "track01.bin"), romFile(9402, "track01.bin")]
        XCTAssertThrowsError(try sheet.resolve(against: files)) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .ambiguousReference("track01.bin",
                                               matches: ["track01.bin", "track01.bin"]))
        }
    }

    func testMissingReferenceIsRejected() throws {
        let sheet = try CueSheet.parse(cue("Vault Runner (Track 09).bin"))
        XCTAssertThrowsError(try sheet.resolve(against: discFiles)) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .referenceNotFound("Vault Runner (Track 09).bin"))
        }
        XCTAssertThrowsError(try sheet.resolve(against: [])) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .referenceNotFound("Vault Runner (Track 09).bin"))
        }
    }

    /// Rule 4: matching happens inside one disc's file list. A track belonging to
    /// another disc of the same game is simply not present, and no filesystem or
    /// library-wide search fills the gap.
    func testTrackOfAnotherDiscIsNotFound() throws {
        let sheet = try CueSheet.parse(cue("Vault Runner (Disc 2) (Track 01).bin"))
        let discOne = [romFile(9501, "Vault Runner (Disc 1).cue", "psx/Vault Runner (Disc 1)"),
                       romFile(9502, "Vault Runner (Disc 1) (Track 01).bin",
                               "psx/Vault Runner (Disc 1)")]
        XCTAssertThrowsError(try sheet.resolve(against: discOne)) { error in
            XCTAssertEqual(error as? CueSheetError,
                           .referenceNotFound("Vault Runner (Disc 2) (Track 01).bin"))
        }
    }

    func testNestedServerDirectoryResolvesByItsDiscRelativePath() throws {
        let files = [romFile(9601, "Vault Runner.cue", "psx/Vault Runner"),
                     romFile(9602, "track01.bin", "psx/Vault Runner/tracks")]
        let sheet = try CueSheet.parse(cue("tracks/track01.bin"))
        let resolved = try sheet.resolve(against: files)
        XCTAssertEqual(resolved.map(\.id), [9602])
        XCTAssertEqual(resolved[0].relativeDestinationPath, "tracks/track01.bin")
    }

    /// A bare name must not reach into a subdirectory: the reference and the
    /// file's disc-relative path have to agree on nesting too.
    func testBareNameDoesNotMatchNestedFile() throws {
        let files = [romFile(9701, "Vault Runner.cue", "psx/Vault Runner"),
                     romFile(9702, "track01.bin", "psx/Vault Runner/tracks")]
        let sheet = try CueSheet.parse(cue("track01.bin"))
        XCTAssertThrowsError(try sheet.resolve(against: files)) { error in
            XCTAssertEqual(error as? CueSheetError, .referenceNotFound("track01.bin"))
        }
    }

    /// A server row whose own path escapes the disc directory can never satisfy a
    /// reference: it is dropped from the candidate set before matching.
    func testServerFileWithEscapingPathIsNeverACandidate() throws {
        let files = [romFile(9801, "Vault Runner.cue", "psx/Vault Runner"),
                     romFile(9802, "track01.bin", "psx/Vault Runner/../../elsewhere")]
        let sheet = try CueSheet.parse(cue("track01.bin"))
        XCTAssertThrowsError(try sheet.resolve(against: files)) { error in
            XCTAssertEqual(error as? CueSheetError, .referenceNotFound("track01.bin"))
        }
    }

    /// `file_name` is one path component. A server row that smuggles a separator
    /// into it would let the same disc-relative path be spelled two ways, which is
    /// exactly the ambiguity the collision rules exist to prevent, so such a row is
    /// dropped from the candidate set instead.
    func testServerFileNameContainingSeparatorIsNeverACandidate() throws {
        let files = [romFile(9901, "Vault Runner.cue"),
                     romFile(9902, "sub/track01.bin"),
                     romFile(9903, "../track01.bin")]
        let sheet = try CueSheet.parse(cue("sub/track01.bin"))
        XCTAssertThrowsError(try sheet.resolve(against: files)) { error in
            XCTAssertEqual(error as? CueSheetError, .referenceNotFound("sub/track01.bin"))
        }
    }

    /// A row with no `file_path` sits at the disc root and must not drag the disc
    /// root up to the library root, stranding every properly-pathed file with it.
    func testFileWithEmptyServerPathIsTreatedAsDiscRootWithoutMovingTheRoot() throws {
        let files = [romFile(9911, "Vault Runner.cue", "psx/Vault Runner"),
                     romFile(9912, "track01.bin", "psx/Vault Runner"),
                     romFile(9913, "extra.bin", "")]
        let sheet = try CueSheet.parse("FILE \"track01.bin\" BINARY\nFILE \"extra.bin\" BINARY\n")
        XCTAssertEqual(try sheet.resolve(against: files).map(\.id), [9912, 9913])
    }

    /// Byte-exact matching runs before folding, so a server that holds both
    /// normalization forms as separate files still resolves to the one the cue
    /// spells rather than reporting an ambiguity.
    func testByteExactMatchWinsOverAFoldedOne() throws {
        let nfc = "caf\u{00E9}.bin"
        let nfd = "cafe\u{0301}.bin"
        let files = [romFile(9921, nfd), romFile(9922, nfc)]
        let resolved = try CueSheet.parse(cue(nfc)).resolve(against: files)
        XCTAssertEqual(resolved.map(\.id), [9922])
    }

    func testResolvedOrderFollowsTheSheet() throws {
        let names = (1...8).map { "Vault Runner (Track 0\($0)).bin" }
        let text = names.map { "FILE \"\($0)\" BINARY" }.joined(separator: "\n") + "\n"
        let files = names.enumerated().map { romFile(9000 + $0.offset, $0.element) }
        let resolved = try CueSheet.parse(text).resolve(against: files.shuffled())
        XCTAssertEqual(resolved.map(\.relativeDestinationPath), names)
        XCTAssertEqual(resolved.map(\.id), (0..<8).map { 9000 + $0 })
    }

    // MARK: - M3U output

    func testM3UPreservesDiscOrderAndRelativePaths() {
        let paths = ["Disc 1/Vault Runner (Disc 1).cue",
                     "Disc 2/Vault Runner (Disc 2).cue",
                     "Disc 3/Vault Runner (Disc 3).cue"]
        let data = M3UWriter.data(cuePaths: paths)
        XCTAssertEqual(data, Data(paths.joined(separator: "\n").appending("\n").utf8))
        XCTAssertFalse(data.contains(0x0D), "no CR")
        XCTAssertNotEqual(Array(data.prefix(3)), [0xEF, 0xBB, 0xBF], "no BOM")
    }

    func testM3UNormalizesSeparators() {
        XCTAssertEqual(M3UWriter.data(cuePaths: ["Disc 1\\Vault Runner (Disc 1).cue"]),
                       Data("Disc 1/Vault Runner (Disc 1).cue\n".utf8))
    }

    /// The M3U's paths come from server-supplied names too, so the writer applies
    /// the same validation instead of trusting its caller.
    func testM3UOmitsUnsafePaths() {
        let data = M3UWriter.data(cuePaths: ["../escape.cue",
                                             "/absolute.cue",
                                             "#EXTM3U",
                                             "line\nbreak.cue",
                                             "~/home.cue",
                                             "",
                                             "Disc 1/Vault Runner (Disc 1).cue"])
        XCTAssertEqual(data, Data("Disc 1/Vault Runner (Disc 1).cue\n".utf8))
    }

    func testM3UOfNothingIsEmpty() {
        XCTAssertEqual(M3UWriter.data(cuePaths: []), Data())
        XCTAssertEqual(M3UWriter.data(cuePaths: ["../escape.cue"]), Data())
    }

    // MARK: - Staging directories (rule 6)

    func testStagingCreatesNestedDirectoryBeneathTheDisc() throws {
        let root = try tempDirectory().appendingPathComponent("disc", isDirectory: true)
        let url = try CueStaging.prepareDestination(for: "tracks/track01.bin", in: root)
        XCTAssertEqual(url, root.appendingPathComponent("tracks/track01.bin"))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("tracks").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "file itself not created")
    }

    func testStagingRevalidatesTheRelativePath() throws {
        let root = try tempDirectory()
        let unsafe: [(String, CueSheetError.Rejection)] = [
            ("../escape.bin", .parentDirectory),
            ("/absolute.bin", .absolutePath),
            ("~/track01.bin", .homeDirectory),
            ("sub/../track01.bin", .parentDirectory),
            ("#EXTM3U.bin", .leadingHash),
        ]
        for (path, rejection) in unsafe {
            XCTAssertThrowsError(try CueStaging.prepareDestination(for: path, in: root),
                                 path) { error in
                XCTAssertEqual(error as? CueSheetError,
                               .unsafeReference(path, rejection: rejection), path)
            }
        }
        XCTAssertThrowsError(try CueStaging.prepareDestination(for: "track01.exe", in: root)) {
            XCTAssertEqual($0 as? CueSheetError,
                           .unsupportedTrackExtension("track01.exe", fileExtension: "exe"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    /// A symlink already sitting in the staging tree would move the write outside
    /// the disc folder, so an existing symlinked component is refused rather than
    /// followed.
    func testStagingRefusesToWriteThroughASymlinkedDirectory() throws {
        let base = try tempDirectory()
        let root = base.appendingPathComponent("disc", isDirectory: true)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("tracks"),
                                                   withDestinationURL: outside)

        XCTAssertThrowsError(try CueStaging.prepareDestination(for: "tracks/track01.bin",
                                                              in: root)) { error in
            XCTAssertEqual(error as? CueSheetError, .destinationBlockedBySymlink("tracks"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testStagingRefusesASymlinkedDestinationFile() throws {
        let base = try tempDirectory()
        let root = base.appendingPathComponent("disc", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let victim = base.appendingPathComponent("victim.bin")
        try Data("victim".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("track01.bin"),
                                                   withDestinationURL: victim)

        XCTAssertThrowsError(try CueStaging.prepareDestination(for: "track01.bin",
                                                              in: root)) { error in
            XCTAssertEqual(error as? CueSheetError, .destinationBlockedBySymlink("track01.bin"))
        }
        XCTAssertEqual(try Data(contentsOf: victim), Data("victim".utf8))
    }

    func testStagingRefusesAFileWhereADirectoryIsNeeded() throws {
        let root = try tempDirectory()
        try Data().write(to: root.appendingPathComponent("tracks"))
        XCTAssertThrowsError(try CueStaging.prepareDestination(for: "tracks/track01.bin",
                                                              in: root)) { error in
            XCTAssertEqual(error as? CueSheetError, .destinationBlockedByFile("tracks"))
        }
    }

    /// A symlinked staging root is the caller's own choice and must still work —
    /// containment is judged on resolved paths, not on string prefixes.
    func testStagingAcceptsASymlinkedStagingRoot() throws {
        let base = try tempDirectory()
        let real = base.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let url = try CueStaging.prepareDestination(for: "tracks/track01.bin", in: link)
        XCTAssertEqual(url, link.appendingPathComponent("tracks/track01.bin"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: real.appendingPathComponent("tracks").path))
    }

    func testStagingCreatesTheDiscDirectoryItself() throws {
        let root = try tempDirectory().appendingPathComponent("disc", isDirectory: true)
        let url = try CueStaging.prepareDestination(for: "track01.bin", in: root)
        XCTAssertEqual(url, root.appendingPathComponent("track01.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - End-to-end

    func testEightTrackDiscResolvesEndToEnd() throws {
        var text = "REM GENRE Action\nREM DATE 1999\n"
        var files = [romFile(8100, "Vault Runner.cue")]
        for track in 1...8 {
            let name = String(format: "Vault Runner (Track %02d).bin", track)
            text += "FILE \"\(name)\" BINARY\n  TRACK \(track) AUDIO\n    INDEX 01 00:00:00\n"
            files.append(romFile(8100 + track, name))
        }
        let sheet = try CueSheet.parse(try CueSheet.decode(Data(text.utf8)))
        XCTAssertEqual(sheet.fileReferences.count, 8)
        let resolved = try sheet.resolve(against: files)
        XCTAssertEqual(resolved.map(\.id), (1...8).map { 8100 + $0 })

        let root = try tempDirectory()
        for entry in resolved {
            let url = try CueStaging.prepareDestination(for: entry.relativeDestinationPath,
                                                        in: root)
            XCTAssertTrue(url.path.hasPrefix(root.path + "/"))
        }
    }
}

private extension String {
    /// UTF-16LE bytes, for the "this is not really a cue sheet" decoding test.
    var utf16LittleEndianBytes: [UInt8] {
        unicodeScalars.flatMap { scalar -> [UInt8] in
            String(scalar).utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        }
    }
}
