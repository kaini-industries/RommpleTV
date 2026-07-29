import XCTest
@testable import RommpleTVKit

// All titles here are invented. They reproduce the *shapes* that break naive
// classifiers (metadata groups that are not disc sets, title text containing
// the keywords, ambiguous "CD" titles) without naming real library content.
final class PS1GameTests: XCTestCase {

    // MARK: - Fixtures

    /// `fsNameNoTags` is deliberately set to a sentinel that can never match a
    /// base title. The classifier must read `fsNameNoExt` only — region text
    /// lives in the tagged name and is load-bearing for the comparison rules.
    private func sib(_ id: Int, _ stem: String, main: Bool = false) -> SiblingRom {
        SiblingRom(id: id, name: stem, fsNameNoTags: "sentinel-do-not-use-\(id)",
                   fsNameNoExt: stem, isMainSibling: main)
    }

    /// `noExt` is RomM's own `fs_name_no_ext`. Left `nil` in most fixtures so the
    /// local fallback stays covered; set explicitly where the server value is
    /// the thing under test.
    private func rom(_ id: Int, _ fsName: String, siblings: [SiblingRom] = [],
                     noExt: String? = nil) -> Rom {
        Rom(id: id, name: nil, fsName: fsName, platformId: 33, sizeBytes: nil,
            coverPath: nil, siblingRoms: siblings, fsNameNoExt: noExt)
    }

    private func index(_ stem: String) -> Int? {
        DiscTokenScanner.soleToken(in: stem)?.index
    }

    private func base(_ stem: String) -> String? {
        guard let token = DiscTokenScanner.soleToken(in: stem) else { return nil }
        return DiscTokenScanner.normalizedBase(of: stem, removing: token)
    }

    // MARK: - Token recognition: accepted forms

    func testAcceptedTokenForms() {
        let expected: [String: Int] = [
            "Chrono Bastion (USA) (Disc 1)": 1,
            "Chrono Bastion (USA) (Disc 2)": 2,
            "Chrono Bastion (USA) (Disc 01)": 1,
            "Chrono Bastion (USA) (Disc 12)": 12,
            "Chrono Bastion (USA) (disc 3)": 3,
            "Chrono Bastion (USA) (DISC 4)": 4,
            "Chrono Bastion (USA) (Disk 1 of 3)": 1,
            "Chrono Bastion (USA) (Disk 2 of 3)": 2,
            "Chrono Bastion (USA) - CD1": 1,
            "Chrono Bastion (USA) - CD 2": 2,
            "Chrono Bastion (USA) - cd3": 3,
            "Chrono Bastion (USA) - Disc 2": 2,
            "Chrono_Bastion_Disc_3": 3,
            "Chrono Bastion (USA) (Disc A)": 1,
            "Chrono Bastion (USA) (Disc B)": 2,
            "Chrono Bastion (USA) (Disc z)": 26,
            "Chrono Bastion (USA) (CD-1)": 1,
            "Chrono Bastion (USA) (Disc 1 of 2)": 1,
        ]
        for (stem, want) in expected {
            XCTAssertEqual(index(stem), want, stem)
        }
    }

    func testEveryLetterAToZMapsOntoOneThroughTwentySix() {
        for (offset, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() {
            XCTAssertEqual(index("Vault Runner (Disc \(letter))"), offset + 1, String(letter))
            XCTAssertEqual(index("Vault Runner (Disk \(letter.lowercased()))"), offset + 1,
                           letter.lowercased())
        }
    }

    func testLetterValuesNeverFollowTheCDKeyword() {
        // `CD-i`, `CD-R`, `CD-X` are product names, not disc numbers.
        for stem in ["Vault Runner (CD-i Version)", "Vault Runner (CD-R Edition)",
                     "Vault Runner (CD-X Remix)", "Vault Runner - CD A"] {
            XCTAssertNil(DiscTokenScanner.soleToken(in: stem), stem)
        }
        // The numeric form after `cd` is untouched.
        XCTAssertEqual(index("Vault Runner - CD-1"), 1)
        XCTAssertEqual(index("Vault Runner - CD 2"), 2)
    }

    func testDeclaredTotalIsCarriedOnTheToken() {
        XCTAssertEqual(DiscTokenScanner.soleToken(in: "Vault Runner (Disk 2 of 3)")?.total, 3)
        XCTAssertEqual(DiscTokenScanner.soleToken(in: "Vault Runner (Disc 1 of 2)")?.total, 2)
        XCTAssertNil(DiscTokenScanner.soleToken(in: "Vault Runner (Disc 1)")?.total)
        XCTAssertNil(DiscTokenScanner.soleToken(in: "Vault Runner (Disc 1 of the Ancients)")?.total)
    }

    // MARK: - Token recognition: boundaries and rejections

    // Every entry here would match a sloppier recognizer (one that skips the
    // leading boundary, the trailing boundary, or the separator before a
    // single-letter value).
    func testTitleTextNeverMatches() {
        let rejected = [
            "Discworld (USA)",                      // keyword glued to title text
            "Discworld II - Presumed Missing (USA)",
            "Discovery Channel (USA)",
            "Disco Inferno (USA)",                  // "Disc" + "o" needs a separator
            "Discs of Thunder (USA)",               // "Disc" + "s"
            "Disklavier Concert (Europe)",
            "Abcd 2 (USA)",                         // "cd" glued to a preceding word
            "McDonnell Skies 3 (USA)",              // "cD" inside a word
            "Arcade Anthology 2 (USA)",             // no keyword at all
            "Sound Test CD (USA)",                  // keyword with no value
            "CD Compendium (USA)",                  // keyword followed by a word
            "Vault Runner (Disc)",                  // bare keyword
            "Vault Runner (Disc 0)",                // zero is not a positive number
            "Vault Runner (Disc AB)",               // two letters
            "Vault Runner (Disc 1a)",               // digit glued to a letter
            "Vault Runner (Disc A1)",               // letter glued to a digit
            "Vault Runner (Bonus Disc)",
            "Vault Runner (Rev 1)",
            "Vault Runner (Beta)",
            "Vault Runner (USA)",
            "Vault Runner (CD-i Version)",           // product name, not a disc letter
            "Vault Runner (CD-R Edition)",
            "Vault Runner (CD-ROM Edition)",
        ]
        for stem in rejected {
            XCTAssertNil(DiscTokenScanner.soleToken(in: stem), stem)
            XCTAssertTrue(DiscTokenScanner.tokens(in: stem).isEmpty, stem)
        }
    }

    func testKeywordInTitleTextDoesNotAddASecondToken() {
        // A real disc token in a title that also *contains* the keyword as text.
        let stem = "Discworld II - Presumed Missing (USA) (Disc 1)"
        XCTAssertEqual(DiscTokenScanner.tokens(in: stem).count, 1)
        XCTAssertEqual(index(stem), 1)
    }

    func testMoreThanOneTokenIsNotASoleToken() {
        for stem in ["Chrono Bastion (USA) (Disc 1) (Disc 2)",
                     "Chrono Bastion (USA) CD1 - Disc 2",
                     "Chrono Bastion (Disk 1 of 2) (Disc 1)"] {
            XCTAssertGreaterThan(DiscTokenScanner.tokens(in: stem).count, 1, stem)
            XCTAssertNil(DiscTokenScanner.soleToken(in: stem), stem)
        }
    }

    func testOfClauseOnlyConsumesADigitCount() {
        // "of" not followed by a number is title text, not part of the token.
        let stem = "Chrono Bastion (Disc 1 of the Ancients)"
        XCTAssertEqual(index(stem), 1)
        XCTAssertEqual(base(stem)?.contains("ancients"), true)
    }

    // MARK: - Base normalization

    func testBasePreservesRegionAndRevisionText() {
        XCTAssertEqual(base("Chrono Bastion (USA) (Disc 1)"),
                       base("Chrono Bastion (USA) (Disc 2)"))
        XCTAssertNotEqual(base("Chrono Bastion (USA) (Disc 1)"),
                          base("Chrono Bastion (Europe) (Disc 1)"))
        XCTAssertNotEqual(base("Chrono Bastion (USA) (Disc 1)"),
                          base("Chrono Bastion (USA) (Rev 1) (Disc 1)"))
        XCTAssertNotEqual(base("Chrono Bastion (USA) (Disc 1)"),
                          base("Chrono Bastion (USA) (Beta) (Disc 1)"))
    }

    func testBaseIsCaseFoldedAndPunctuationOfTheTokenIsRemoved() {
        XCTAssertEqual(base("Chrono Bastion (USA) (DISC 1)"),
                       base("chrono bastion (usa) - cd2"))
    }

    // Pins the exact contract the relative assertions above rely on.
    func testBaseProducesTheseExactStrings() {
        XCTAssertEqual(base("Chrono Bastion (USA) (Disc 1)"), "chrono bastion (usa)")
        XCTAssertEqual(base("Chrono Bastion (USA) - CD2"), "chrono bastion (usa)")
        XCTAssertEqual(base("Chrono_Bastion_Disc_3"), "chrono_bastion")
        XCTAssertEqual(base("Chrono Bastion (USA) (Rev 1) (Disk 2 of 3)"),
                       "chrono bastion (usa) (rev 1)")
        XCTAssertEqual(base("Chrono Bastion (USA) (Bonus Disc 1)"), "chrono bastion (usa) (bonus )")
    }

    // MARK: - Classification: genuine disc sets

    func testTwoDiscGroupSortsNumerically() {
        let rep = rom(10, "Chrono Bastion (USA) (Disc 1).cue",
                      siblings: [sib(11, "Chrono Bastion (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.discs.map(\.romID), [10, 11])
        XCTAssertEqual(game.discs.map(\.label), ["Disc 1", "Disc 2"])
        XCTAssertEqual(game.discs.map(\.fileStem),
                       ["Chrono Bastion (USA) (Disc 1)", "Chrono Bastion (USA) (Disc 2)"])
        XCTAssertEqual(game.canonicalRomID, 10)
        XCTAssertTrue(game.excludedSiblings.isEmpty)
    }

    func testDiscsArriveOutOfOrderAndStillSortNumerically() {
        let rep = rom(10, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(13, "Chrono Bastion (USA) (Disc 4)"),
            sib(12, "Chrono Bastion (USA) (Disc 3)"),
            sib(11, "Chrono Bastion (USA) (Disc 2)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(game.discs.map(\.romID), [10, 11, 12, 13])
    }

    func testDiskOfNTokens() {
        let rep = rom(20, "Vault Runner (USA) (Disk 1 of 3).chd", siblings: [
            sib(21, "Vault Runner (USA) (Disk 2 of 3)"),
            sib(22, "Vault Runner (USA) (Disk 3 of 3)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2, 3])
        XCTAssertEqual(game.discs.map(\.label), ["Disc 1", "Disc 2", "Disc 3"])
        XCTAssertEqual(game.canonicalRomID, 20)
    }

    func testIncompleteOfNSetCollapsesToSingleDisc() {
        // Contiguous from 1, but the filenames say a third disc exists.
        let rep = rom(300, "Vault Runner (USA) (Disk 1 of 3).chd",
                      siblings: [sib(301, "Vault Runner (USA) (Disk 2 of 3)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [300],
                       "two discs of a three-disc title must not merge")
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 300)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [301])
    }

    func testMismatchedOfNTotalsCollapseToSingleDisc() {
        let rep = rom(310, "Vault Runner (USA) (Disk 1 of 2).chd",
                      siblings: [sib(311, "Vault Runner (USA) (Disk 2 of 3)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [310])
        XCTAssertEqual(game.excludedSiblings.map(\.id), [311])
    }

    /// The case that pins *which* totals rule is in force, which the test above
    /// cannot: `1 of 2` + `2 of 3` is rejected by the weaker "every total must
    /// agree with the disc count" rule too (max is 3, two discs found), so with
    /// `declared.count == 1` deleted the whole suite stays green.
    ///
    /// `1 of 1` + `2 of 2` is the input that separates them. Two discs found, and
    /// a rule reading only the largest total sees 2 == 2 and merges — a game
    /// whose own filenames each say they are complete on their own. It also
    /// pins the reason the clause cannot simply be dropped: `declared` is a
    /// `Set`, so with the count check gone `declared.first` is an arbitrary one
    /// of {1, 2} and the merge decision for this input is not even deterministic.
    func testTotalsThatDisagreeWhileMatchingTheDiscCountStillCollapse() {
        let rep = rom(340, "Vault Runner (USA) (Disc 1 of 1).chd",
                      siblings: [sib(341, "Vault Runner (USA) (Disc 2 of 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [340],
                       "two discs each declaring a different total must not merge")
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 340)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [341])
    }

    func testATotalDeclaredOnOnlyOneDiscStillGoverns() {
        let complete = rom(320, "Vault Runner (USA) (Disc 1 of 2).chd",
                           siblings: [sib(321, "Vault Runner (USA) (Disc 2)")])
        XCTAssertEqual(PS1GameClassifier.classify(complete).discs.map(\.romID), [320, 321])

        let short = rom(330, "Vault Runner (USA) (Disc 1 of 3).chd",
                        siblings: [sib(331, "Vault Runner (USA) (Disc 2)")])
        XCTAssertEqual(PS1GameClassifier.classify(short).discs.map(\.romID), [330])
    }

    func testCDTokensSeparatedFromTitleText() {
        let rep = rom(30, "Harbor Detective (USA) - CD1.cue",
                      siblings: [sib(31, "Harbor Detective (USA) - CD2")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.canonicalRomID, 30)
        XCTAssertTrue(game.excludedSiblings.isEmpty)
    }

    func testDiscLettersMapToOneAndTwo() {
        let rep = rom(40, "Harbor Detective (Europe) (Disc A).cue",
                      siblings: [sib(41, "Harbor Detective (Europe) (Disc B)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.discs.map(\.label), ["Disc 1", "Disc 2"])
        XCTAssertEqual(game.canonicalRomID, 40)
    }

    func testDiscOneIsCanonicalWhenRepresentativeIsDiscTwo() {
        let rep = rom(51, "Chrono Bastion (USA) (Disc 2).cue",
                      siblings: [sib(50, "Chrono Bastion (USA) (Disc 1)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.canonicalRomID, 50)
        XCTAssertEqual(game.id, 51, "the card identity stays the server's representative")
    }

    func testIdentifiers() {
        let rep = rom(60, "Chrono Bastion (USA) (Disc 1).cue",
                      siblings: [sib(61, "Chrono Bastion (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.id, rep.id)
        XCTAssertEqual(game.representative.id, 60)
        for disc in game.discs {
            XCTAssertEqual(disc.id, disc.romID)
        }
        XCTAssertEqual(game.discs.map(\.id), [60, 61])
    }

    // MARK: - Classification: independence

    func testRegionVariantsWithoutTokensStayIndependent() {
        let rep = rom(70, "Chrono Bastion (USA).cue",
                      siblings: [sib(71, "Chrono Bastion (Europe)"),
                                 sib(72, "Chrono Bastion (Japan)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.count, 1)
        XCTAssertEqual(game.discs.map(\.romID), [70])
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.discs.map(\.label), ["Disc 1"])
        XCTAssertEqual(game.canonicalRomID, 70)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [71, 72])
    }

    func testRegionVariantsWithTokensDoNotMerge() {
        let rep = rom(80, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(81, "Chrono Bastion (Europe) (Disc 1)"),
            sib(82, "Chrono Bastion (Europe) (Disc 2)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [80])
        XCTAssertEqual(game.canonicalRomID, 80)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [81, 82])
    }

    func testBonusRevisionAndBetaSiblingsStayIndependent() {
        let rep = rom(90, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(91, "Chrono Bastion (USA) (Disc 2)"),
            sib(92, "Chrono Bastion (USA) (Bonus Disc)"),
            sib(93, "Chrono Bastion (USA) (Bonus Disc 1)"),
            sib(94, "Chrono Bastion (USA) (Rev 1)"),
            sib(95, "Chrono Bastion (USA) (Beta)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [90, 91])
        XCTAssertEqual(game.excludedSiblings.map(\.id), [92, 93, 94, 95])
    }

    func testSiblingWithMoreThanOneTokenIsExcluded() {
        let rep = rom(100, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(101, "Chrono Bastion (USA) (Disc 2)"),
            sib(102, "Chrono Bastion (USA) (Disc 3) (Disc 4)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [100, 101])
        XCTAssertEqual(game.excludedSiblings.map(\.id), [102])
    }

    func testRepresentativeWithMoreThanOneTokenNeverMerges() {
        let rep = rom(110, "Chrono Bastion (USA) (Disc 1) (Disc 2).cue",
                      siblings: [sib(111, "Chrono Bastion (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [110])
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 110)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [111])
    }

    func testDiscworldStyleTitlesStayIndependent() {
        let rep = rom(120, "Discworld (USA).cue", siblings: [
            sib(121, "Discworld II - Presumed Missing (USA)"),
            sib(122, "Disco Inferno (USA)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [120])
        XCTAssertEqual(game.excludedSiblings.map(\.id), [121, 122])
    }

    func testDiscworldStyleTitleStillMergesItsOwnRealDiscs() {
        let rep = rom(130, "Discworld II - Presumed Missing (USA) (Disc 1).cue",
                      siblings: [sib(131, "Discworld II - Presumed Missing (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.canonicalRomID, 130)
    }

    // MARK: - Classification: reject rather than guess

    func testMissingDiscOneInvalidatesTheSequence() {
        let rep = rom(140, "Chrono Bastion (USA) (Disc 2).cue",
                      siblings: [sib(141, "Chrono Bastion (USA) (Disc 3)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [140], "no partial set may be emitted")
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 140)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [141])
    }

    func testGapInTheSequenceInvalidatesTheSequence() {
        let rep = rom(150, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(151, "Chrono Bastion (USA) (Disc 2)"),
            sib(152, "Chrono Bastion (USA) (Disc 4)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [150])
        XCTAssertEqual(game.canonicalRomID, 150)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [151, 152])
    }

    func testDuplicateDiscNumbersInvalidateTheSequence() {
        let rep = rom(160, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(161, "Chrono Bastion (USA) (Disc 2)"),
            sib(162, "Chrono Bastion (USA) (Disc 2)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [160])
        XCTAssertEqual(game.excludedSiblings.map(\.id), [161, 162])
    }

    func testMixedAlphabeticAndNumericDuplicatesAreRejected() {
        let rep = rom(170, "Chrono Bastion (USA) (Disc 1).cue",
                      siblings: [sib(171, "Chrono Bastion (USA) (Disc A)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [170], "Disc A and Disc 1 are both index 1")
        XCTAssertEqual(game.excludedSiblings.map(\.id), [171])
    }

    func testAmbiguousCDTitleFallsBackToSingleDisc() {
        // "Comet CD 2" reads as a token by construction; the sequence rule is
        // the safety net that stops it from launching as a partial set.
        let rep = rom(180, "Comet CD 2 (USA).cue",
                      siblings: [sib(181, "Comet CD (USA)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [180])
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 180)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [181])
    }

    // MARK: - The collection case

    // Structure of the acceptance case: a metadata group headed by a
    // representative with no disc token, whose siblings contain one genuine
    // disc pair plus unrelated titles.
    private var collectionSiblings: [SiblingRom] {
        [sib(201, "Lantern Compendium - Lantern (USA)"),
         sib(202, "Lantern Compendium - Lantern II (USA)"),
         sib(203, "Lantern Compendium - Lantern III (USA) (Disc 1)"),
         sib(204, "Lantern Compendium - Lantern III (USA) (Disc 2)"),
         sib(205, "Lantern Compendium - The Chronicle of Lantern (USA)")]
    }

    func testCollectionRepresentativeWithoutATokenYieldsASingleDisc() {
        let rep = rom(200, "Lantern Compendium - Beast Cup (USA).cue",
                      siblings: collectionSiblings)
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [200],
                       "a tokenless representative can never merge")
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.canonicalRomID, 200)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [201, 202, 203, 204, 205],
                       "the genuine disc pair is excluded too")
    }

    func testCollectionRepresentativeThatIsDiscOneMergesOnlyItsOwnDiscs() {
        let rep = rom(203, "Lantern Compendium - Lantern III (USA) (Disc 1).cue", siblings: [
            sib(201, "Lantern Compendium - Lantern (USA)"),
            sib(202, "Lantern Compendium - Lantern II (USA)"),
            sib(204, "Lantern Compendium - Lantern III (USA) (Disc 2)"),
            sib(205, "Lantern Compendium - The Chronicle of Lantern (USA)"),
            sib(200, "Lantern Compendium - Beast Cup (USA)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [203, 204])
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.canonicalRomID, 203)
        XCTAssertEqual(game.excludedSiblings.map(\.id), [201, 202, 205, 200])
    }

    // MARK: - Input hygiene

    func testDuplicateSiblingIDsAreDeduplicated() {
        let rep = rom(210, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(211, "Chrono Bastion (USA) (Disc 2)"),
            sib(211, "Chrono Bastion (USA) (Disc 2)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [210, 211],
                       "a repeated RomM id must not look like a duplicate disc")
        XCTAssertTrue(game.excludedSiblings.isEmpty)
    }

    func testSiblingSharingTheRepresentativeIDIsIgnored() {
        let rep = rom(220, "Chrono Bastion (USA) (Disc 1).cue", siblings: [
            sib(220, "Chrono Bastion (USA) (Disc 1)", main: true),
            sib(221, "Chrono Bastion (USA) (Disc 2)"),
        ])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [220, 221])
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertTrue(game.excludedSiblings.isEmpty)
    }

    func testNoSiblingsYieldsASingleDisc() {
        let rep = rom(230, "Harbor Detective (USA).cue")
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.romID), [230])
        XCTAssertEqual(game.discs.map(\.index), [1])
        XCTAssertEqual(game.discs.map(\.label), ["Disc 1"])
        XCTAssertEqual(game.discs.map(\.fileStem), ["Harbor Detective (USA)"])
        XCTAssertEqual(game.canonicalRomID, 230)
        XCTAssertTrue(game.excludedSiblings.isEmpty)
    }

    func testFileStemStripsOnlyARealExtension() {
        XCTAssertEqual(PS1GameClassifier.fileStem(forFSName: "Chrono Bastion (USA) (Disc 1).cue"),
                       "Chrono Bastion (USA) (Disc 1)")
        XCTAssertEqual(PS1GameClassifier.fileStem(forFSName: "Chrono Bastion (USA) (Disc 1).chd"),
                       "Chrono Bastion (USA) (Disc 1)")
        // Multi-file PS1 roms are folders: fs_name has no extension and may
        // carry a version dot that must survive.
        XCTAssertEqual(PS1GameClassifier.fileStem(forFSName: "Chrono Bastion v1.1 (USA) (Disc 1)"),
                       "Chrono Bastion v1.1 (USA) (Disc 1)")
        XCTAssertEqual(PS1GameClassifier.fileStem(forFSName: "Chrono Bastion (USA)"),
                       "Chrono Bastion (USA)")
    }

    func testFolderStyleRepresentativeStillMerges() {
        let rep = rom(240, "Chrono Bastion v1.1 (USA) (Disc 1)",
                      siblings: [sib(241, "Chrono Bastion v1.1 (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.discs.map(\.fileStem),
                       ["Chrono Bastion v1.1 (USA) (Disc 1)", "Chrono Bastion v1.1 (USA) (Disc 2)"])
    }

    // MARK: - Server-supplied stem

    // RomM returns `fs_name_no_ext` identical to `fs_name` for extension-less
    // folder roms, dots included. Siblings' stems always come from the server,
    // so the representative's must too — a local stem that strips after the
    // last dot disagrees with the sibling and the merge silently fails.
    func testServerSuppliedStemWinsOverTheLocalGuess() {
        // A folder rom whose name ends in a dotted acronym: RomM reports
        // `fs_name_no_ext` identical to `fs_name`, the local heuristic cannot
        // tell the last segment from an extension, and only the server is right.
        let fsName = "Vault Runner - Operation S.W.A.T"
        XCTAssertEqual(PS1GameClassifier.fileStem(forFSName: fsName),
                       "Vault Runner - Operation S.W.A",
                       "precondition: the local heuristic mangles this name")
        let rep = rom(250, fsName, noExt: fsName)
        XCTAssertEqual(PS1GameClassifier.fileStem(for: rep), fsName)
        XCTAssertEqual(PS1GameClassifier.classify(rep).discs.map(\.fileStem), [fsName])
    }

    func testDottedTitleMergesOnServerSuppliedStems() {
        let one = "Vault Runner - Operation S.W.A.T (USA) (Disc 1)"
        let two = "Vault Runner - Operation S.W.A.T (USA) (Disc 2)"
        let rep = rom(252, one, siblings: [sib(253, two)], noExt: one)
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
        XCTAssertEqual(game.discs.map(\.romID), [252, 253])
        XCTAssertEqual(game.discs.map(\.fileStem), [one, two], "dots must survive verbatim")
        XCTAssertEqual(game.canonicalRomID, 252)
    }

    func testServerSuppliedStemIsUsedVerbatimForFileRoms() {
        let rep = rom(260, "Chrono Bastion (USA) (Disc 1).cue",
                      siblings: [sib(261, "Chrono Bastion (USA) (Disc 2)")],
                      noExt: "Chrono Bastion (USA) (Disc 1)")
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.fileStem),
                       ["Chrono Bastion (USA) (Disc 1)", "Chrono Bastion (USA) (Disc 2)"])
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
    }

    func testLocalStemIsOnlyAFallback() {
        // Server omitted the field: the local heuristic still strips `.cue` and
        // still leaves a mid-name dot alone.
        let rep = rom(270, "Vault Runner - Project S.C.A.R. (USA) (Disc 1).cue",
                      siblings: [sib(271, "Vault Runner - Project S.C.A.R. (USA) (Disc 2)")])
        let game = PS1GameClassifier.classify(rep)
        XCTAssertEqual(game.discs.map(\.fileStem),
                       ["Vault Runner - Project S.C.A.R. (USA) (Disc 1)",
                        "Vault Runner - Project S.C.A.R. (USA) (Disc 2)"])
        XCTAssertEqual(game.discs.map(\.index), [1, 2])
    }

    func testRomDecodesServerStem() throws {
        let json = Data("""
        {"id": 280, "name": "Vault Runner", "fs_name": "Vault Runner (USA) (Disc 1)",
         "fs_name_no_ext": "Vault Runner (USA) (Disc 1)", "platform_id": 33}
        """.utf8)
        let decoded = try JSONDecoder().decode(Rom.self, from: json)
        XCTAssertEqual(decoded.fsNameNoExt, "Vault Runner (USA) (Disc 1)")

        let withoutField = Data("""
        {"id": 281, "fs_name": "Vault Runner (USA).cue", "platform_id": 33}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(Rom.self, from: withoutField).fsNameNoExt)
    }
}
