import UIKit

/// Keyboard chrome uses UIKit's native UIInputView(.keyboard) material. Keys
/// are thin overlays on that material, as on the native keyboard. Stacking
/// generic glass on each key produces a different appearance (particularly
/// with accessibility settings), so those styles remain diagnostic comparisons.
enum KeyboardGlassStyle: String {
    case regular      // UIGlassEffect(.regular) — Liquid Glass with specular rim
    case clear        // UIGlassEffect(.clear) — flatter/clearer glass
    case translucent  // plain semi-transparent fill, no rim (native-like)
    case solid        // opaque fill (pre-iOS 26 fallback look)

    static let shipped: KeyboardGlassStyle = .translucent
    #if DEBUG
    @MainActor static var current: KeyboardGlassStyle = shipped
    #else
    static var current: KeyboardGlassStyle { shipped }
    #endif
}

struct KeyboardMetrics {
    let keyCornerRadius: CGFloat
    let keyShadowOpacity: Float
    let keyShadowRadius: CGFloat
    let keyShadowOffset: CGSize
    let rowSpacing: CGFloat
    let keySpacing: CGFloat
    let rowTouchExtension: CGFloat
    let keyTouchExtension: CGFloat
    let suggestionHeight: CGFloat
    let suggestionContentTopInset: CGFloat
    let suggestionContentBottomInset: CGFloat
    let minimumKeyHeight: CGFloat
    let keyPreviewHeight: CGFloat
    let keyPreviewMinimumWidth: CGFloat
    let keyPreviewHorizontalOutset: CGFloat
    let keyPreviewStemHeight: CGFloat
    let keyPreviewStemWidth: CGFloat
    let keyPreviewCornerRadius: CGFloat
    let keyPreviewShadowOpacity: Float
    let keyPreviewShadowRadius: CGFloat
    let keyPreviewShadowOffset: CGSize
    let keyboardInsets: UIEdgeInsets
    let characterFontSize: CGFloat
    let symbolFontSize: CGFloat
    let keyPreviewFontSize: CGFloat
    let commandFontSize: CGFloat
    let modeSwitchFontSize: CGFloat
    let spaceIntroFontSize: CGFloat
    let spaceLanguageFontSize: CGFloat
    let suggestionFontSize: CGFloat
    let deterministicSuggestionFontSize: CGFloat
    /// iPad flick-down glyph. Measured off the reference capture: cap height 7pt
    /// (so ~10pt SF) with its cap top 10pt below the key top. Defaulted so the
    /// iPhone metrics and `defaultMetrics` need no change — they never draw it.
    var padSecondaryFontSize: CGFloat = 10
    var padSecondaryTopInset: CGFloat = 8
    /// The 13-inch iPad draws its number row shorter than the letter rows
    /// (45.5pt against 61pt). Zero means "every row is `minimumKeyHeight`",
    /// which is every other layout we ship.
    var padNumberRowHeight: CGFloat = 0
    /// Ink insets for a command key's glyph from its key edges, or nil to centre
    /// it. Per iPad family — the mini centres, larger iPads anchor. See KeyType.
    var padGlyphInsets: UIEdgeInsets?
    /// How many suggestion slots the strip lays out. Three everywhere on iPhone —
    /// that is the shipped, parity-gated layout — and more on iPad, which is wide
    /// enough to hold them at native's own slot density. See `suggestionSlotCount`.
    var suggestionSlotCount: Int = 3
    /// Height of the strip's content block: the slot separators, and the box the
    /// suggestion text is centred in. Native gives its prediction row 27.5pt of
    /// content flush with the top of the band and leaves the rest as clearance
    /// above the keys. Zero keeps the legacy proportional rule (iPhone).
    var suggestionContentHeight: CGFloat = 0

    /// Where the strip's content sits relative to the strip's own centre, positive
    /// = down. One rule for the separators and the labels, so they cannot drift.
    ///
    /// iPad pins a `suggestionContentHeight` block flush with the strip's top,
    /// mirroring how native fills its shortcuts bar and leaving the same clearance
    /// above the keys. iPhone keeps the measured rule it was tuned against: text
    /// centres ~26pt above the strip's BOTTOM edge whatever the strip's height, so
    /// a taller strip keeps the text near the keys; the -7 floor preserves the look
    /// of the shortest (legacy 34pt) strip.
    var suggestionContentOffset: CGFloat {
        guard suggestionContentHeight > 0 else {
            return max(-7, suggestionHeight / 2 - 26)
        }
        // Centred in the strip, with a floor so it can never ride up into the
        // system's shortcuts bar.
        //
        // Plain centring is right at every height we actually ask for, and it is
        // what the strip looks wrong without. But the strip is the flex element: on
        // an iPad rotated to landscape and back, the system lays us out at 353pt on
        // the way to 309 and the strip absorbs all 44pt of that. Centred content in
        // a 96pt strip sits 48pt down from a top that is momentarily behind the
        // shortcuts bar, which is how the suggestions ended up drawn across
        // undo/redo/paste. Past ~54pt the content stops rising and simply stays
        // above the keys.
        return max(0, suggestionHeight / 2 - 38)
    }
}

/// Every spatial constant native uses for an iPad keyboard, per layout family and
/// per orientation. All measured — see docs/native-parity-ipad.md and
/// `scripts/parity/ipad-geometry.py fit`, which reproduces the whole table from
/// the captures in Reference/native-ipad/.
///
/// Bottom insets are the one derived value: native's are measured from the SCREEN
/// edge, and an iPad input view does not reach it — the system's keyboard
/// container keeps a ~20pt band below us (measured identically on all five widths;
/// it is NOT the safe area, which reports 5). So what we apply is native's gap
/// minus that band.
struct PadAxisMetrics {
    let margin: CGFloat
    let gap: CGFloat
    let keyHeight: CGFloat
    /// The 13-inch number row is shorter than its letter rows. Zero elsewhere.
    let numberRowHeight: CGFloat
    let rowSpacing: CGFloat
    let bottomInset: CGFloat
    /// The shortcuts bar iPadOS draws ABOVE the keyboard — undo / redo / paste,
    /// plus (for the system keyboard only) three prediction slots. It sits in the
    /// keyboard container but outside our view, so we can neither fill it nor
    /// remove it: `UITextInputAssistantItem` belongs to the host's responder, and
    /// an extension "can draw only within the primary view of its
    /// UIInputViewController". Measured on native captures, per family and
    /// orientation. Our own strip mirrors its height so the two read as a pair of
    /// rows rather than a row plus a sliver.
    let shortcutBarHeight: CGFloat

    /// The band the system keeps below an iPad input view.
    static let systemBottomBand: CGFloat = 20

    /// Native iPad key type, measured from the reference captures and confirmed
    /// against a real iPad Pro 11-inch.
    ///
    /// The headline: the letter font is a per-ORIENTATION CONSTANT — 22.2pt in
    /// portrait and 28.0 in landscape — on every family, whether the key is 55.3pt
    /// tall or 61. It does not scale with the key at all. We were deriving it as
    /// `23 * keyHeight / 45`, which gave 28.3 portrait and 37.7 landscape: letters
    /// 27% and 43% too large. On a real device that is the difference between
    /// "looks like Apple's" and "looks like an imitation".
    ///
    /// The flick label goes the other way — native draws it BIGGER than we did
    /// (11.8 / 14.6 against our 10 / 11) and at half the opacity, so the pair reads
    /// as one key with a hint rather than two competing glyphs.
    struct KeyType {
        let letter: CGFloat
        let secondary: CGFloat
        let secondaryTop: CGFloat
        /// SF Symbol point size for the command keys. Native's symbols measured
        /// consistently 0.87-0.88 of ours across globe, shift, backspace and hide.
        let command: CGFloat
        /// `.?123`, which is text rather than a symbol.
        let modeSwitch: CGFloat
        /// Where the command glyph sits in its key, as INK insets from the key's
        /// edges. `nil` means centred.
        ///
        /// This is per-FAMILY, which is easy to get wrong: an iPad mini centres its
        /// command glyphs (measured 23.0 left against 22.0 right in portrait, 38.0
        /// against 37.5 in landscape) while every larger iPad pins them to the
        /// bottom-outer corner. Taking a Pro 11-inch's anchoring and applying it
        /// everywhere would have put the mini's glyphs against the wrong edge.
        let glyphInsets: UIEdgeInsets?

        static func of(
            _ family: KeyboardLayoutProvider.PadFamily,
            landscape: Bool
        ) -> KeyType {
            let insets: UIEdgeInsets?
            switch (family, landscape) {
            case (.compact, _):
                insets = nil
            case (.standard, false):
                insets = UIEdgeInsets(top: 0, left: 7, bottom: 6, right: 7.5)
            case (.standard, true):
                insets = UIEdgeInsets(top: 0, left: 10, bottom: 10, right: 11)
            case (.extended, false):
                insets = UIEdgeInsets(top: 0, left: 14, bottom: 10, right: 15)
            case (.extended, true):
                insets = UIEdgeInsets(top: 0, left: 17, bottom: 11.5, right: 17.75)
            }
            return landscape
                ? KeyType(letter: 28, secondary: 14.6, secondaryTop: 12.5,
                          command: 28.5, modeSwitch: 17.5, glyphInsets: insets)
                : KeyType(letter: 22.2, secondary: 11.8, secondaryTop: 8.7,
                          command: 22.5, modeSwitch: 14, glyphInsets: insets)
        }
    }

    /// Content block inside one suggestion row. Native's prediction separators run
    /// 27.5pt from the container's top edge on every iPad in both orientations,
    /// and the prediction text is centred in that same box; everything below it is
    /// clearance above the keys.
    static let suggestionContentHeight: CGFloat = 27.5

    /// What to ask for so the strip actually renders at `shortcutBarHeight`.
    ///
    /// The iPad container settles a keyboard extension shorter than it asks for.
    /// Sweeping the asked height 283 → 323pt on an iPad Pro 11-inch showed the
    /// deficit is an offset rather than a scale: every extra point asked for landed
    /// 1:1 in the strip, and the key rows never moved at all. Measured, the deficit
    /// is our own `bottomInset` — 8pt on a 4-row portrait iPad and 11pt in landscape
    /// both came back exact. The 13-inch is the one that does not fit, landing 2pt
    /// out either way.
    ///
    /// Being wrong here only flexes the strip: the key block is bottom-anchored, so
    /// nothing that parity is measured on can drift.
    var askedStripHeight: CGFloat { shortcutBarHeight + bottomInset }

    static func of(
        _ family: KeyboardLayoutProvider.PadFamily,
        landscape: Bool,
        portraitWidth: CGFloat
    ) -> PadAxisMetrics {
        switch (family, landscape) {
        case (.compact, false):
            // 744pt. Native: key 55.5, pitch 64.5, 28pt above the screen edge.
            PadAxisMetrics(margin: 6, gap: 12, keyHeight: 55.3, numberRowHeight: 0,
                           rowSpacing: 8.9, bottomInset: 28 - systemBottomBand,
                           shortcutBarHeight: 45.5)
        case (.standard, false):
            // 820/834pt. Key height moves 0.5pt across that range, so it is flat.
            PadAxisMetrics(margin: 9, gap: 10, keyHeight: 55.3, numberRowHeight: 0,
                           rowSpacing: 8.9, bottomInset: 28 - systemBottomBand,
                           shortcutBarHeight: 45.5)
        case (.extended, false):
            // 1024/1032pt. Five rows; the number row is 45.5 against 61.
            PadAxisMetrics(margin: 3.5, gap: 7, keyHeight: 61, numberRowHeight: 45.5,
                           rowSpacing: 7.12, bottomInset: 24 - systemBottomBand,
                           shortcutBarHeight: 43.5)
        case (.compact, true):
            // 1133pt.
            PadAxisMetrics(margin: 7, gap: 14, keyHeight: 75, numberRowHeight: 0,
                           rowSpacing: 10.75, bottomInset: 30 - systemBottomBand,
                           shortcutBarHeight: 48.5)
        case (.standard, true):
            // 1180/1210pt. Unlike portrait, landscape key height tracks the
            // device's portrait width here: 72.5/820 = 0.0884, 74/834 = 0.0887.
            PadAxisMetrics(margin: 15, gap: 14, keyHeight: 0.08857 * portraitWidth,
                           numberRowHeight: 0, rowSpacing: 11.75,
                           bottomInset: 31 - systemBottomBand,
                           shortcutBarHeight: 48.5)
        case (.extended, true):
            // 1366/1376pt. Identical on both.
            PadAxisMetrics(margin: 5, gap: 10, keyHeight: 79, numberRowHeight: 59,
                           rowSpacing: 9, bottomInset: 24 - systemBottomBand,
                           shortcutBarHeight: 45.5)
        }
    }

    /// How many suggestion slots to lay out at a given layout width.
    ///
    /// Native shows exactly three predictions on every iPad, but it draws them in a
    /// fixed block centred in the shortcuts bar — measured slot pitch 147pt on a
    /// mini and 155pt on everything else — and leaves the rest of the bar empty.
    /// Our strip spans the full width, so at three slots it would be 248-344pt per
    /// suggestion: two to three times native's density, which is what makes it read
    /// as three words adrift in a wide empty band.
    ///
    /// So we keep native's density and take the slot count from it. 165pt is that
    /// pitch with a little slack for Bangla's wider glyphs. The cap is a UX limit,
    /// not a spatial one: a rotated 13-inch could hold nine, and nobody scans nine.
    static func suggestionSlotCount(forLayoutWidth width: CGFloat, isPad: Bool) -> Int {
        guard isPad else { return 3 }
        return min(6, max(3, Int((width / 165).rounded())))
    }

    /// The key block, accounting for the extended family's shorter number row.
    func keyBlockHeight(rowCount: Int) -> CGFloat {
        let uniform = CGFloat(rowCount) * keyHeight
        let numberRowAdjustment = numberRowHeight > 0 ? keyHeight - numberRowHeight : 0
        return uniform - numberRowAdjustment + CGFloat(rowCount - 1) * rowSpacing
    }
}

/// Native iPhone geometry in LANDSCAPE, measured off the captures in
/// `Reference/native-iphone/landscape/` — reproduce with
/// `scripts/parity/iphone-landscape.py fit`.
///
/// Landscape is not a stretched portrait. The keyboard container does not span
/// the screen, it is inset on both sides, and on notched phones the globe and
/// dictation keys sit OUTSIDE it in the safe-area corners, which is why native's
/// bottom row carries three keys there and five on an SE.
///
/// Like portrait, everything here is class-quantized rather than proportional:
/// key height 27.3 and pitch 35.33 hold across 852 → 956pt, a 12% span in width.
/// The single most important fact here, and the one that is invisible from the
/// source: **in landscape the system gives the extension a view NARROWER than the
/// screen.** Measured from the running extension —
///
/// | device | screen | our view | native's inset | left for us |
/// |---|---|---|---|---|
/// | SE 3 | 667 | 667 | 72 | 72 |
/// | iPhone 16 | 852 | 702 | 79 | 4 |
/// | iPhone Air | 912 | 678 | 121 | 4 |
/// | 17 Pro Max | 956 | 722 | 121 | 4 |
///
/// So the system has already applied almost exactly native's container inset for
/// us, and what we add on top is 4pt — not 79 or 121, which would inset a second
/// time. A home-button phone's view spans the whole screen, so it takes the full
/// 72. Applying the screen-relative numbers directly put the keys 68pt too far in
/// on every notched phone.
///
/// It also means `bounds.width` is NOT the screen's longer side, which is why the
/// class test takes the screen size rather than the view's.
struct PhoneLandscapeMetrics {
    /// Applied INSIDE our view, on top of whatever the system already inset it by.
    let sideInset: CGFloat
    let keyHeight: CGFloat
    let rowSpacing: CGFloat
    let keySpacing: CGFloat
    /// From the last key row to the bottom of OUR view. Native's rows sit 25pt
    /// above the screen edge on a notched phone and 4pt on an SE; the difference
    /// is the 21pt home-indicator safe area, which our view already stops above.
    /// So the inset we apply is 4 on both.
    let bottomInset: CGFloat
    /// The strip WE draw. Native's zone (container top to first key row) measures
    /// 48.7 on notched phones and 49.0 on an SE, and the system paints part of it
    /// above our view — but that band is NOT the 16pt of portrait. Measured from
    /// where the system actually placed our view: 10pt on a notched phone, 15 on an
    /// SE. So the strip is 38.7 and 34 respectively.
    ///
    /// Deriving this from `referenceSuggestionHeight` (34, a portrait number) asked
    /// 171pt on an iPhone 16 where the zone needs 176. The system granted 176
    /// anyway and the strip absorbed the difference, which is exactly the kind of
    /// accident that looks fine until a host grants literally what you ask for.
    let stripHeight: CGFloat

    var keyBlockHeight: CGFloat { 4 * keyHeight + 3 * rowSpacing }
    /// What to ask the system for.
    var totalHeight: CGFloat { stripHeight + keyBlockHeight + bottomInset }

    /// Home-button phones are their own geometry class here, unlike in portrait
    /// where they share the sub-410pt class. Selected on ASPECT RATIO rather than
    /// on width: 16:9 versus the ~19.5:9 of every notched phone is the physical
    /// difference that causes it (no safe-area inset to work around), so it keeps
    /// classifying correctly on hardware that does not exist yet.
    static func of(screenSize: CGSize) -> PhoneLandscapeMetrics {
        let shorter = min(screenSize.width, screenSize.height)
        let longer = max(screenSize.width, screenSize.height)
        if longer / max(shorter, 1) < 2.0 {
            // 375x667. Larger keys than any notched phone, a wider bottom row, and
            // a view that spans the screen — so it applies native's inset itself.
            return PhoneLandscapeMetrics(
                sideInset: 72, keyHeight: 32, rowSpacing: 8,
                keySpacing: 6, bottomInset: 4, stripHeight: 34
            )
        }
        // Native's own inset is class-quantized on the SAME ~410pt portrait
        // boundary the portrait geometry uses — 79 below it, 121 at and above —
        // but the system has already applied it to our view. We add the 4pt that
        // is left, which measured identical on every notched phone.
        return PhoneLandscapeMetrics(
            sideInset: 4, keyHeight: 27.3, rowSpacing: 8.03,
            keySpacing: 6, bottomInset: 4, stripHeight: 38.7
        )
    }
}

enum KeyboardTheme {
    /// Whether the host presents us in the LEGACY (pre-Liquid-Glass) keyboard
    /// container. There is no public API for this; the keyboard controller detects
    /// it from the presentation's transient sizing pass (see
    /// LegacyPresentationDetector) and sets this before relayout. Main-thread only,
    /// like every renderer that reads it. Gates both metrics (native legacy zone is
    /// 53pt with no system band) and the key palette (legacy keys: dark ≈ white
    /// @0.30 over panel, light = opaque white — both measured).
    @MainActor static var legacyPresentation = false

    #if DEBUG
    /// Diagnosis-only override making the strip carry the whole native zone, as if
    /// no system band were coming. Set solely by the debug panel's pinned-presentation
    /// control so the two layouts can be A/B'd on device; the shipping path never
    /// reads a runtime-detected value here. See KeyboardSizingLog.
    @MainActor static var debugFullZoneStrip = false
    #endif

    private static let referencePhoneWidth: CGFloat = 440
    /// The suggestion strip WE draw. In the modern presentation the system paints an
    /// unpaintable band above the extension inside its container, so the VISIBLE zone
    /// (container edge → q row) = band + strip.
    ///
    /// The band's measured size WHEN PRESENT is used as a design estimate, not
    /// an OS guarantee. Its presence can change across iOS 27 presentations
    /// (see docs/keyboard-investigation.md). Earlier measurements found it on
    /// iOS 26.5 at 16.0pt and invariant under a swept asked height (217→307pt),
    /// repeated presentations, and host `inputAccessoryView`s of 0/44/88pt; measured
    /// on an iOS 27 device at 17.3pt in a third-party host. The earlier notes cite
    /// FB17978212 for an Apple explanation; that private feedback was not available
    /// to independently verify in the September 2026 audit.
    ///
    /// Do NOT reintroduce a runtime "is a band coming?" detector. One shipped briefly
    /// and keyed off the presentation's transient sizing heights, which are not
    /// stable (identical simulator presentations measured intermediates of 452 AND
    /// 481). Because the system pins our view's BOTTOM edge, changing this value
    /// moves every key row by the delta — a wrong guess re-shapes the whole keyboard,
    /// which is exactly the instability it was meant to cure.
    @MainActor
    private static var referenceSuggestionHeight: CGFloat {
        // Legacy presentation draws no system band, so the strip IS the zone
        // (native legacy zone: 53pt at every measured width).
        if legacyPresentation {
            return 53
        }
        #if DEBUG
        if debugFullZoneStrip {
            if #available(iOS 27.0, *) { return 54 }
            return 51
        }
        #endif
        // zone − band, per OS: iOS 27 native zone 54 − band ~17; iOS 26 zone ~51 − 16.
        if #available(iOS 27.0, *) {
            return 36
        }
        return 34
    }
    private static let referenceLandscapeHeight: CGFloat = 220

    private static let fallbackMetrics = KeyboardMetrics(
        keyCornerRadius: 6,
        keyShadowOpacity: 0,
        keyShadowRadius: 0,
        keyShadowOffset: CGSize(width: 0, height: 0.5),
        rowSpacing: 10.67,
        keySpacing: 6,
        rowTouchExtension: 8,
        keyTouchExtension: 10,
        suggestionHeight: 51,
        suggestionContentTopInset: 0,
        suggestionContentBottomInset: 0,
        minimumKeyHeight: 45,
        keyPreviewHeight: 77,
        keyPreviewMinimumWidth: 56,
        keyPreviewHorizontalOutset: 16,
        keyPreviewStemHeight: 0,
        keyPreviewStemWidth: 24,
        keyPreviewCornerRadius: 10,
        keyPreviewShadowOpacity: 0.32,
        keyPreviewShadowRadius: 4,
        keyPreviewShadowOffset: CGSize(width: 0, height: 2),
        keyboardInsets: UIEdgeInsets(top: 6, left: 6.67, bottom: 6, right: 6.67),
        characterFontSize: 23,
        symbolFontSize: 21,
        keyPreviewFontSize: 32,
        commandFontSize: 21,
        modeSwitchFontSize: 17,
        spaceIntroFontSize: 18,
        spaceLanguageFontSize: 11,
        suggestionFontSize: 15,
        deterministicSuggestionFontSize: 15
    )

    static var defaultMetrics: KeyboardMetrics {
        fallbackMetrics
    }

    @MainActor
    /// `portraitWidth` is the SCREEN's shorter side, and it has to be passed in
    /// rather than derived from `bounds`: in landscape `bounds.width` is the
    /// rotated width, which would classify an iPad Pro 11-inch at 1210pt as a
    /// 13-inch and an iPhone 16 at 852pt as a large phone. Both the iPad layout
    /// family and the iPhone landscape inset class are properties of the DEVICE.
    static func metrics(
        for bounds: CGSize,
        traitCollection: UITraitCollection,
        screenSize: CGSize = .zero
    ) -> KeyboardMetrics {
        let padPortraitWidth = min(screenSize.width, screenSize.height)
        let isLandscape = bounds.width > bounds.height && traitCollection.verticalSizeClass == .compact
        guard bounds.width > 0, bounds.height > 0 else {
            return fallbackMetrics
        }

        if isLandscape {
            if bounds.height > 260 {
                let scale = clamp(bounds.height / 320, min: 0.92, max: 1.0)
                return KeyboardMetrics(
                    keyCornerRadius: 6,
                    keyShadowOpacity: 0,
                    keyShadowRadius: 0,
                    keyShadowOffset: CGSize(width: 0, height: 0.5),
                    rowSpacing: 10 * scale,
                    keySpacing: clamp(bounds.width * 0.006, min: 6, max: 9),
                    rowTouchExtension: 8,
                    keyTouchExtension: 10,
                    suggestionHeight: 42 * scale,
                    suggestionContentTopInset: 0,
                    suggestionContentBottomInset: 0,
                    minimumKeyHeight: 54 * scale,
                    keyPreviewHeight: 78 * scale,
                    keyPreviewMinimumWidth: 58 * scale,
                    keyPreviewHorizontalOutset: 16 * scale,
                    keyPreviewStemHeight: 0,
                    keyPreviewStemWidth: 24 * scale,
                    keyPreviewCornerRadius: 10 * scale,
                    keyPreviewShadowOpacity: 0.32,
                    keyPreviewShadowRadius: 4 * scale,
                    keyPreviewShadowOffset: CGSize(width: 0, height: 2 * scale),
                    keyboardInsets: UIEdgeInsets(
                        top: 8 * scale,
                        left: clamp(bounds.width * 0.006, min: 7, max: 10),
                        bottom: 8 * scale,
                        right: clamp(bounds.width * 0.006, min: 7, max: 10)
                    ),
                    characterFontSize: 27 * scale,
                    symbolFontSize: 25 * scale,
                    keyPreviewFontSize: 34 * scale,
                    commandFontSize: 24 * scale,
                    modeSwitchFontSize: 18 * scale,
                    spaceIntroFontSize: 18 * scale,
                    spaceLanguageFontSize: 11,
                    suggestionFontSize: 16,
                    deterministicSuggestionFontSize: 16
                )
            }

            // Class-quantized off native (see PhoneLandscapeMetrics). Everything
            // here used to be a proportion of our own height — key height fell out
            // of `floor((bounds.height - …) / 4)`, which made every constant native
            // actually uses a function of whatever the host granted us.
            // From the SCREEN, never from `bounds`: in landscape the system hands
            // us a view narrower than the screen (702pt on an 852pt iPhone 16), so
            // `bounds.width` reads as a 1.79 aspect ratio and classified every
            // notched phone as a home-button one.
            let axis = PhoneLandscapeMetrics.of(
                screenSize: screenSize.width > 1 ? screenSize : bounds
            )
            let keySpacing = axis.keySpacing
            let rowSpacing = axis.rowSpacing
            let topInset: CGFloat = 0
            let bottomInset = axis.bottomInset
            let keyHeight = axis.keyHeight
            // The strip takes the remainder, so a host that grants a height other
            // than the one we asked for flexes the strip instead of walking the key
            // rows off native's.
            let suggestionHeight = clamp(
                bounds.height - topInset - bottomInset - axis.keyBlockHeight,
                min: 20,
                max: 60
            )
            return KeyboardMetrics(
                keyCornerRadius: 5.5,
                keyShadowOpacity: 0,
                keyShadowRadius: 0,
                keyShadowOffset: CGSize(width: 0, height: 0.5),
                rowSpacing: rowSpacing,
                keySpacing: keySpacing,
                rowTouchExtension: 7,
                keyTouchExtension: 9,
                suggestionHeight: suggestionHeight,
                suggestionContentTopInset: 0,
                suggestionContentBottomInset: 0,
                minimumKeyHeight: keyHeight,
                keyPreviewHeight: 0,
                keyPreviewMinimumWidth: 0,
                keyPreviewHorizontalOutset: 0,
                keyPreviewStemHeight: 0,
                keyPreviewStemWidth: 0,
                keyPreviewCornerRadius: 0,
                keyPreviewShadowOpacity: 0,
                keyPreviewShadowRadius: 0,
                keyPreviewShadowOffset: .zero,
            keyboardInsets: UIEdgeInsets(
                top: topInset,
                // Native's landscape container does not span the screen: it is
                // inset 79pt below the ~410pt portrait boundary and 121 above it,
                // 72 on a home-button phone. The old 3-4pt was a phone-portrait
                // number applied to a layout it was never measured on.
                left: axis.sideInset,
                bottom: bottomInset,
                right: axis.sideInset
            ),
                characterFontSize: 21,
                symbolFontSize: 19,
                keyPreviewFontSize: 0,
                commandFontSize: 19,
                modeSwitchFontSize: 16,
                spaceIntroFontSize: 16,
                spaceLanguageFontSize: 10,
                suggestionFontSize: 15,
                deterministicSuggestionFontSize: 15
            )
        }

        // Measured against native iOS 26.5 portrait captures at 402/420/440pt.
        // Use supported system fonts; exact private keyboard font identity is not
        // documented. Preserve unmeasured legacy/older-OS typography for now.
        let measuredModernPhoneType: Bool
        if #available(iOS 26.0, *) {
            measuredModernPhoneType = !legacyPresentation
        } else {
            measuredModernPhoneType = false
        }
        let scale = clamp(bounds.width / referencePhoneWidth, min: 0.88, max: 1.0)
        // Type and key spacing scale with the taller iPad key; `scale` is capped at
        // 1.0, so without this an 834pt iPad drew 440pt-iPhone glyphs.
        let isPad = traitCollection.userInterfaceIdiom == .pad
        // The device's portrait width, which is what picks the family. Falls back
        // to the layout width, correct in portrait and the only thing available
        // before the window exists.
        let portraitWidth = padPortraitWidth > 1 ? padPortraitWidth : bounds.width
        let padFamily = isPad ? KeyboardLayoutProvider.PadFamily.forPortraitWidth(Double(portraitWidth)) : nil
        // Our own bounds are always wider than tall (a keyboard is a wide strip),
        // so orientation has to come from comparing the layout width against the
        // device's portrait width, never from our aspect ratio.
        let padIsLandscape = isPad && bounds.width > portraitWidth + 1
        let padMetrics = padFamily.map { PadAxisMetrics.of($0, landscape: padIsLandscape, portraitWidth: portraitWidth) }
        let padTypeScale: CGFloat = padMetrics.map { $0.keyHeight / 45.0 } ?? 1
        let padType = padFamily.map { PadAxisMetrics.KeyType.of($0, landscape: padIsLandscape) }
        // The gap between keys is a per-family CONSTANT on iPad (12 / 10 / 7),
        // measured off native — not a scaled version of the phone's 6pt.
        let keySpacing = padMetrics?.gap ?? clamp(6 * scale, min: 5.25, max: 6)
        // Portrait key geometry is CLASS-QUANTIZED, not proportional to width —
        // measured against native across 375/393/402/420/430/440pt (iOS 26.5 sim,
        // modern + legacy hosts): pitch 54 / key 43 below ~410pt, pitch 56 / key 45
        // at 410pt and up, row gap 11 in both classes. The previous width/440
        // scaling shrank keys ~9% on Pro-class widths and sat the rows ~9pt below
        // native's (worst on SE-class, 18.5pt).
        // iPad is its own geometry class, and unlike iPhone its VERTICAL metrics do
        // not vary with width at all: measured across 744/820/834pt native key
        // height moves 0.5pt and total keyboard height 3pt, so both are family
        // constants. The 13-inch family is a different keyboard entirely — five
        // rows, taller keys, tighter gaps. See docs/native-parity-ipad.md.
        let compactWidthClass = bounds.width < 410
        let keyHeight: CGFloat = padMetrics?.keyHeight ?? (compactWidthClass ? 43 : 45)
        let rowSpacing: CGFloat = padMetrics?.rowSpacing ?? 11
        let keyRowCount = padFamily == .extended ? 5 : 4
        let topInset: CGFloat = 0
        // Verified: with 6, class-B q-rows land exactly on native's (440: 663=663).
        // Class A solves to 3 from the measured chain (q = screen − dock − keyblock
        // − bottom + strip; native q 591 @ 402pt) — re-verified on-sim.
        let bottomInset: CGFloat = padMetrics?.bottomInset ?? (compactWidthClass ? 3 : 6)
        // The strip takes the remainder of the actual bounds, so if a host hands us
        // a height other than the one we ask for, the strip flexes instead of the
        // keys drifting off native's rows.
        // The number row is shorter than the letter rows on the extended layout, so
        // the key block is not simply rowCount * keyHeight.
        let keyBlockHeight = padMetrics?.keyBlockHeight(rowCount: keyRowCount)
            ?? (CGFloat(keyRowCount) * keyHeight + CGFloat(keyRowCount - 1) * rowSpacing)
        let suggestionHeight = clamp(
            bounds.height - topInset - bottomInset - keyBlockHeight,
            min: 24,
            max: 96
        )
        return KeyboardMetrics(
            // Native's corner arc spans ~7pt at 440pt (measured: the top-row edge
            // inset decays 6.33 → 0 over 7 rows), drawn with a continuous curve.
            keyCornerRadius: clamp(7 * scale, min: 6, max: 7) * padTypeScale,
            keyShadowOpacity: 0,
            keyShadowRadius: 0,
            keyShadowOffset: CGSize(width: 0, height: 0.5),
            rowSpacing: rowSpacing,
            keySpacing: keySpacing,
            rowTouchExtension: 8,
            keyTouchExtension: 10,
            suggestionHeight: suggestionHeight,
            suggestionContentTopInset: 0,
            suggestionContentBottomInset: 0,
            minimumKeyHeight: keyHeight,
            keyPreviewHeight: 77 * scale,
            keyPreviewMinimumWidth: 56 * scale,
            keyPreviewHorizontalOutset: 16 * scale,
            keyPreviewStemHeight: 0,
            keyPreviewStemWidth: 24 * scale,
            keyPreviewCornerRadius: 10 * scale,
            keyPreviewShadowOpacity: 0.32,
            keyPreviewShadowRadius: 4 * scale,
            keyPreviewShadowOffset: CGSize(width: 0, height: 2 * scale),
            keyboardInsets: UIEdgeInsets(
                top: topInset,
                // Side margin is a measured per-family constant on iPad (6 / 9 / 3.5).
                left: padMetrics?.margin ?? clamp(6.67 * scale, min: 5.87, max: 6.67),
                bottom: bottomInset,
                right: padMetrics?.margin ?? clamp(6.67 * scale, min: 5.87, max: 6.67)
            ),
            // iPad type comes from PadAxisMetrics.Type — measured constants per
            // orientation — not from scaling the phone's. See that type for why.
            characterFontSize: padType.map(\.letter) ?? (measuredModernPhoneType ? 25 : 23 * scale),
            symbolFontSize: padType.map { $0.letter * 0.91 } ?? 21 * scale,
            keyPreviewFontSize: 32 * scale,
            commandFontSize: padType.map(\.command) ?? 21 * scale,
            modeSwitchFontSize: padType.map(\.modeSwitch) ?? (measuredModernPhoneType ? 18 : 17 * scale),
            spaceIntroFontSize: 18,
            spaceLanguageFontSize: 11,
            // Suggestion type scales with the iPad key like every other glyph does.
            // At the phone's flat 15pt the strip's Bangla measured 9.5pt of ink
            // against native's 15.5pt on the same screen, which is most of why it
            // read as a sliver.
            suggestionFontSize: !isPad && measuredModernPhoneType ? 17 : 15 * padTypeScale,
            deterministicSuggestionFontSize: !isPad && measuredModernPhoneType ? 17 : 15 * padTypeScale,
            padSecondaryFontSize: padType?.secondary ?? 10,
            padSecondaryTopInset: padType?.secondaryTop ?? 8,
            padNumberRowHeight: padMetrics?.numberRowHeight ?? 0,
            padGlyphInsets: padType?.glyphInsets,
            suggestionSlotCount: PadAxisMetrics.suggestionSlotCount(
                forLayoutWidth: bounds.width, isPad: isPad
            ),
            suggestionContentHeight: isPad ? PadAxisMetrics.suggestionContentHeight : 0
        )
    }

    @MainActor
    static func preferredKeyboardHeight(
        for screenSize: CGSize,
        traitCollection: UITraitCollection
    ) -> CGFloat {
        let shorterSide = min(screenSize.width, screenSize.height)
        let longerSide = max(screenSize.width, screenSize.height)
        let isLandscape = traitCollection.verticalSizeClass == .compact || screenSize.width > screenSize.height

        // iPad first, and in BOTH orientations, because the generic landscape
        // clamps below are phone heuristics: on an iPad Pro 11-inch they asked for
        // ~300pt against a 331pt key block, which simply overflows. Every number
        // here comes from PadAxisMetrics, so a change there cannot drift out of
        // step with what the rows actually need.
        if traitCollection.userInterfaceIdiom == .pad {
            let family = KeyboardLayoutProvider.PadFamily.forPortraitWidth(Double(shorterSide))
            let axis = PadAxisMetrics.of(family, landscape: isLandscape, portraitWidth: shorterSide)
            let rows = family == .extended ? 5 : 4
            // Not `referenceSuggestionHeight`: that is the iPhone's strip, sized
            // against the ~16pt band iOS paints above a phone keyboard. iPad's band
            // is the 45.5pt shortcuts bar, and our strip matches it so the two form
            // a pair of equal rows.
            return axis.askedStripHeight + axis.keyBlockHeight(rowCount: rows) + axis.bottomInset
        }

        if isLandscape {
            if shorterSide >= 600 {
                return clamp(shorterSide * 0.36, min: 300, max: 360)
            }
            // Class-quantized off native, like portrait. The previous
            // `clamp(shorterSide * 0.50, 196...220)` was a heuristic that had never
            // been checked against the system keyboard; it asked for 196.5 on an
            // iPhone 16 where native's container is 207.
            return PhoneLandscapeMetrics.of(screenSize: screenSize).totalHeight
        }

        // Class-quantized like the metrics: key 43 / pitch 54 / bottom 3 below
        // ~410pt, key 45 / pitch 56 / bottom 6 above (native-measured; see
        // metrics(for:)).
        let compact = shorterSide < 410
        let keyHeight: CGFloat = compact ? 43 : 45
        let bottomInset: CGFloat = compact ? 3 : 6
        let classHeight = referenceSuggestionHeight + 4 * keyHeight + 3 * 11 + bottomInset
        let minimumHeight = shorterSide >= 600 ? min(longerSide * 0.20, 320) : 199
        return clamp(classHeight, min: minimumHeight, max: max(minimumHeight, classHeight))
    }

    @MainActor
    static func preferredEmojiKeyboardHeight(
        for screenSize: CGSize,
        traitCollection: UITraitCollection
    ) -> CGFloat {
        let shorterSide = min(screenSize.width, screenSize.height)
        let longerSide = max(screenSize.width, screenSize.height)
        let isLandscape = traitCollection.verticalSizeClass == .compact || screenSize.width > screenSize.height

        // iPad: exactly the height of the letters keyboard. This branch did not
        // exist, so an iPad fell through to a phone heuristic and asked for ~332pt
        // against a 367pt keyboard — the panel jumped 35pt shorter on opening and
        // 35pt taller on closing, on a device with room to spare.
        if traitCollection.userInterfaceIdiom == .pad {
            return preferredKeyboardHeight(for: screenSize, traitCollection: traitCollection)
        }

        if isLandscape {
            return clamp(shorterSide * 0.58, min: 250, max: 330)
        }

        let scale = clamp(shorterSide / referencePhoneWidth, min: 0.88, max: 1.0)
        let fourRowEmojiHeight = 332 * scale
        let maximumHeight = longerSide * 0.42
        return clamp(fourRowEmojiHeight, min: 306 * scale, max: maximumHeight)
    }

    private static func clamp(_ value: CGFloat, min lowerBound: CGFloat, max upperBound: CGFloat) -> CGFloat {
        Swift.max(lowerBound, Swift.min(value, upperBound))
    }

    static func primaryKeyColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
        }
        return UIColor.white.withAlphaComponent(0.96)
    }

    static func utilityKeyColor(for traitCollection: UITraitCollection) -> UIColor {
        primaryKeyColor(for: traitCollection)
    }

    static func highlightedPrimaryKeyColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(red: 0.315, green: 0.315, blue: 0.325, alpha: 1)
        }
        return UIColor.white
    }

    static func highlightedUtilityKeyColor(for traitCollection: UITraitCollection) -> UIColor {
        highlightedPrimaryKeyColor(for: traitCollection)
    }

    /// Translucent tint layered over a Liquid Glass key (iOS 26+) so the colored
    /// backdrop refracts through — the rest state is faint, the pressed state
    /// brightens (mirroring the native key's touch-down lift). Unified for
    /// character and utility keys to match the current design, where
    /// `utilityKeyColor == primaryKeyColor`.
    ///
    /// Alphas are calibrated to Apple's own keys sampled on iOS 27 (native vs
    /// Obadh, dark/light × solid/gradient hosts). A neutral white tint, not a cool
    /// one: native's cool cast in some hosts comes from the backdrop refracting
    /// through the glass, so over a neutral backdrop native keys are neutral — a
    /// cool tint made ours read cool where native didn't. Light native keys are
    /// near-opaque white (~254), so the light alpha runs high; dark keys stay
    /// visibly translucent (~64).
    /// The measured key fill. No debug overrides reach this: a persisted override
    /// pref once survived reinstalls and silently re-tinted dark mode, so the shipped
    /// values are the only values, in every build configuration.
    ///
    /// Rest alphas solved from same-backdrop screenshot sampling against native
    /// (iOS 26.5, modern presentation, mid-gray measurement background):
    /// dark — native key 78 over panel 44 → white @ (78−44)/(255−44) ≈ 0.16;
    /// light — native key ~246.5 over panel ~192 → white @ ≈ 0.87.
    /// Pressed lifts keep the shipped relative feel.
    @MainActor
    static func glassKeyTint(for traitCollection: UITraitCollection, highlighted: Bool) -> UIColor {
        let isDark = traitCollection.userInterfaceStyle == .dark
        if legacyPresentation || traitCollection.accessibilityContrast == .high
            || UIAccessibility.isReduceTransparencyEnabled {
            // Native uses this stronger overlay with Reduce Transparency or
            // Increase Contrast too (verified on the modern keyboard). The
            // UIInputView backdrop itself becomes opaque under those settings.
            // Measured against native: dark key 129 over panel 74 → white
            // @ (129−74)/(255−74) ≈ 0.30; light keys are opaque white (255).
            if isDark {
                return UIColor.white.withAlphaComponent(highlighted ? 0.51 : 0.30)
            }
            return UIColor.white.withAlphaComponent(highlighted ? 0.94 : 1.0)
        }
        if isDark {
            return UIColor.white.withAlphaComponent(highlighted ? 0.37 : 0.16)
        }
        return UIColor.white.withAlphaComponent(highlighted ? 0.94 : 0.87)
    }


    static func keyPreviewColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(red: 0.235, green: 0.235, blue: 0.243, alpha: 1)
        }
        return .white
    }

    static func textColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return .white
        }
        return .black
    }

    static func separatorColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(red: 0.220, green: 0.220, blue: 0.227, alpha: 1)
        }
        return UIColor.black.withAlphaComponent(0.12)
    }

    static func secondaryTextColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.56)
        }
        return UIColor.black.withAlphaComponent(0.48)
    }

    /// The iPad flick label. Measured off native: white 0.30 in dark, black 0.25 in
    /// light — half the weight of `secondaryTextColor`, which it used to borrow.
    /// At 0.56 the hint competed with the letter instead of sitting under it, and
    /// combined with our undersized glyph it inverted native's relationship
    /// entirely: native's flick label is BIGGER and FAINTER than ours was.
    static func padSecondaryTextColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.30)
        }
        return UIColor.black.withAlphaComponent(0.25)
    }

    /// Suggestion text. Deliberately darker than `secondaryTextColor`, which the
    /// strip used to borrow: measured against native's prediction row, the system
    /// draws it at black 0.76 / white 0.64 while the assistant glyphs beside it are
    /// the lighter secondary tone. At 0.48 our suggestions read as chrome rather
    /// than as content you are meant to tap. Identical on iPhone and iPad, and on
    /// both, native measured the same to the hundredth.
    static func suggestionTextColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.64)
        }
        return UIColor.black.withAlphaComponent(0.76)
    }

    static func suggestionHighlightColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.08)
        }
        return UIColor.black.withAlphaComponent(0.07)
    }

    static func emojiSearchBackgroundColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.12)
        }
        return UIColor.black.withAlphaComponent(0.08)
    }

    static func emojiPlaceholderColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.56)
        }
        return UIColor.black.withAlphaComponent(0.42)
    }

    static func emojiCategoryTintColor(selected: Bool, traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(selected ? 0.94 : 0.56)
        }
        return UIColor.black.withAlphaComponent(selected ? 0.88 : 0.48)
    }

    static func emojiCategorySelectedBackgroundColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.13)
        }
        return UIColor.black.withAlphaComponent(0.09)
    }

    static func emojiCellHighlightColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor.white.withAlphaComponent(0.14)
        }
        return UIColor.black.withAlphaComponent(0.10)
    }

    static func keyboardBackgroundColor(for traitCollection: UITraitCollection) -> UIColor {
        if traitCollection.userInterfaceStyle == .dark {
            return UIColor(red: 0.090, green: 0.090, blue: 0.090, alpha: 1)
        }
        return UIColor(red: 0.820, green: 0.843, blue: 0.882, alpha: 1)
    }

}
