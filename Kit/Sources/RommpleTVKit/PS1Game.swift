import Foundation

// MARK: - Model

/// One disc of a PlayStation game. `romID` is the RomM ROM id — the id Task 6
/// fetches full `RomDetails` for before transferring anything.
public struct PS1Disc: Identifiable, Sendable {
    public let romID: Int
    /// The entry's name without its extension: exactly the string the disc
    /// token was matched in.
    public let fileStem: String
    /// 1-based disc number, after mapping letter tokens (A–Z) onto 1–26.
    public let index: Int
    /// Display string for the disc-switch overlay.
    public let label: String
    public var id: Int { romID }

    public init(romID: Int, fileStem: String, index: Int, label: String) {
        self.romID = romID
        self.fileStem = fileStem
        self.index = index
        self.label = label
    }
}

/// The result of classifying one RomM metadata group. A group is *not* the same
/// thing as a multi-disc game, so `discs` frequently holds the representative
/// alone while `excludedSiblings` holds everything the group merely shares
/// metadata with.
public struct PS1Game: Identifiable, Sendable {
    public let representative: Rom
    /// The ROM id that owns the game/save identity: disc 1 when a disc set was
    /// recognized, otherwise the representative itself.
    public let canonicalRomID: Int
    /// Sorted by `index`, always non-empty, always contiguous from 1.
    public let discs: [PS1Disc]
    /// Group members that are separate games, in the order RomM listed them.
    public let excludedSiblings: [SiblingRom]
    public var id: Int { representative.id }

    public init(representative: Rom, canonicalRomID: Int, discs: [PS1Disc],
                excludedSiblings: [SiblingRom]) {
        self.representative = representative
        self.canonicalRomID = canonicalRomID
        self.discs = discs
        self.excludedSiblings = excludedSiblings
    }
}

// MARK: - Token recognition

/// A recognized disc token and where it sits in the name it was found in.
/// `range` indexes the `Character` array of that same name.
struct DiscToken {
    let index: Int
    /// The `N` of a `1 of N` token, when the filename declared one. The
    /// classifier refuses to merge a set that contradicts it.
    let total: Int?
    let range: Range<Int>
    var label: String { "Disc \(index)" }
}

/// Recognizes the single disc token in a file stem.
///
/// The grammar is deliberately hand-scanned rather than expressed as a regex:
/// every boundary below is an explicit, individually testable condition.
///
///     token   := boundary keyword value boundary
///     keyword := "disc" | "disk" | "cd"            (case-insensitive)
///     value   := sep* number ( sep+ "of" sep* number )?
///              | sep+ letter                       (not after "cd")
///     number  := ASCII digits, value > 0            (leading zeros allowed)
///     letter  := one ASCII letter A–Z → 1–26
///     sep     := space | tab | "." | "-" | "_"
///
/// The two boundaries are what keep title text out: the character before the
/// keyword and the character after the value must both be non-alphanumeric (or
/// absent). That alone rejects `Discworld` (keyword glued to `world`) and
/// `Abcd 2` (keyword glued to `Ab`). The `sep+` before a single letter is the
/// third guard: without it, `Disco Inferno` would read as `Disc O` — a token
/// with a plausible-looking index, which is far more dangerous than no token.
/// The fourth is that `cd` takes no letter value at all: `CD-i`, `CD-R` and
/// `CD-X` are product names, and letter-numbered rips in the wild are written
/// `Disc A`/`Disk A`, never `CD A`.
enum DiscTokenScanner {
    private static let keywords: [(characters: [Character], allowsLetterValue: Bool)] = [
        (Array("disc"), true), (Array("disk"), true), (Array("cd"), false),
    ]
    private static let separators: Set<Character> = [" ", "\t", ".", "-", "_"]

    /// Every disc token in `name`, left to right, non-overlapping.
    static func tokens(in name: String) -> [DiscToken] {
        let chars = Array(name)
        var found: [DiscToken] = []
        var i = 0
        while i < chars.count {
            if let token = token(in: chars, at: i) {
                found.append(token)
                i = token.range.upperBound
            } else {
                i += 1
            }
        }
        return found
    }

    /// The token in `name`, or `nil` when there is none or more than one.
    /// A filename bearing more than one disc token never matches.
    static func soleToken(in name: String) -> DiscToken? {
        let all = tokens(in: name)
        return all.count == 1 ? all[0] : nil
    }

    /// The case-folded title with *only* the recognized token removed. Region
    /// and revision text — `(USA)`, `(Europe)`, `(Rev 1)` — survives, so those
    /// variants never compare equal to each other.
    ///
    /// Two cosmetic normalizations apply so that the same title written
    /// `… (Disc 1)` and `… - CD2` still compares equal: a bracket pair that the
    /// token exactly filled is dropped with it, and whitespace runs collapse
    /// before trimming stray separators from the ends.
    static func normalizedBase(of name: String, removing token: DiscToken) -> String {
        var chars = Array(name)
        var lower = token.range.lowerBound
        var upper = token.range.upperBound
        if lower > 0, upper < chars.count, isBracketPair(chars[lower - 1], chars[upper]) {
            lower -= 1
            upper += 1
        }
        chars.removeSubrange(lower..<upper)
        let collapsed = String(chars)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
            .lowercased()
    }

    // MARK: Scanner internals

    private static func isBracketPair(_ open: Character, _ close: Character) -> Bool {
        (open == "(" && close == ")")
            || (open == "[" && close == "]")
            || (open == "{" && close == "}")
    }

    /// Alphanumeric in the boundary sense. `_`, `-` and `.` are deliberately
    /// *not* word characters: they are filename separators.
    private static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static func token(in chars: [Character], at start: Int) -> DiscToken? {
        // Leading boundary: the keyword may not continue a word.
        if start > 0, isWordCharacter(chars[start - 1]) { return nil }
        guard let keyword = matchKeyword(chars, at: start) else { return nil }

        var cursor = keyword.end
        var separatorCount = 0
        while cursor < chars.count, separators.contains(chars[cursor]) {
            cursor += 1
            separatorCount += 1
        }
        guard cursor < chars.count else { return nil }

        if let (value, total, end) = matchNumber(chars, from: cursor) {
            return DiscToken(index: value, total: total, range: start..<end)
        }
        // A single letter needs a separator, and never follows `cd`; see the
        // type comment.
        if keyword.allowsLetterValue, separatorCount > 0,
           let (value, end) = matchLetter(chars, from: cursor) {
            return DiscToken(index: value, total: nil, range: start..<end)
        }
        return nil
    }

    private static func matchKeyword(_ chars: [Character],
                                     at start: Int) -> (end: Int, allowsLetterValue: Bool)? {
        for keyword in keywords {
            guard start + keyword.characters.count <= chars.count else { continue }
            var matched = true
            for (offset, expected) in keyword.characters.enumerated()
            where chars[start + offset].lowercased() != String(expected) {
                matched = false
                break
            }
            if matched {
                return (start + keyword.characters.count, keyword.allowsLetterValue)
            }
        }
        return nil
    }

    /// A positive Arabic number plus an optional `of N` tail. Returns the disc
    /// index, the declared total when there was one, and the end of the value.
    private static func matchNumber(_ chars: [Character],
                                    from start: Int) -> (index: Int, total: Int?, end: Int)? {
        guard let (value, afterDigits) = matchDigits(chars, from: start), value > 0 else {
            return nil
        }
        // Trailing boundary: all consecutive ASCII digits were consumed, so any
        // alphanumeric still sitting here means the value ran into a word.
        if afterDigits < chars.count, isWordCharacter(chars[afterDigits]) { return nil }
        if let (total, end) = matchOfCount(chars, from: afterDigits) {
            return (value, total, end)
        }
        return (value, nil, afterDigits)
    }

    private static func matchDigits(_ chars: [Character], from start: Int) -> (Int, Int)? {
        var cursor = start
        var digits = ""
        while cursor < chars.count, chars[cursor].isASCII, chars[cursor].isNumber {
            digits.append(chars[cursor])
            cursor += 1
        }
        // `Int(_:)` also rejects an absurdly long run of digits.
        guard !digits.isEmpty, let value = Int(digits) else { return nil }
        return (value, cursor)
    }

    /// The optional `of N` tail of `Disk 1 of 3`, returning the declared total
    /// and the end of the tail. `of` that is not followed by a number is title
    /// text and stays out of the token.
    private static func matchOfCount(_ chars: [Character],
                                     from start: Int) -> (total: Int, end: Int)? {
        var cursor = start
        var separatorCount = 0
        while cursor < chars.count, separators.contains(chars[cursor]) {
            cursor += 1
            separatorCount += 1
        }
        guard separatorCount > 0, cursor + 2 <= chars.count,
              chars[cursor].lowercased() == "o", chars[cursor + 1].lowercased() == "f"
        else { return nil }
        cursor += 2
        while cursor < chars.count, separators.contains(chars[cursor]) { cursor += 1 }
        guard let (total, afterDigits) = matchDigits(chars, from: cursor), total > 0 else {
            return nil
        }
        if afterDigits < chars.count, isWordCharacter(chars[afterDigits]) { return nil }
        return (total, afterDigits)
    }

    /// One ASCII letter A–Z mapped onto 1–26.
    private static func matchLetter(_ chars: [Character], from start: Int) -> (Int, Int)? {
        let candidate = chars[start]
        guard candidate.isASCII, candidate.isLetter else { return nil }
        let end = start + 1
        // Trailing boundary: `Disc A1` and `Disc AB` are not disc tokens.
        if end < chars.count, isWordCharacter(chars[end]) { return nil }
        guard let scalar = candidate.uppercased().unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else { return nil }
        return (Int(scalar.value) - 64, end)
    }
}

// MARK: - Classification

/// Decides which entries of a RomM metadata group are genuinely discs of one
/// game. Pure: no I/O, no paging, no fetching. The classifier yields ROM ids
/// and file stems only.
public enum PS1GameClassifier {
    /// - Warning: A title whose own text ends in a disc-token shape is
    ///   indistinguishable from a real disc token by filename alone, and the
    ///   sequence rule only defends the singleton case. A demo series named
    ///   `Neon Monthly Demo Disc 1 (USA)` / `… Disc 2 (USA)` under one meta id
    ///   normalizes to the same base, is contiguous from 1, and contains the
    ///   representative — so it **will** merge into a bogus two-disc game with
    ///   an M3U. Two separately numbered products, one launch. Neither a
    ///   filename rule nor RomM metadata distinguishes this case; the defense
    ///   has to be in the UI. Task 10 should make the resolved disc set visible
    ///   and let the player override it (launch a single disc).
    public static func classify(_ representative: Rom) -> PS1Game {
        let stem = fileStem(for: representative)
        let siblings = deduplicated(representative.siblingRoms, excludingID: representative.id)

        // The representative must carry exactly one token before any merge is
        // allowed. This is what stops a collection's metadata group — whose
        // head has no disc token — from absorbing the disc pair buried in it.
        guard let representativeToken = DiscTokenScanner.soleToken(in: stem) else {
            return singleDisc(representative, stem: stem, excluding: siblings)
        }
        let base = DiscTokenScanner.normalizedBase(of: stem, removing: representativeToken)

        var discs = [PS1Disc(romID: representative.id, fileStem: stem,
                             index: representativeToken.index,
                             label: representativeToken.label)]
        var declaredTotals: [Int] = representativeToken.total.map { [$0] } ?? []
        var excluded: [SiblingRom] = []
        for sibling in siblings {
            let siblingStem = sibling.fsNameNoExt
            guard let token = DiscTokenScanner.soleToken(in: siblingStem),
                  DiscTokenScanner.normalizedBase(of: siblingStem, removing: token) == base
            else {
                excluded.append(sibling)
                continue
            }
            discs.append(PS1Disc(romID: sibling.id, fileStem: siblingStem,
                                 index: token.index, label: token.label))
            if let total = token.total { declaredTotals.append(total) }
        }
        discs.sort { ($0.index, $0.romID) < ($1.index, $1.romID) }

        // Reject rather than guess: a partial set produces a game that cannot
        // boot, which is worse than treating the representative as single-disc.
        guard isValidSequence(discs, declaredTotals: declaredTotals,
                              containing: representative.id) else {
            return singleDisc(representative, stem: stem, excluding: siblings)
        }
        return PS1Game(representative: representative,
                       canonicalRomID: discs[0].romID,
                       discs: discs,
                       excludedSiblings: excluded)
    }

    /// The representative's stem, preferring RomM's own `fs_name_no_ext`.
    ///
    /// Siblings' stems are server-computed, so the representative's must be too
    /// or the two sides can disagree and the merge silently fails. RomM does not
    /// split on the last dot: for an extension-less folder ROM it returns
    /// `fs_name_no_ext` identical to `fs_name`, dots and all. The local
    /// computation below is only a fallback for servers that omit the field.
    static func fileStem(for rom: Rom) -> String {
        if let serverStem = rom.fsNameNoExt, !serverStem.isEmpty { return serverStem }
        return fileStem(forFSName: rom.fsName)
    }

    /// The name without its extension. Only a short, letter-bearing extension
    /// is stripped, so a folder-style `fs_name` carrying a version dot
    /// (`… v1.1 (USA) (Disc 1)`) survives intact. This is a heuristic and is
    /// not identical to RomM's own rule — prefer `fileStem(for:)`.
    static func fileStem(forFSName fsName: String) -> String {
        guard let dot = fsName.lastIndex(of: "."), dot != fsName.startIndex else { return fsName }
        let ext = fsName[fsName.index(after: dot)...]
        guard !ext.isEmpty, ext.count <= 5,
              ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext.contains(where: { $0.isLetter })
        else { return fsName }
        return String(fsName[..<dot])
    }

    /// First occurrence wins; the representative is never its own sibling.
    private static func deduplicated(_ siblings: [SiblingRom],
                                     excludingID representativeID: Int) -> [SiblingRom] {
        var seen: Set<Int> = [representativeID]
        var unique: [SiblingRom] = []
        for sibling in siblings where seen.insert(sibling.id).inserted {
            unique.append(sibling)
        }
        return unique
    }

    /// Starts at 1, unique contiguous indices, contains the representative, and
    /// does not contradict any `of N` total the filenames declared.
    ///
    /// The totals rule is the difference between "contiguous" and "complete":
    /// `Disk 1 of 3` + `Disk 2 of 3` is contiguous from 1 and would otherwise
    /// merge into a two-disc game for a three-disc title. Every declared total
    /// must agree with every other and with the number of discs found.
    private static func isValidSequence(_ discs: [PS1Disc], declaredTotals: [Int],
                                        containing representativeID: Int) -> Bool {
        // Holds by construction — `discs` is seeded with the representative and
        // never filtered — but the rule is cheap to keep honest.
        guard !discs.isEmpty,
              discs.contains(where: { $0.romID == representativeID }) else { return false }
        for (offset, disc) in discs.enumerated() where disc.index != offset + 1 {
            return false
        }
        let declared = Set(declaredTotals)
        if let total = declared.first {
            guard declared.count == 1, total == discs.count else { return false }
        }
        return true
    }

    private static func singleDisc(_ representative: Rom, stem: String,
                                   excluding siblings: [SiblingRom]) -> PS1Game {
        let disc = PS1Disc(romID: representative.id, fileStem: stem, index: 1, label: "Disc 1")
        return PS1Game(representative: representative,
                       canonicalRomID: representative.id,
                       discs: [disc],
                       excludedSiblings: siblings)
    }
}
