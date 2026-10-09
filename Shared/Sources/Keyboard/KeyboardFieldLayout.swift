import Foundation

/// Field-specific content reuses the measured QWERTY geometry. It never changes
/// a key's output through transliteration: syntax keys are literal symbols.
enum KeyboardFieldLayout {
    static func adapt(_ rows: [KeyboardRow], mode: KeyboardMode, field: KeyboardFieldPolicy,
                      isPad: Bool, includesGlobeKey: Bool) -> [KeyboardRow] {
        var rows = rows.map { row in
            KeyboardRow(keys: row.keys.map {
                if $0 == .emoji && !field.allowsEmoji { return .spacer }
                return asciiKey($0, enabled: field.usesASCIISymbols)
            },
                        keyWeights: row.keyWeights, customSpacingAfterKeyIndex: row.customSpacingAfterKeyIndex,
                        leadingFlex: row.leadingFlex, trailingFlex: row.trailingFlex)
        }
        guard mode == .letters else { return rows }
        let shortcuts: [KeyboardKey]
        switch field.layout {
        case .email: shortcuts = [literal("@"), literal(".")]
        case .url: shortcuts = [literal("/"), literal(".")]
        case .webSearch: shortcuts = [literal(".")]
        case .social: shortcuts = [literal("@"), literal("#")]
        default: return rows
        }
        if isPad {
            // All iPad families already have punctuation next to the lower letters.
            // Replace those cells instead of squeezing the command row or losing
            // its globe, microphone, or keyboard-dismiss controls.
            rows = rows.map { row in
                var shortcutIndex = 0
                let keys = row.keys.map { key -> KeyboardKey in
                    guard case .symbol(let symbol) = key,
                          symbol.output == "," || symbol.output == "।" || symbol.output == ".",
                          shortcutIndex < shortcuts.count else { return key }
                    defer { shortcutIndex += 1 }
                    return shortcuts[shortcutIndex]
                }
                return KeyboardRow(keys: keys, keyWeights: row.keyWeights,
                                   customSpacingAfterKeyIndex: row.customSpacingAfterKeyIndex,
                                   leadingFlex: row.leadingFlex, trailingFlex: row.trailingFlex)
            }
        } else {
            // Keep the existing leading block and Return width. Each syntax key
            // takes one standard key plus a gap out of the space/domain span.
            var leading: [KeyboardKey] = [.modeSwitch("123")]
            if field.allowsEmoji { leading.append(.emoji) }
            if includesGlobeKey { leading.append(.globe) }
            let eachLeading = (102.0 - Double(leading.count - 1) * 6.0) / Double(leading.count)
            let centreWidth = 210.67 - Double(shortcuts.count) * (37.33 + 6.0)
            let centre: KeyboardKey = field.layout == .url ? literal(".com") : .space
            let keys: [KeyboardKey]
            if shortcuts.count == 2 {
                keys = leading + [shortcuts[0], centre, shortcuts[1], .returnKey]
            } else {
                keys = leading + [centre, shortcuts[0], .returnKey]
            }
            let weights = Array(repeating: eachLeading, count: leading.count)
                + (shortcuts.count == 2 ? [37.33, centreWidth, 37.33] : [centreWidth, 37.33])
                + [102.33]
            rows[rows.count - 1] = KeyboardRow(keys: keys, keyWeights: weights)
        }
        return rows
    }

    static func numericRows(field: KeyboardFieldPolicy, includesGlobeKey: Bool,
                            isPad: Bool, family: KeyboardLayoutProvider.PadFamily) -> [KeyboardRow] {
        var rows = ["123", "456", "789"].map { digits in
            KeyboardRow(keys: digits.map { literal(String($0)) })
        }
        var left: [KeyboardKey] = []
        if field.layout == .decimalPad { left.append(literal(field.traits.decimalSeparator)) }
        if field.layout == .phonePad { left.append(literal("+")) }
        if includesGlobeKey { left.append(.globe) }
        if left.isEmpty { left = [.spacer] }
        rows.append(KeyboardRow(keys: left + [literal("0"), .backspace],
                                keyWeights: Array(repeating: 1.0 / Double(left.count), count: left.count) + [1, 1]))
        if isPad {
            // A compact pad uses the same four rows. Wider iPads retain a path
            // to dismiss and to activate an explicit host action.
            var commands: [KeyboardKey] = [.hideKeyboard]
            if field.traits.returnAction != .default { commands.insert(.returnKey, at: 0) }
            if family == .extended {
                rows.insert(KeyboardRow(keys: commands), at: 0)
            } else {
                let bottom = rows.removeLast()
                rows.append(KeyboardRow(keys: bottom.keys + commands,
                                        keyWeights: (bottom.keyWeights ?? []) + Array(repeating: 0.65, count: commands.count)))
            }
        }
        return rows
    }

    static func asciiKey(_ key: KeyboardKey, enabled: Bool) -> KeyboardKey {
        guard enabled, case .symbol(let symbol) = key else { return key }
        let output: String
        switch symbol.output {
        case "।": output = "."
        case ".": output = "'" // The prose page already has a separate দাঁড়ি cell.
        case "৳": output = "$"
        default: output = asciiDigits(symbol.output)
        }
        return literal(output)
    }

    static func secondary(for key: KeyboardKey, field: KeyboardFieldPolicy) -> KeyboardSymbol? {
        guard let secondary = key.padSecondary else { return nil }
        guard field.usesASCIISymbols else { return secondary }
        let output = secondary.output == "৳" ? "$" : asciiDigits(secondary.output)
        return .literal(output)
    }

    private static func asciiDigits(_ value: String) -> String {
        String(value.unicodeScalars.map { scalar -> Character in
            if (0x09E6...0x09EF).contains(scalar.value) {
                return Character(UnicodeScalar(scalar.value - 0x09E6 + 0x30)!)
            }
            return Character(scalar)
        })
    }

    private static func literal(_ text: String) -> KeyboardKey { .symbol(.literal(text)) }
}
