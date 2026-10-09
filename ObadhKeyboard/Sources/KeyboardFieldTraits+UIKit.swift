import UIKit

extension KeyboardFieldTraits {
    /// UIKit can return nil before establishing the host connection, despite
    /// declaring this Objective-C property nonnull. Reading it directly as a
    /// Swift UUID traps in the Foundation bridge. KVC calls the same public
    /// accessor while preserving its actual optional Objective-C result.
    @MainActor
    static func documentIdentifier(for proxy: any UITextDocumentProxy) -> UUID? {
        (proxy as? NSObject)?.value(forKey: #keyPath(UITextDocumentProxy.documentIdentifier)) as? UUID
    }

    /// Optional protocol properties may be absent on custom host editors. Never
    /// inspect a view hierarchy or guess the field type from the user's text.
    @MainActor
    init(proxy: any UITextDocumentProxy) {
        self.init()
        switch proxy.keyboardType ?? .default {
        case .default: kind = .text
        case .asciiCapable: kind = .ascii
        case .numbersAndPunctuation: kind = .numbersAndPunctuation
        case .URL: kind = .url
        case .numberPad, .asciiCapableNumberPad: kind = .numberPad
        case .phonePad: kind = .phonePad
        case .namePhonePad: kind = .namePhonePad
        case .emailAddress: kind = .email
        case .decimalPad: kind = .decimalPad
        case .twitter: kind = .social
        case .webSearch: kind = .webSearch
        @unknown default: kind = .text
        }
        switch proxy.textContentType ?? nil {
        case .emailAddress: content = .email
        case .URL: content = .url
        case .username, .postalCode, .shipmentTrackingNumber, .flightNumber:
            content = .identifier
        case .password, .newPassword, .oneTimeCode, .creditCardNumber,
             .creditCardSecurityCode, .creditCardExpiration, .creditCardExpirationMonth,
             .creditCardExpirationYear, .cellularEID, .cellularIMEI:
            content = .privateText
        case .name, .namePrefix, .nameSuffix, .givenName, .middleName, .familyName,
             .nickname, .creditCardName, .creditCardGivenName, .creditCardMiddleName,
             .creditCardFamilyName:
            content = .personName
        default: content = .ordinary
        }
        correction = Self.preference(proxy.autocorrectionType?.rawValue)
        spelling = Self.preference(proxy.spellCheckingType?.rawValue)
        smartQuotes = Self.preference(proxy.smartQuotesType?.rawValue)
        smartDashes = Self.preference(proxy.smartDashesType?.rawValue)
        smartInsertDelete = Self.preference(proxy.smartInsertDeleteType?.rawValue)
        switch proxy.autocapitalizationType ?? .sentences {
        case .none: capitalization = .none
        case .words: capitalization = .words
        case .sentences: capitalization = .sentences
        case .allCharacters: capitalization = .allCharacters
        @unknown default: capitalization = .none
        }
        switch proxy.returnKeyType ?? .default {
        case .default: returnAction = .default
        case .go: returnAction = .go
        case .google: returnAction = .google
        case .join: returnAction = .join
        case .next: returnAction = .next
        case .route: returnAction = .route
        case .search: returnAction = .search
        case .send: returnAction = .send
        case .yahoo: returnAction = .yahoo
        case .done: returnAction = .done
        case .emergencyCall: returnAction = .emergencyCall
        case .continue: returnAction = .continue
        @unknown default: returnAction = .default
        }
        automaticallyEnablesReturn = proxy.enablesReturnKeyAutomatically ?? false
        isSecure = proxy.isSecureTextEntry ?? false
        switch proxy.keyboardAppearance ?? .default {
        case .default: appearance = .automatic
        case .light: appearance = .light
        case .dark: appearance = .dark
        @unknown default: appearance = .automatic
        }
        decimalSeparator = Locale.current.decimalSeparator ?? "."
    }

    private static func preference(_ rawValue: Int?) -> Preference {
        switch rawValue {
        case 1: .disabled
        case 2: .enabled
        default: .unspecified
        }
    }
}
