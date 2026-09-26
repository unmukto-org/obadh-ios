import CoreGraphics
import Foundation

enum KeyboardMode: Equatable {
    case letters
    case numbers
    case symbols
}

enum KeyboardKey: Equatable {
    case character(String)
    case symbol(KeyboardSymbol)
    case shift
    case backspace
    case modeSwitch(String)
    case emoji
    /// Next-keyboard switch. Only laid out when the system does NOT provide its
    /// own (see `needsInputModeSwitchKey`): on iPhone the system draws a globe in
    /// the row below our view, but on iPad it does not, which left no way out of
    /// Obadh at all.
    case globe
    case space
    case returnKey
    /// iPad-only keys. Native iPadOS carries a tab and a caps lock on every
    /// layout wider than an iPad mini, and a dismiss-keyboard key at the end of
    /// the command row on all of them. See KNOWN-ISSUES.md#ki-007.
    case tab
    case capsLock
    case hideKeyboard

    var weight: Double {
        switch self {
        case .space:
            5.0
        case .returnKey:
            2.25
        case .modeSwitch, .emoji, .globe, .hideKeyboard:
            1.25
        case .shift, .backspace, .tab, .capsLock:
            1.35
        case .character, .symbol:
            1
        }
    }

    /// The flick-down label iPadOS draws in the top-left of a letter key, and
    /// emits when the touch is dragged downward before lifting. Purely an iPad
    /// affordance — iPhone keys have no secondary.
    var padSecondary: KeyboardSymbol? {
        switch self {
        case let .character(value):
            KeyboardLayoutProvider.padSecondaryByCharacter[value].map { KeyboardSymbol.literal($0) }
        case let .symbol(symbol):
            KeyboardLayoutProvider.padSecondaryBySymbolOutput[symbol.output].map { label in
                label == "?" || label == "!"
                    ? KeyboardSymbol.terminator(label)
                    : KeyboardSymbol.literal(label)
            }
        default:
            nil
        }
    }
}

struct KeyboardSymbol: Equatable {
    let label: String
    let output: String
    let role: Role

    enum Role: Equatable {
        case literal
        case sentenceTerminator
    }

    static func literal(_ value: String, output: String? = nil) -> Self {
        Self(label: value, output: output ?? value, role: .literal)
    }

    /// A sentence-ending symbol: it commits any active composition and marks an
    /// autosuggest boundary. Used for দাঁড়ি `।`, `?`, and `!`.
    static func terminator(_ value: String, output: String? = nil) -> Self {
        Self(label: value, output: output ?? value, role: .sentenceTerminator)
    }

    /// দাঁড়ি — the Bangla full stop.
    static let dari = Self.terminator("\u{0964}")
}

struct KeyboardRow: Equatable {
    let keys: [KeyboardKey]
    let keyWeights: [Double]?
    let customSpacingAfterKeyIndex: [Int: Double]
    let leadingFlex: Double
    let trailingFlex: Double

    init(
        keys: [KeyboardKey],
        keyWeights: [Double]? = nil,
        customSpacingAfterKeyIndex: [Int: Double] = [:],
        leadingFlex: Double = 0,
        trailingFlex: Double = 0
    ) {
        assert(keyWeights == nil || keyWeights?.count == keys.count)
        self.keys = keys
        self.keyWeights = keyWeights?.count == keys.count ? keyWeights : nil
        self.customSpacingAfterKeyIndex = customSpacingAfterKeyIndex
        self.leadingFlex = leadingFlex
        self.trailingFlex = trailingFlex
    }
}

enum KeyboardLayoutProvider {
    // MARK: - iPad secondary (flick-down) labels
    //
    // Native iPadOS prints a second glyph in the top-left of each letter key and
    // emits it when you flick the key downward. We keep native's POSITIONS and
    // visual shape exactly, and substitute content only where a Bangla keyboard
    // makes a strictly better choice than the US-English original:
    //
    //   * The digit row becomes ১২৩৪৫৬৭৮৯০ rather than 1234567890. Obadh has no
    //     Latin digits anywhere (the numbers page is Bangla-only), so this adds
    //     reach for the digits users actually want and removes nothing.
    //   * `d` carries ৳ where native carries $. The taka sign is the one Bangla
    //     symbol worth promoting out of the numbers page, and a dollar sign is
    //     dead weight here.
    //
    // Everything else — @ # & * ( ) ' " % - + = / ; : ! ? — is kept exactly where
    // native puts it. Those are the "important ones" and moving them would cost
    // muscle memory for no gain.
    static let padSecondaryByCharacter: [String: String] = [
        "q": "১", "w": "২", "e": "৩", "r": "৪", "t": "৫",
        "y": "৬", "u": "৭", "i": "৮", "o": "৯", "p": "০",
        "a": "@", "s": "#", "d": "৳", "f": "&", "g": "*",
        "h": "(", "j": ")", "k": "'", "l": "\"",
        "z": "%", "x": "-", "c": "+", "v": "=", "b": "/", "n": ";", "m": ":"
    ]

    /// Secondaries for the punctuation keys iPad adds to the letters page, and
    /// for the dedicated number row the 13-inch layout gains. Native prints the
    /// shifted ASCII pair above each digit (`!1 @2 #3 …`); we keep that pairing
    /// and swap only $ for ৳, for the reason given above.
    static let padSecondaryBySymbolOutput: [String: String] = [
        ",": "!",
        "\u{0964}": "?",   // দাঁড়ি → ?
        "/": "\\",
        "`": "~",
        "-": "_",
        "=": "+",
        "[": "{",
        "]": "}",
        "\\": "|",
        ";": ":",
        "'": "\"",
        // The 13-inch number row. Native puts the shifted ASCII pair here
        // (`!1 @2 #3 …`), but we already carry every one of those glyphs on the
        // letter-row flicks, which the extended layout keeps. That frees this row
        // for something Obadh has nowhere else: the LATIN digits. A Bangla writer
        // needs both numeral systems — phone numbers, prices and code are routinely
        // Latin — and this is the only place they can sit without displacing
        // anything. Nothing native offers is lost; it just moved one row.
        "১": "1", "২": "2", "৩": "3", "৪": "4", "৫": "5",
        "৬": "6", "৭": "7", "৮": "8", "৯": "9", "০": "0"
    ]

    private enum NativeGeometry {
        // iOS 26 phone portrait measurements from native keyboard screenshots
        // on a 440 pt-wide device class.
        static let standardKeyWidth = 37.33
        static let keyboardSideInset = 6.67
        static let homeRowScreenIndent = 28.0
        static let homeRowInternalIndent = homeRowScreenIndent - keyboardSideInset
        static let spaceKeyWidth = 210.67
        static let returnKeyWidth = 102.33
        static let edgeCommandKeyWidth = 50.33
        static let edgeBackspaceKeyWidth = 50.33
        static let rowThreeSideGap = 14.67
        static let punctuationSymbolKeyWidth = 54.53
        /// Native's single leading command key, measured 102.0 at 440pt against a
        /// 102.33 return — the row is very nearly symmetric. Whatever we put there
        /// (mode switch, emoji, our own globe) shares exactly this span including
        /// the gaps between them, so the count of leading keys never reaches space
        /// or return. Two keys therefore come out at exactly 48.0 each.
        static let leadingCommandBlockWidth = 102.0
        /// The gap between keys inside that block, at the 440pt reference.
        static let commandBlockGap = 6.0

        static let lowerRowWeights = [edgeCommandKeyWidth / standardKeyWidth]
            + Array(repeating: 1.0, count: 7)
            + [edgeBackspaceKeyWidth / standardKeyWidth]

        static let lowerRowSpacingAfterKeyIndex = [
            0: rowThreeSideGap,
            7: rowThreeSideGap
        ]

        static let punctuationLowerRowWeights = [edgeCommandKeyWidth]
            + Array(repeating: punctuationSymbolKeyWidth, count: 5)
            + [edgeBackspaceKeyWidth]

        static let punctuationLowerRowSpacingAfterKeyIndex = [
            0: rowThreeSideGap,
            5: rowThreeSideGap
        ]
    }


    /// The bottom command row. When the system does not supply a next-keyboard key
    /// we add our own (see `KeyboardKey.globe`). No explicit weights: each key's own
    /// `weight` applies, so space keeps its 5.0 share and the row re-proportions
    /// itself around the extra key instead of being hand-tuned per variant.
    /// The bottom command row, on native's measured widths.
    ///
    /// Native's row is one leading key, then space, then return. We put more than
    /// one key in that leading position — the emoji key always, and our own globe
    /// key when the system withholds its next-keyboard key — so the block is
    /// SUBDIVIDED rather than allowed to push the others aside. Space and return
    /// are the two widths actually measured off native (210.67 / 102.33 at the
    /// 440pt reference), and they stay put no matter how many keys lead.
    ///
    /// This used to fall back to each key's intrinsic `weight` on the theory that
    /// the row would re-proportion itself around the extra key. It does, but not
    /// onto native's numbers: measured on the simulator that put space at 209.6
    /// and shrank return to 94.3 against native's 102.3, on every iPhone width.
    private static func commandRow(leading: [KeyboardKey], includesGlobeKey: Bool) -> KeyboardRow {
        let leadingKeys = leading + (includesGlobeKey ? [.globe] : [])
        let interiorGaps = Double(leadingKeys.count - 1) * NativeGeometry.commandBlockGap
        let each = (NativeGeometry.leadingCommandBlockWidth - interiorGaps) / Double(leadingKeys.count)
        return KeyboardRow(
            keys: leadingKeys + [.space, .returnKey],
            keyWeights: Array(repeating: each, count: leadingKeys.count)
                + [NativeGeometry.spaceKeyWidth, NativeGeometry.returnKeyWidth]
        )
    }

    // MARK: - iPad
    //
    // scripts/parity/ipad-geometry.py reproduces the measurements below from
    // Reference/native-ipad/. Coverage limits are in KNOWN-ISSUES.md#ki-007.
    // The short version: iPad native quantizes the ROW STRUCTURE by
    // width, not just the key size, so there are three distinct layouts and a
    // ratio table taken from one iPad describes a keyboard the others do not have.

    enum PadFamily {
        /// 744pt — iPad mini. Four rows, no tab or caps lock, indented home row.
        case compact
        /// 820/834pt — iPad, iPad Air 11", iPad Pro 11". Four rows plus tab and caps.
        case standard
        /// 1024/1032pt — 13-inch. Five rows: a real number row appears.
        case extended

        /// Selected from the device's PORTRAIT width — the screen's shorter side —
        /// never from the current layout width.
        ///
        /// This distinction is the whole ballgame in landscape. An iPad Pro 11-inch
        /// is 1210pt wide in landscape, which is past the extended threshold, but
        /// native still draws it the 4-row standard layout: the family is a property
        /// of the DEVICE, and rotating only stretches whichever layout that device
        /// has. Keying off the live width would hand every rotated iPad a number row
        /// it does not have in native.
        ///
        /// Boundaries sit in the empty space between real device widths, so no
        /// shipping iPad lands near one. The fleet is 744 / 820 / 834 / 1024 / 1032.
        static func forPortraitWidth(_ width: Double) -> PadFamily {
            switch width {
            case ..<780: .compact
            case ..<1000: .standard
            default: .extended
            }
        }

        static func forScreen(_ size: CGSize) -> PadFamily {
            forPortraitWidth(Double(min(size.width, size.height)))
        }

        var margin: Double {
            switch self {
            case .compact: 6
            case .standard: 9
            case .extended: 3.5
            }
        }

        var gap: Double {
            switch self {
            case .compact: 12
            case .standard: 10
            case .extended: 7
            }
        }
    }

    /// Fitted key weights, in units of the letter-key width. Worst-case error
    /// against the measured native key is 0.56pt on `standard` and 0.15pt on
    /// `extended` (excluding the space bar, which absorbs the row remainder by
    /// construction and lands within 2.3pt).
    private enum PadWeight {
        /// Landscape command rows. The letter-row weights are orientation
        /// independent (every one reproduces within 0.01 of the portrait fit), but
        /// the command row is not: landscape gives the space bar more and the side
        /// keys less. Measured on 1133 / 1180 / 1210 / 1366 / 1376.
        enum Landscape {
            static let compactCommand = 1.021
            static let compactSpace = 5.770
            static let compactWide = 1.612
            static let standardCommand = 1.007
            static let standardSpace = 7.617
            static let standardWide = 1.503
            /// The 13-inch command row is absolute in landscape too.
            static let extendedSides: [Double] = [124, 123.5, 124, 191.5, 191.5]
            static let extendedSidesNoGlobe: [Double] = [123.5, 124, 191.5, 191.5]
            /// The compact home row is both less indented and has a shorter return
            /// key in landscape than in portrait.
            static let compactHomeRowIndent = 0.466
            static let compactReturn = 1.931
        }

        enum Compact {
            static let backspace = 1.239
            static let returnKey = 1.972
            static let leftShift = 1.0
            static let rightShift = 1.239
            static let homeRowIndent = 0.486
            static let command = 1.046
            static let space = 5.835
            static let commandWide = 1.679
        }

        enum Standard {
            static let tab = 1.292
            static let backspace = 1.292
            static let capsLock = 1.648
            static let returnKey = 2.120
            static let leftShift = 2.179
            static let rightShift = 1.589
            static let command = 1.067
            static let space = 7.284
            static let modeSwitchRight = 1.589
            static let hide = 1.594
        }

        enum Extended {
            static let tab = 1.601
            static let backspace = 1.601
            static let capsLock = 1.853
            static let returnKey = 1.853
            static let shift = 2.410
            static let command = 1.474
            static let mic = 1.482
            static let space = 6.523
            static let modeSwitchRight = 2.276
            static let hide = 2.272
        }
    }

    private static func character(_ value: Character) -> KeyboardKey { .character(String(value)) }

    /// Native's command row, in native's order: globe, mode switch, the dictation
    /// slot, space, a second mode switch, dismiss. We have no dictation, so that
    /// slot carries the emoji key — it is the one thing we own that belongs in a
    /// fixed-width command position.
    private static func padCommandRow(
        modeLabel: String,
        family: PadFamily,
        width: Double,
        margin: Double,
        gap: Double,
        landscape: Bool,
        includesGlobeKey: Bool
    ) -> KeyboardRow {
        // The 13-inch command row is the one place a proportional fit is provably
        // wrong: its side keys measure IDENTICALLY on 1024 and 1032 (93.5 / 93.5 /
        // 94 / 145 / 145) while the space bar grows by exactly the 8pt the screen
        // grew. So lay those out in points and let space take the remainder — the
        // weights are absolute widths, which sum to the content width and so
        // resolve to a unit of 1. Proportional weights here sat 3pt off native.
        if family == .extended {
            let sides: [Double] = landscape
                ? (includesGlobeKey ? PadWeight.Landscape.extendedSides
                                    : PadWeight.Landscape.extendedSidesNoGlobe)
                : (includesGlobeKey ? [93.5, 93.5, 94, 145, 145]
                                    : [93.5, 94, 145, 145])
            let keyCount = sides.count + 1
            let content = width - 2 * margin - Double(keyCount - 1) * gap
            let space = max(1, content - sides.reduce(0, +))
            var keys: [KeyboardKey] = includesGlobeKey ? [.globe] : []
            keys += [.modeSwitch(modeLabel), .emoji, .space, .modeSwitch(modeLabel), .hideKeyboard]
            let weights = Array(sides.prefix(sides.count - 2)) + [space] + Array(sides.suffix(2))
            return KeyboardRow(keys: keys, keyWeights: weights)
        }

        var keys: [KeyboardKey] = []
        var weights: [Double] = []
        let (narrow, space, wide, hide): (Double, Double, Double, Double) = switch (family, landscape) {
        case (.compact, false):
            (PadWeight.Compact.command, PadWeight.Compact.space,
             PadWeight.Compact.commandWide, PadWeight.Compact.commandWide)
        case (.compact, true):
            (PadWeight.Landscape.compactCommand, PadWeight.Landscape.compactSpace,
             PadWeight.Landscape.compactWide, PadWeight.Landscape.compactWide)
        case (_, true):
            (PadWeight.Landscape.standardCommand, PadWeight.Landscape.standardSpace,
             PadWeight.Landscape.standardWide, PadWeight.Landscape.standardWide)
        case (_, false):
            (PadWeight.Standard.command, PadWeight.Standard.space,
             PadWeight.Standard.modeSwitchRight, PadWeight.Standard.hide)
        }

        if includesGlobeKey {
            keys.append(.globe)
            weights.append(narrow)
        }
        keys.append(.modeSwitch(modeLabel))
        weights.append(narrow)
        keys.append(.emoji)
        weights.append(narrow)
        keys.append(.space)
        weights.append(space)
        keys.append(.modeSwitch(modeLabel))
        weights.append(wide)
        keys.append(.hideKeyboard)
        weights.append(hide)
        return KeyboardRow(keys: keys, keyWeights: weights)
    }

    /// The two punctuation keys native puts at the end of the bottom letter row.
    /// দাঁড়ি takes the position of the period, which is what it is.
    private static let padRowThreeTail: [KeyboardKey] = [
        .symbol(.literal(",")),
        .symbol(.dari)
    ]

    private static func padLetterRows(
        family: PadFamily,
        width: Double,
        margin: Double,
        gap: Double,
        landscape: Bool,
        includesGlobeKey: Bool
    ) -> [KeyboardRow] {
        let top = "qwertyuiop".map(character)
        let home = "asdfghjkl".map(character)
        let lower = "zxcvbnm".map(character)

        switch family {
        case .compact:
            return [
                KeyboardRow(
                    keys: top + [.backspace],
                    keyWeights: Array(repeating: 1.0, count: 10) + [PadWeight.Compact.backspace]
                ),
                KeyboardRow(
                    keys: home + [.returnKey],
                    keyWeights: Array(repeating: 1.0, count: 9)
                        + [landscape ? PadWeight.Landscape.compactReturn : PadWeight.Compact.returnKey],
                    leadingFlex: landscape
                        ? PadWeight.Landscape.compactHomeRowIndent
                        : PadWeight.Compact.homeRowIndent
                ),
                KeyboardRow(
                    keys: [.shift] + lower + padRowThreeTail + [.shift],
                    keyWeights: [PadWeight.Compact.leftShift]
                        + Array(repeating: 1.0, count: 9)
                        + [PadWeight.Compact.rightShift]
                ),
                padCommandRow(modeLabel: "123", family: family, width: width, margin: margin,
                              gap: gap, landscape: landscape, includesGlobeKey: includesGlobeKey)
            ]
        case .standard:
            return [
                KeyboardRow(
                    keys: [.tab] + top + [.backspace],
                    keyWeights: [PadWeight.Standard.tab]
                        + Array(repeating: 1.0, count: 10)
                        + [PadWeight.Standard.backspace]
                ),
                KeyboardRow(
                    keys: [.capsLock] + home + [.returnKey],
                    keyWeights: [PadWeight.Standard.capsLock]
                        + Array(repeating: 1.0, count: 9)
                        + [PadWeight.Standard.returnKey]
                ),
                KeyboardRow(
                    keys: [.shift] + lower + padRowThreeTail + [.shift],
                    keyWeights: [PadWeight.Standard.leftShift]
                        + Array(repeating: 1.0, count: 9)
                        + [PadWeight.Standard.rightShift]
                ),
                padCommandRow(modeLabel: ".?123", family: family, width: width, margin: margin,
                              gap: gap, landscape: landscape, includesGlobeKey: includesGlobeKey)
            ]
        case .extended:
            return [padNumberRow()] + [
                KeyboardRow(
                    keys: [.tab] + top + ["[", "]", "\\"].map { .symbol(.literal($0)) },
                    keyWeights: [PadWeight.Extended.tab] + Array(repeating: 1.0, count: 13)
                ),
                KeyboardRow(
                    keys: [.capsLock] + home + [";", "'"].map { .symbol(.literal($0)) } + [.returnKey],
                    keyWeights: [PadWeight.Extended.capsLock]
                        + Array(repeating: 1.0, count: 11)
                        + [PadWeight.Extended.returnKey]
                ),
                KeyboardRow(
                    keys: [.shift] + lower + padRowThreeTail + [.symbol(.literal("/"))] + [.shift],
                    keyWeights: [PadWeight.Extended.shift]
                        + Array(repeating: 1.0, count: 10)
                        + [PadWeight.Extended.shift]
                ),
                padCommandRow(modeLabel: ".?123", family: .extended, width: width, margin: margin,
                              gap: gap, landscape: landscape, includesGlobeKey: includesGlobeKey)
            ]
        }
    }

    /// The 13-inch number row. Bangla numerals rather than Latin ones: Obadh has
    /// no Latin digits anywhere, so mirroring native's `1234567890` would be
    /// mirroring a keyboard we are not.
    private static func padNumberRow() -> KeyboardRow {
        let digits = ["১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯", "০"]
        let keys: [KeyboardKey] = [.symbol(.literal("`"))]
            + digits.map { .symbol(.literal($0)) }
            + [.symbol(.literal("-")), .symbol(.literal("="))]
            + [.backspace]
        return KeyboardRow(
            keys: keys,
            keyWeights: Array(repeating: 1.0, count: 13) + [PadWeight.Extended.backspace]
        )
    }

    /// Numbers and symbols pages keep the family's frame — same row count, same
    /// command row — so switching pages never resizes the keyboard. The content
    /// rows are the existing phone sets; on the wider families they simply have
    /// more room, and on `extended` the number row is already the digits so the
    /// symbol pages inherit it unchanged.
    private static func padSymbolRows(
        family: PadFamily,
        width: Double,
        margin: Double,
        gap: Double,
        landscape: Bool,
        includesGlobeKey: Bool,
        modeLabel: String,
        firstRow: [KeyboardKey],
        secondRow: [KeyboardKey],
        thirdRow: [KeyboardKey]
    ) -> [KeyboardRow] {
        let leading: [KeyboardKey] = family == .compact ? [] : [.tab]
        let capsLeading: [KeyboardKey] = family == .compact ? [] : [.capsLock]
        let edge: Double = switch family {
        case .compact: PadWeight.Compact.backspace
        case .standard: PadWeight.Standard.backspace
        case .extended: PadWeight.Extended.backspace
        }
        let caps: Double = switch family {
        case .compact: PadWeight.Compact.backspace
        case .standard: PadWeight.Standard.capsLock
        case .extended: PadWeight.Extended.capsLock
        }
        let ret: Double = switch family {
        case .compact: PadWeight.Compact.returnKey
        case .standard: PadWeight.Standard.returnKey
        case .extended: PadWeight.Extended.returnKey
        }
        let shift: Double = switch family {
        case .compact: PadWeight.Compact.leftShift
        case .standard: PadWeight.Standard.leftShift
        case .extended: PadWeight.Extended.shift
        }
        let shiftRight: Double = switch family {
        case .compact: PadWeight.Compact.rightShift
        case .standard: PadWeight.Standard.rightShift
        case .extended: PadWeight.Extended.shift
        }

        var rows: [KeyboardRow] = []
        if family == .extended {
            rows.append(padNumberRow())
        }
        rows.append(KeyboardRow(
            keys: leading + firstRow + [.backspace],
            keyWeights: (leading.isEmpty ? [] : [edge])
                + Array(repeating: 1.0, count: firstRow.count) + [edge]
        ))
        rows.append(KeyboardRow(
            keys: capsLeading + secondRow + [.returnKey],
            keyWeights: (capsLeading.isEmpty ? [] : [caps])
                + Array(repeating: 1.0, count: secondRow.count) + [ret]
        ))
        rows.append(KeyboardRow(
            keys: [.modeSwitch(modeLabel)] + thirdRow + [.modeSwitch(modeLabel)],
            keyWeights: [shift] + Array(repeating: 1.0, count: thirdRow.count) + [shiftRight]
        ))
        rows.append(padCommandRow(
            modeLabel: "ABC",
            family: family,
            width: width,
            margin: margin,
            gap: gap,
            landscape: landscape,
            includesGlobeKey: includesGlobeKey
        ))
        return rows
    }

    /// `width` is the CURRENT layout width (it sizes the keys); `family` comes from
    /// the device's portrait width and does not change when the iPad rotates.
    static func padRows(
        for mode: KeyboardMode,
        width: Double,
        family: PadFamily,
        margin: Double,
        gap: Double,
        landscape: Bool,
        includesGlobeKey: Bool
    ) -> [KeyboardRow] {
        switch mode {
        case .letters:
            return padLetterRows(family: family, width: width, margin: margin, gap: gap,
                                 landscape: landscape, includesGlobeKey: includesGlobeKey)
        case .numbers:
            return padSymbolRows(
                family: family,
                width: width,
                margin: margin,
                gap: gap,
                landscape: landscape,
                includesGlobeKey: includesGlobeKey,
                modeLabel: "#+=",
                firstRow: ["১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯", "০"]
                    .map { .symbol(.literal($0)) },
                secondRow: ["-", "/", ":", ";", "(", ")", "৳", "'", "@", "\""]
                    .map { .symbol(.literal($0)) },
                thirdRow: [.symbol(.dari), .symbol(.literal(".")), .symbol(.literal(","))]
                    + [.symbol(.terminator("?")), .symbol(.terminator("!"))]
            )
        case .symbols:
            return padSymbolRows(
                family: family,
                width: width,
                margin: margin,
                gap: gap,
                landscape: landscape,
                includesGlobeKey: includesGlobeKey,
                modeLabel: "123",
                firstRow: ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="]
                    .map { .symbol(.literal($0)) },
                secondRow: ["_", "\\", "|", "~", "<", ">", "&", "$", "€", "£"]
                    .map { .symbol(.literal($0)) },
                thirdRow: [.symbol(.dari), .symbol(.literal(".")), .symbol(.literal(","))]
                    + [.symbol(.terminator("?")), .symbol(.terminator("!"))]
            )
        }
    }

    static func rows(
        for mode: KeyboardMode,
        includesGlobeKey: Bool = false,
        isPad: Bool = false,
        width: Double = 0,
        family: PadFamily = .standard,
        landscape: Bool = false,
        margin: Double = 0,
        gap: Double = 0
    ) -> [KeyboardRow] {
        if isPad, width > 0 {
            return padRows(
                for: mode,
                width: width,
                family: family,
                margin: margin > 0 ? margin : family.margin,
                gap: gap > 0 ? gap : family.gap,
                landscape: landscape,
                includesGlobeKey: includesGlobeKey
            )
        }
        return phoneRows(for: mode, includesGlobeKey: includesGlobeKey)
    }

    private static func phoneRows(for mode: KeyboardMode, includesGlobeKey: Bool) -> [KeyboardRow] {
        switch mode {
        case .letters:
            [
                KeyboardRow(keys: "qwertyuiop".map { .character(String($0)) }),
                KeyboardRow(
                    keys: "asdfghjkl".map { .character(String($0)) },
                    leadingFlex: NativeGeometry.homeRowInternalIndent / NativeGeometry.standardKeyWidth,
                    trailingFlex: NativeGeometry.homeRowInternalIndent / NativeGeometry.standardKeyWidth
                ),
                KeyboardRow(
                    keys: [.shift] + "zxcvbnm".map { .character(String($0)) } + [.backspace],
                    keyWeights: NativeGeometry.lowerRowWeights,
                    customSpacingAfterKeyIndex: NativeGeometry.lowerRowSpacingAfterKeyIndex
                ),
                commandRow(leading: [.modeSwitch("123"), .emoji], includesGlobeKey: includesGlobeKey)
            ]
        case .numbers:
            [
                KeyboardRow(keys: ["১", "২", "৩", "৪", "৫", "৬", "৭", "৮", "৯", "০"].map { .symbol(.literal($0)) }),
                KeyboardRow(
                    keys: ["-", "/", ":", ";", "(", ")", "৳", "'", "@", "\""].map { .symbol(.literal($0)) }
                ),
                KeyboardRow(
                    keys: [.modeSwitch("#+=")]
                        + [.symbol(.dari), .symbol(.literal(".")), .symbol(.literal(","))]
                        + [.symbol(.terminator("?")), .symbol(.terminator("!"))]
                        + [.backspace],
                    keyWeights: NativeGeometry.punctuationLowerRowWeights,
                    customSpacingAfterKeyIndex: NativeGeometry.punctuationLowerRowSpacingAfterKeyIndex
                ),
                commandRow(leading: [.modeSwitch("ABC")], includesGlobeKey: includesGlobeKey)
            ]
        case .symbols:
            [
                KeyboardRow(keys: ["[", "]", "{", "}", "#", "%", "^", "*", "+", "="].map { .symbol(.literal($0)) }),
                KeyboardRow(
                    keys: ["_", "\\", "|", "~", "<", ">", "&", "$", "€", "£"].map { .symbol(.literal($0)) }
                ),
                KeyboardRow(
                    keys: [.modeSwitch("123")]
                        + [.symbol(.dari), .symbol(.literal(".")), .symbol(.literal(","))]
                        + [.symbol(.terminator("?")), .symbol(.terminator("!"))]
                        + [.backspace],
                    keyWeights: NativeGeometry.punctuationLowerRowWeights,
                    customSpacingAfterKeyIndex: NativeGeometry.punctuationLowerRowSpacingAfterKeyIndex
                ),
                commandRow(leading: [.modeSwitch("ABC")], includesGlobeKey: includesGlobeKey)
            ]
        }
    }
}
