import Foundation

// MARK: - Errors

/// Every way a cue sheet can be refused. The cases are deliberately fine-grained:
/// each one names the single rule that fired, so a caller can explain the failure
/// to someone sitting on a couch, and a test can pin one rule at a time.
public enum CueSheetError: Error, Equatable, Sendable, LocalizedError {

    /// Why one `FILE` reference is not a safe relative path.
    public enum Rejection: String, Sendable {
        case empty
        case absolutePath
        case parentDirectory
        case currentDirectory
        case dotsOnlyComponent
        case hiddenComponent
        case homeDirectory
        case driveLetter
        case urlScheme
        case colon
        case controlCharacter
        case percentEncoded
        case leadingHash
        case emptyComponent
        case whitespacePadding
        case componentTooLong
        case pathTooLong
    }

    /// Why one `FILE` line is not a well-formed directive.
    public enum DirectiveProblem: String, Sendable {
        case missingOperand
        case unterminatedQuote
        case unquotedNameWithSpaces
        case trailingJunk
    }

    /// Why two references cannot both be staged.
    public enum Collision: String, Sendable {
        /// Same name once case and Unicode normalization are folded away.
        case foldedName
        /// One reference needs a directory where another needs a file.
        case directoryOverFile
    }

    case cueTooLarge(byteCount: Int, limit: Int)
    case undecodableText
    case nulByteInCue
    case noFileDirectives
    case tooManyFileDirectives(count: Int, limit: Int)
    case malformedDirective(line: Int, problem: DirectiveProblem)
    case unsafeReference(String, rejection: Rejection)
    case unsupportedTrackExtension(String, fileExtension: String)
    case collidingReferences(String, String, collision: Collision)
    case referenceNotFound(String)
    case ambiguousReference(String, matches: [String])
    case destinationEscapesStagingDirectory(String)
    case destinationBlockedBySymlink(String)
    case destinationBlockedByFile(String)
    case destinationIsNotARegularFile(String)

    public var errorDescription: String? {
        switch self {
        case let .cueTooLarge(byteCount, limit):
            return "This disc's cue sheet is \(byteCount) bytes; a cue sheet larger than "
                + "\(limit) bytes is not a cue sheet RommpleTV will read."
        case .undecodableText:
            return "This disc's cue sheet is not readable as text."
        case .nulByteInCue:
            return "This disc's cue sheet contains binary data where text should be."
        case .noFileDirectives:
            return "This disc's cue sheet does not list any track files."
        case let .tooManyFileDirectives(count, limit):
            return "This disc's cue sheet lists \(count) track files; a CD holds at most \(limit)."
        case let .malformedDirective(line, problem):
            let detail: String
            switch problem {
            case .missingOperand: detail = "names no file"
            case .unterminatedQuote: detail = "has an unclosed quote"
            case .unquotedNameWithSpaces: detail = "has an unquoted name with spaces in it"
            case .trailingJunk: detail = "has unexpected text after the file name"
            }
            return "Line \(line) of this disc's cue sheet \(detail)."
        case let .unsafeReference(reference, rejection):
            let detail: String
            switch rejection {
            case .empty: detail = "is empty"
            case .absolutePath: detail = "is an absolute path"
            case .parentDirectory: detail = "points outside the disc folder"
            case .currentDirectory: detail = "contains a \".\" path step"
            case .dotsOnlyComponent: detail = "contains a path step made only of dots"
            case .hiddenComponent: detail = "names a hidden file"
            case .homeDirectory: detail = "points at a home directory"
            case .driveLetter: detail = "is a Windows drive path"
            case .urlScheme: detail = "is a URL, not a file in this disc folder"
            case .colon: detail = "contains a colon"
            case .controlCharacter: detail = "contains a control or invisible character"
            case .percentEncoded: detail = "is percent-encoded"
            case .leadingHash: detail = "starts with \"#\""
            case .emptyComponent: detail = "has an empty folder name in it"
            case .whitespacePadding: detail = "starts or ends with a space"
            case .componentTooLong: detail = "has a name that is too long"
            case .pathTooLong: detail = "is too long"
            }
            return "This disc's cue sheet references \"\(reference)\", which \(detail). "
                + "RommpleTV only downloads files that live inside the disc folder."
        case let .unsupportedTrackExtension(reference, fileExtension):
            let kind = fileExtension.isEmpty ? "no file extension" : "a .\(fileExtension) extension"
            return "This disc's cue sheet references \"\(reference)\", which has \(kind). "
                + "RommpleTV plays cue/bin discs only."
        case let .collidingReferences(first, second, collision):
            switch collision {
            case .foldedName:
                return "This disc's cue sheet references both \"\(first)\" and \"\(second)\", "
                    + "which are the same file name on this device."
            case .directoryOverFile:
                return "This disc's cue sheet references both \"\(first)\" and \"\(second)\", "
                    + "so the same name would have to be a file and a folder at once."
            }
        case let .referenceNotFound(reference):
            return "This disc's cue sheet references \"\(reference)\", which is not one of the "
                + "files the server lists for this disc."
        case let .ambiguousReference(reference, matches):
            return "This disc's cue sheet references \"\(reference)\", and the server lists "
                + "\(matches.count) files that could be it (\(matches.joined(separator: ", "))). "
                + "RommpleTV will not guess."
        case let .destinationEscapesStagingDirectory(path):
            return "Saving \"\(path)\" would write outside this disc's folder."
        case let .destinationBlockedBySymlink(component):
            return "\"\(component)\" in this disc's folder is a link to somewhere else, so "
                + "RommpleTV will not write through it."
        case let .destinationBlockedByFile(component):
            return "\"\(component)\" in this disc's folder is a file where a folder is needed."
        case let .destinationIsNotARegularFile(component):
            return "\"\(component)\" in this disc's folder is a folder, or something other "
                + "than a file, where a track file has to go."
        }
    }
}

// MARK: - Path validation

/// The single place a cue-relative path is judged safe. Everything that can turn
/// a server-supplied string into a filesystem write goes through `validate`, which
/// either returns a normalized relative path or throws naming the rule that fired.
///
/// The rules are deliberately literal: no path arithmetic, no unescaping, no
/// "helpful" trimming. `sub/../track01.bin` resolves to a perfectly safe location
/// and is still refused, because a parser that performs the resolution is a parser
/// whose idea of the final path can diverge from the filesystem's.
enum CuePath {
    /// APFS/HFS+ name limit. A longer component fails at write time with a
    /// cryptic errno; refusing it here produces a sentence a player can read.
    static let maximumComponentByteCount = 255
    /// Half of Darwin's `PATH_MAX` (1024, NUL included). The other half is the
    /// budget for what this path hangs off: the app container's Caches directory
    /// plus this disc's staging folder. A cap *at* `PATH_MAX` would let a
    /// reference through that still fails with `ENAMETOOLONG` once joined.
    static let maximumPathByteCount = 512
    /// What a `FILE` line may name. A cue sheet references its tracks; it never
    /// references another cue sheet, and staging one would put a download on top
    /// of the disc's own cue. The `.cue` and `.m3u` files RommpleTV writes itself
    /// go through `validate` without this check — see `CueStaging`.
    static let allowedTrackExtensions: Set<String> = ["bin", "sbi"]

    /// The safe relative spelling of a `FILE` reference, which must additionally
    /// name a track this build can play.
    static func validateTrackReference(_ reference: String) throws -> String {
        let path = try validate(reference)
        let name = String(path.split(separator: "/").last ?? "")
        let fileExtension = self.fileExtension(of: name)
        guard allowedTrackExtensions.contains(fileExtension.lowercased()) else {
            throw CueSheetError.unsupportedTrackExtension(reference, fileExtension: fileExtension)
        }
        return path
    }

    /// The safe relative spelling of `reference`, or a throw naming the rule.
    ///
    /// Path safety only: what the file at the end of it may be called is a
    /// separate question, asked by `validateTrackReference` of cue references and
    /// by `M3UWriter` of playlist entries, because the answer differs.
    ///
    /// Separators are normalized (`\` → `/`) *before* the component rules run, so
    /// `a\..\..\b` is judged as `a/../../b` rather than sailing through as one
    /// exotic filename.
    static func validate(_ reference: String) throws -> String {
        func reject(_ rejection: CueSheetError.Rejection) -> CueSheetError {
            .unsafeReference(reference, rejection: rejection)
        }

        guard !reference.isEmpty else { throw reject(.empty) }
        guard reference.utf8.count <= maximumPathByteCount else { throw reject(.pathTooLong) }

        // Control, format (RTL override, zero-width space, BOM) and line/paragraph
        // separators: characters that make a name display as something other than
        // what it is, or that could split one line into two for a different parser.
        for scalar in reference.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                throw reject(.controlCharacter)
            default:
                continue
            }
        }

        // Percent escapes: this code never unescapes, but anything downstream that
        // does would see a different path than the one validated here.
        let scalars = Array(reference.unicodeScalars)
        for index in scalars.indices where scalars[index] == "%" {
            if index + 2 < scalars.count,
               isHexDigit(scalars[index + 1]), isHexDigit(scalars[index + 2]) {
                throw reject(.percentEncoded)
            }
        }

        if reference.contains(":") {
            if reference.contains("://") { throw reject(.urlScheme) }
            let characters = Array(reference)
            if characters.count >= 2, characters[1] == ":",
               characters[0].isASCII, characters[0].isLetter {
                throw reject(.driveLetter)
            }
            throw reject(.colon)
        }

        let normalized = reference.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { throw reject(.absolutePath) }

        let components = normalized
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        for component in components {
            guard !component.isEmpty else { throw reject(.emptyComponent) }
            if component == "." { throw reject(.currentDirectory) }
            if component == ".." { throw reject(.parentDirectory) }
            if component.allSatisfy({ $0 == "." }) { throw reject(.dotsOnlyComponent) }
            if component.hasPrefix("~") { throw reject(.homeDirectory) }
            if component.hasPrefix("#") { throw reject(.leadingHash) }
            if component.hasPrefix(".") { throw reject(.hiddenComponent) }
            if component.first?.isWhitespace == true || component.last?.isWhitespace == true {
                throw reject(.whitespacePadding)
            }
            guard component.utf8.count <= maximumComponentByteCount else {
                throw reject(.componentTooLong)
            }
        }

        return components.joined(separator: "/")
    }

    /// The key two paths share when the destination filesystem would treat them as
    /// one file.
    ///
    /// `lowercased()` covers case folding; Unicode normalization is covered for
    /// free, because Swift compares and hashes strings by canonical equivalence, so
    /// the NFC and NFD spellings of the same name produce keys that are `==` and
    /// hash alike. Byte-level identity, where it matters, is taken with `Array(utf8)`
    /// instead — the two notions are not interchangeable here.
    static func foldedKey(_ path: String) -> String { path.lowercased() }

    /// The extension of a name whose leading dot has already been refused, so a
    /// dotfile can never be read as "all extension, no name".
    static func fileExtension(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...])
    }

    private static func isHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        Character(scalar).isHexDigit
    }
}

// MARK: - CueSheet

/// A parsed, validated cue sheet: the list of files it says the disc is made of.
///
/// The only way to obtain one is `parse`, so `fileReferences` carries an invariant
/// rather than a hope — every element is a safe, normalized, disc-relative path
/// with a supported extension, and no two of them collide on the destination
/// filesystem.
public struct CueSheet: Sendable {
    /// A cue sheet describes a CD; 8 tracks is typical and a few KB is large.
    /// Anything past a megabyte is not a cue sheet, and reading it is work a
    /// hostile server should not get for free.
    public static let maximumByteCount = 1 << 20
    /// Red Book allows 99 tracks, so 99 `FILE` lines is the ceiling.
    public static let maximumFileDirectives = 99

    /// Safe relative paths, in sheet order, exact duplicates collapsed.
    public let fileReferences: [String]

    private init(fileReferences: [String]) {
        self.fileReferences = fileReferences
    }

    /// UTF-8, then Windows-1252, then ISO-8859-1.
    ///
    /// The order matters and is not cosmetic: bytes 0x80–0x9F are printable
    /// punctuation in Windows-1252 (the encoding cue sheets from Windows rippers
    /// actually use) and C1 *control characters* in ISO-8859-1. Trying Latin-1
    /// first would turn a legitimate curly-quoted filename into a reference this
    /// parser then refuses for containing control characters.
    public static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else {
            throw CueSheetError.cueTooLarge(byteCount: data.count, limit: maximumByteCount)
        }
        // A UTF-8 byte order mark is dropped here, at the byte level, rather than
        // after decoding: Foundation's UTF-8 decoder already removes it, but the
        // 8-bit fallbacks do not — they turn it into three visible characters glued
        // to the first keyword, which would make the whole sheet parse as no sheet
        // at all.
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        for encoding in [String.Encoding.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: bytes, encoding: encoding) { return text }
        }
        throw CueSheetError.undecodableText
    }

    /// Scans line-oriented `FILE` directives and validates every reference.
    ///
    /// Only a line whose *first* whitespace-delimited token is `FILE` is a file
    /// directive. Quoted strings belonging to `REM`, `TITLE`, `PERFORMER` or any
    /// other keyword are text, not paths — which is why this is a scanner over
    /// lines and not a regex over quotes.
    public static func parse(_ text: String) throws -> CueSheet {
        guard text.utf8.count <= maximumByteCount else {
            throw CueSheetError.cueTooLarge(byteCount: text.utf8.count, limit: maximumByteCount)
        }
        guard !text.unicodeScalars.contains("\u{0000}") else { throw CueSheetError.nulByteInCue }

        var operands: [String] = []
        for (offset, line) in lines(of: text).enumerated() {
            if let operand = try fileOperand(in: line, number: offset + 1) {
                operands.append(operand)
            }
        }
        guard !operands.isEmpty else { throw CueSheetError.noFileDirectives }
        guard operands.count <= maximumFileDirectives else {
            throw CueSheetError.tooManyFileDirectives(count: operands.count,
                                                      limit: maximumFileDirectives)
        }

        var references: [String] = []
        var seenBytes: Set<[UInt8]> = []
        var filesByFoldedPath: [String: String] = [:]
        var directoriesByFoldedPath: [String: String] = [:]

        for operand in operands {
            let path = try CuePath.validateTrackReference(operand)
            // Two spellings that normalize to the same bytes name the same file at
            // the same place: one download, not a conflict.
            guard seenBytes.insert(Array(path.utf8)).inserted else { continue }

            let key = CuePath.foldedKey(path)
            if let existing = filesByFoldedPath[key] {
                throw CueSheetError.collidingReferences(existing, path, collision: .foldedName)
            }
            if let owner = directoriesByFoldedPath[key] {
                throw CueSheetError.collidingReferences(owner, path,
                                                        collision: .directoryOverFile)
            }
            var ancestor: [String] = []
            for component in path.split(separator: "/").dropLast() {
                ancestor.append(String(component))
                let ancestorKey = CuePath.foldedKey(ancestor.joined(separator: "/"))
                if let existing = filesByFoldedPath[ancestorKey] {
                    throw CueSheetError.collidingReferences(existing, path,
                                                            collision: .directoryOverFile)
                }
                directoriesByFoldedPath[ancestorKey] = path
            }
            filesByFoldedPath[key] = path
            references.append(path)
        }
        return CueSheet(fileReferences: references)
    }

    /// Matches every reference against the files RomM lists **for this disc**.
    ///
    /// There is no filesystem search and no library-wide lookup: a reference that
    /// is not in `files` is an error, not an invitation to go looking. The
    /// destination path is always the reference's own spelling — the downloaded
    /// track is renamed to suit the cue, never the other way round, because the
    /// cue is never rewritten and the emulator will open exactly what it names.
    public func resolve(against files: [RomFile]) throws -> [ResolvedCueFile] {
        let index = DiscFileIndex(files: files)
        return try fileReferences.map { reference in
            let matches = index.matches(for: reference)
            switch matches.count {
            case 1:
                return ResolvedCueFile(file: matches[0].file, relativeDestinationPath: reference)
            case 0:
                throw CueSheetError.referenceNotFound(reference)
            default:
                throw CueSheetError.ambiguousReference(
                    reference, matches: matches.map(\.relativePath).sorted())
            }
        }
    }

    // MARK: Directive scanning

    /// Lines split on LF, CR and CRLF only. Other Unicode line breaks stay inside
    /// the line, where the control-character rule refuses them: a name that this
    /// parser reads as one line and another parser reads as two is exactly the
    /// disagreement worth refusing.
    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
    }

    /// The file-type tokens the cue format defines. Used only to word the error
    /// for a malformed unquoted directive; no directive is accepted because of it.
    private static let fileTypes: Set<String> = ["binary", "motorola", "aiff", "wave", "mp3"]

    /// The operand of a `FILE` directive, or `nil` when the line is not one.
    private static func fileOperand(in line: String, number: Int) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let keyword = trimmed.prefix(while: { !$0.isWhitespace })
        guard keyword.lowercased() == "file" else { return nil }

        let remainder = trimmed.dropFirst(keyword.count).drop(while: { $0.isWhitespace })
        guard !remainder.isEmpty else {
            throw CueSheetError.malformedDirective(line: number, problem: .missingOperand)
        }

        if remainder.first == "\"" {
            let body = remainder.dropFirst()
            guard let closing = body.firstIndex(of: "\"") else {
                throw CueSheetError.malformedDirective(line: number, problem: .unterminatedQuote)
            }
            let tail = body[body.index(after: closing)...]
                .split(whereSeparator: { $0.isWhitespace })
            guard tail.count <= 1 else {
                throw CueSheetError.malformedDirective(line: number, problem: .trailingJunk)
            }
            return String(body[..<closing])
        }

        // Unquoted: the name is one word. The cue format requires quotes around a
        // name with spaces, and guessing where such a name ends is how a validator
        // starts interpreting. Both shapes below are refused; the file-type token
        // only decides which sentence the player is shown — `x.bin BINARY EXTRA`
        // is junk after a complete directive, `track 01.bin BINARY` is a name that
        // needed quotes.
        let tokens = remainder.split(whereSeparator: { $0.isWhitespace })
        if tokens.count > 2 {
            let problem: CueSheetError.DirectiveProblem =
                Self.fileTypes.contains(tokens[1].lowercased()) ? .trailingJunk
                                                                : .unquotedNameWithSpaces
            throw CueSheetError.malformedDirective(line: number, problem: problem)
        }
        return String(tokens[0])
    }
}

// MARK: - Resolution

/// One cue reference matched to the RomM file that satisfies it.
public struct ResolvedCueFile: Identifiable, Sendable {
    /// The server's record — the id, size and hashes the transfer needs.
    public let file: RomFile
    /// Where the bytes go, relative to this disc's staging directory. Always the
    /// cue's own spelling of the reference, normalized to `/` separators.
    public let relativeDestinationPath: String
    public var id: Int { file.id }

    init(file: RomFile, relativeDestinationPath: String) {
        self.file = file
        self.relativeDestinationPath = relativeDestinationPath
    }
}

/// The disc's files, keyed by the path each one has *relative to the disc*.
///
/// RomM reports `file_path` as a library-relative directory, so the disc's own
/// root is the longest directory prefix its files share. Files whose disc-relative
/// path is not a plain safe path — a `..` step the server put there, a `file_name`
/// carrying a separator — are dropped from the candidate set entirely, so no
/// reference can ever be satisfied by one.
private struct DiscFileIndex {
    struct Entry {
        let file: RomFile
        let relativePath: String
    }

    let entries: [Entry]

    init(files: [RomFile]) {
        let root = Self.commonRoot(of: files)
        entries = files.compactMap { file in
            guard let relative = Self.relativePath(of: file, under: root) else { return nil }
            return Entry(file: file, relativePath: relative)
        }
    }

    /// Byte-exact matches first; only when there are none does case (and Unicode
    /// normalization) folding apply, and then only a single survivor is accepted.
    func matches(for reference: String) -> [Entry] {
        let referenceBytes = Array(reference.utf8)
        let exact = entries.filter { Array($0.relativePath.utf8) == referenceBytes }
        if !exact.isEmpty { return exact }
        let key = CuePath.foldedKey(reference)
        return entries.filter { CuePath.foldedKey($0.relativePath) == key }
    }

    private static func directoryComponents(_ path: String) -> [String] {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
    }

    /// The longest directory prefix shared by every file that declares one. A file
    /// with an empty `file_path` sits at the disc root and is skipped here, so one
    /// such row cannot drag the root up and strand every other file.
    private static func commonRoot(of files: [RomFile]) -> [String] {
        var root: [String]?
        for file in files {
            let components = directoryComponents(file.filePath)
            guard !components.isEmpty else { continue }
            guard let current = root else { root = components; continue }
            root = zip(current, components).prefix(while: { $0 == $1 }).map(\.0)
        }
        return root ?? []
    }

    private static func relativePath(of file: RomFile, under root: [String]) -> String? {
        let directory = directoryComponents(file.filePath)
        var relativeDirectory: [String] = []
        if !directory.isEmpty {
            guard directory.count >= root.count,
                  Array(directory.prefix(root.count)) == root else { return nil }
            relativeDirectory = Array(directory.dropFirst(root.count))
        }
        let components = relativeDirectory + [file.fileName]
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.contains("/"), !component.contains("\\"),
                  !component.unicodeScalars.contains(where: { $0.value == 0 })
            else { return nil }
        }
        return components.joined(separator: "/")
    }
}

// MARK: - M3U

/// Writes the playlist that tells the core which cue sheets are the discs of one
/// game, in order.
public enum M3UWriter {
    /// One relative cue path per line, LF-terminated, UTF-8, no BOM, disc order
    /// preserved.
    ///
    /// The paths are validated again here rather than trusted: they are built from
    /// server-supplied names too, and a line the core would read as a directive or
    /// as a path outside the game folder must never be written.
    ///
    /// Validation is **all or nothing**. Dropping one bad entry from a three-disc
    /// game does not produce a playlist with a problem in it, it produces a
    /// *wrong* playlist: disc 3 silently becomes disc 2 and every index the player
    /// sees afterwards is off by one. An empty playlist is a failure the caller
    /// can see; a short one is a wrong answer nobody notices.
    public static func data(cuePaths: [String]) -> Data {
        var safe: [String] = []
        for path in cuePaths {
            guard let normalized = try? CuePath.validate(path),
                  let name = normalized.split(separator: "/").last,
                  CuePath.fileExtension(of: String(name)).lowercased() == "cue"
            else { return Data() }
            safe.append(normalized)
        }
        guard !safe.isEmpty else { return Data() }
        return Data(safe.map { $0 + "\n" }.joined().utf8)
    }
}

// MARK: - Staging

/// Turns a validated relative path into a URL under one disc's staging directory,
/// creating the directories it needs and nothing else.
public enum CueStaging {
    /// The URL `relativePath` must be written to, with its parent directories
    /// created beneath `stagingDirectory`.
    ///
    /// The path is validated again here — this is the last point before a write, and
    /// it is reached with strings that travelled through a downloader. Directories
    /// are created one component at a time so that an existing symlink or file is
    /// found *before* anything is created through it; `withIntermediateDirectories`
    /// would happily follow a symlink out of the disc folder.
    ///
    /// Path safety only: the track-extension whitelist deliberately does not apply,
    /// because the disc's own `.cue` and the generated `.m3u` are staged through
    /// this same function. What a cue may *reference* is decided in `CueSheet.parse`.
    @discardableResult
    public static func prepareDestination(for relativePath: String,
                                          in stagingDirectory: URL) throws -> URL {
        let normalized = try CuePath.validate(relativePath)
        let components = normalized.split(separator: "/").map(String.init)
        let manager = FileManager.default

        if !manager.fileExists(atPath: stagingDirectory.path) {
            try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        }

        var url = stagingDirectory
        for component in components.dropLast() {
            url.appendPathComponent(component, isDirectory: true)
            switch itemType(at: url) {
            case .none:
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
            case .some(.typeDirectory):
                continue
            case .some(.typeSymbolicLink):
                throw CueSheetError.destinationBlockedBySymlink(component)
            case .some:
                throw CueSheetError.destinationBlockedByFile(component)
            }
        }

        // The destination gets the same three-way check as every component before
        // it. Replacing a regular file is the ordinary re-download case; anything
        // else there is a write that cannot happen. Staging directories outlive a
        // run, so a directory left by an earlier cue that referenced
        // `x.bin/y.bin` is waiting for a later cue that references `x.bin`.
        let name = components[components.count - 1]
        url.appendPathComponent(name, isDirectory: false)
        switch itemType(at: url) {
        case .none, .some(.typeRegular):
            break
        case .some(.typeSymbolicLink):
            throw CueSheetError.destinationBlockedBySymlink(name)
        case .some:
            throw CueSheetError.destinationIsNotARegularFile(name)
        }

        // Backstop. The component walk above already refuses every way this can be
        // false, so this only catches a symlink that appeared while we worked.
        // Containment is judged on resolved paths, so a caller whose cache root is
        // itself a symlink still works.
        let root = stagingDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == root || parent.hasPrefix(root + "/") else {
            throw CueSheetError.destinationEscapesStagingDirectory(normalized)
        }
        return url
    }

    /// The item's own type, without following a final symlink.
    private static func itemType(at url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }
}
