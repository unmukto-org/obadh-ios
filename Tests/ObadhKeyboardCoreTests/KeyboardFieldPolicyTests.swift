import XCTest
@testable import ObadhKeyboardCore

final class KeyboardFieldPolicyTests: XCTestCase {
    func testProseRetainsBanglaAndCaseSensitivePhoneticKeys() {
        for kind in [KeyboardFieldTraits.Kind.text, .social, .webSearch, .numbersAndPunctuation] {
            let policy = KeyboardFieldPolicy(traits: .init(kind: kind, capitalization: .allCharacters))
            XCTAssertTrue(policy.usesBanglaComposition)
            XCTAssertFalse(policy.shouldCapitalize(contextBefore: ""))
            XCTAssertTrue(policy.allowsLearning)
        }
    }

    func testEmailURLAndIdentifiersNeverUseLanguageTransformsOrLearning() {
        for traits in [KeyboardFieldTraits(kind: .email), .init(kind: .url),
                       .init(content: .email), .init(content: .url), .init(content: .identifier),
                       .init(content: .privateText), .init(isSecure: true)] {
            let policy = KeyboardFieldPolicy(traits: traits)
            XCTAssertFalse(policy.usesBanglaComposition)
            XCTAssertFalse(policy.allowsCorrections)
            XCTAssertFalse(policy.allowsSuggestions)
            XCTAssertFalse(policy.allowsLearning)
            XCTAssertFalse(policy.allowsSmartQuotes)
            XCTAssertFalse(policy.allowsSmartDashes)
            XCTAssertFalse(policy.allowsDoubleSpacePeriod)
            XCTAssertFalse(policy.allowsVoice)
        }
    }

    func testAlphanumericCodeDoesNotBecomeNumericWithoutAnExplicitPadHint() {
        XCTAssertEqual(KeyboardFieldPolicy(traits: .init(content: .privateText)).layout, .standard)
        XCTAssertEqual(KeyboardFieldPolicy(traits: .init(kind: .decimalPad, content: .identifier)).layout, .decimalPad)
    }

    func testProtectedFieldsOmitEmojiCommandsAcrossPagesAndTabletFamilies() {
        for content in [KeyboardFieldTraits.Content.identifier, .privateText, .email, .url] {
            let policy = KeyboardFieldPolicy(traits: .init(content: content))
            for mode in [KeyboardMode.letters, .numbers, .symbols] {
                for width in [414.0, 744, 820, 1024] {
                    let rows = KeyboardLayoutProvider.rows(for: mode, includesGlobeKey: true,
                        isPad: width > 500, width: width,
                        family: .forPortraitWidth(width), field: policy)
                    XCTAssertFalse(rows.flatMap(\.keys).contains(.emoji))
                    XCTAssertTrue(rows.flatMap(\.keys).contains(.globe))
                }
            }
        }
    }

    func testNamesKeepBanglaButNeverAutoReplaceOrLearn() {
        let policy = KeyboardFieldPolicy(traits: .init(content: .personName))
        XCTAssertTrue(policy.usesBanglaComposition)
        XCTAssertFalse(policy.allowsCorrections)
        XCTAssertFalse(policy.allowsLearning)
    }

    func testHostOptOutsAreIndependentAndDoNotDisableExplicitInput() {
        let policy = KeyboardFieldPolicy(traits: .init(correction: .disabled, spelling: .disabled,
            smartQuotes: .disabled, smartDashes: .enabled, smartInsertDelete: .disabled))
        XCTAssertTrue(policy.usesBanglaComposition)
        XCTAssertTrue(policy.allowsSuggestions)
        XCTAssertFalse(policy.allowsCorrections)
        XCTAssertFalse(policy.allowsCursorCorrections)
        XCTAssertFalse(policy.allowsSmartQuotes)
        XCTAssertTrue(policy.allowsSmartDashes)
        XCTAssertFalse(policy.allowsSmartSpacing)
        XCTAssertTrue(policy.allowsDoubleSpacePeriod)
    }

    func testLiteralLatinCapitalizationAndUnknownContext() {
        var traits = KeyboardFieldTraits(kind: .ascii, capitalization: .sentences)
        var policy = KeyboardFieldPolicy(traits: traits)
        for text in ["", "Hello. ", "Hello! ” ", "Hello\n"] {
            XCTAssertTrue(policy.shouldCapitalize(contextBefore: text), text)
        }
        for text in ["hello", "hello ", "Hello. next"] {
            XCTAssertFalse(policy.shouldCapitalize(contextBefore: text), text)
        }
        XCTAssertFalse(policy.shouldCapitalize(contextBefore: nil))
        traits.capitalization = .words
        policy = KeyboardFieldPolicy(traits: traits)
        XCTAssertTrue(policy.shouldCapitalize(contextBefore: "First "))
        XCTAssertFalse(policy.shouldCapitalize(contextBefore: "First"))
        traits.capitalization = .allCharacters
        XCTAssertTrue(KeyboardFieldPolicy(traits: traits).shouldCapitalize(contextBefore: "code"))
        traits.kind = .email
        traits.capitalization = .sentences
        XCTAssertFalse(KeyboardFieldPolicy(traits: traits).shouldCapitalize(contextBefore: ""))
    }

    func testReturnAvailabilityUsesWholeDocumentEvidence() {
        let policy = KeyboardFieldPolicy(traits: .init(automaticallyEnablesReturn: true))
        XCTAssertFalse(policy.returnIsEnabled(hasText: false))
        XCTAssertTrue(policy.returnIsEnabled(hasText: true))
        XCTAssertTrue(KeyboardFieldPolicy().returnIsEnabled(hasText: false))
    }

    func testContextLayoutsRemainUsableAtPhoneAndTabletWidthsInEveryMode() {
        for kind in KeyboardFieldTraits.Kind.allCases {
            for mode in [KeyboardMode.letters, .numbers, .symbols] {
                for width in [320.0, 414, 440, 744, 1024] {
                    for globe in [false, true] {
                        let pad = width > 500
                        let family = KeyboardLayoutProvider.PadFamily.forPortraitWidth(width)
                        let rows = KeyboardLayoutProvider.rows(for: mode, includesGlobeKey: globe,
                            isPad: pad, width: width, family: family,
                            field: .init(traits: .init(kind: kind)))
                        XCTAssertFalse(rows.isEmpty)
                        if globe { XCTAssertTrue(rows.flatMap(\.keys).contains(.globe), "\(kind), \(width)") }
                        for row in rows {
                            let frames = KeyboardLayoutGeometry.keyFrames(for: row, availableWidth: width - 14, keySpacing: 6)
                            XCTAssertEqual(frames.count, row.keys.count)
                            XCTAssertTrue(frames.allSatisfy { $0.width > 12 && $0.x >= -0.01 && $0.x + $0.width <= width - 13.99 },
                                          "\(kind), \(mode), \(width), \(globe)")
                        }
                    }
                }
            }
        }
    }

    func testNumericPadsOfferEveryASCIIDigitAndOnlyTheirRequestedSeparator() {
        for kind in [KeyboardFieldTraits.Kind.numberPad, .decimalPad] {
            let rows = KeyboardLayoutProvider.rows(for: .letters, field: .init(traits: .init(kind: kind, decimalSeparator: ",")))
            let outputs = rows.flatMap(\.keys).compactMap { key -> String? in
                if case .symbol(let symbol) = key { return symbol.output }
                return nil
            }
            XCTAssertEqual(Set(outputs.filter { $0 != "," }), Set("0123456789".map(String.init)))
            XCTAssertEqual(outputs.contains(","), kind == .decimalPad)
            XCTAssertFalse(rows.flatMap(\.keys).contains(.space))
            XCTAssertFalse(rows.flatMap(\.keys).contains(.emoji))
        }
    }

    func testLiteralTabletFlicksRetainPeriodAndShiftedDigitPairs() {
        let policy = KeyboardFieldPolicy(traits: .init(kind: .ascii))
        XCTAssertEqual(KeyboardFieldLayout.secondary(for: .symbol(.literal(".")), field: policy)?.output, "?")
        XCTAssertEqual(KeyboardFieldLayout.secondary(for: .symbol(.literal("4")), field: policy)?.output, "$")
        XCTAssertEqual(KeyboardFieldLayout.secondary(for: .character("q"), field: policy)?.output, "1")
        XCTAssertEqual(KeyboardFieldLayout.secondary(for: .character("d"), field: policy)?.output, "$")
    }

    func testEmailAndURLSyntaxHasNoBanglaSymbolsOnAnyPage() {
        for kind in [KeyboardFieldTraits.Kind.email, .url, .ascii] {
            let field = KeyboardFieldPolicy(traits: .init(kind: kind))
            for mode in [KeyboardMode.letters, .numbers, .symbols] {
                let keys = KeyboardLayoutProvider.rows(for: mode, field: field).flatMap(\.keys)
                for key in keys {
                    if case .symbol(let symbol) = key {
                        XCTAssertFalse(symbol.output.unicodeScalars.contains { (0x0980...0x09FF).contains($0.value) }, symbol.output)
                    }
                }
                if mode == .letters, kind == .email {
                    XCTAssertTrue(keys.contains(.symbol(.literal("@"))))
                    XCTAssertTrue(keys.contains(.symbol(.literal("."))))
                }
                if mode == .letters, kind == .url {
                    XCTAssertTrue(keys.contains(.symbol(.literal("/"))))
                    XCTAssertTrue(keys.contains(.symbol(.literal(".com"))))
                }
            }
        }
    }

    func testSmartPunctuationOptOutKeepsAddressSyntaxAndLatinPeriodShortcut() {
        XCTAssertEqual(SmartPunctuation.literalSubstitution(for: "'", contextBefore: "a",
            smartQuotes: false), .insert("'"))
        XCTAssertEqual(SmartPunctuation.literalSubstitution(for: "-", contextBefore: "a-",
            smartDashes: false), .insert("-"))
        XCTAssertEqual(SmartPunctuation.literalSubstitution(for: ".", contextBefore: "a..",
            smartEllipsis: false), .insert("."))
        XCTAssertEqual(SmartPunctuation.doubleSpaceSubstitution(contextBefore: "hello ", terminator: ".")?.insertion, ". ")
    }
}
