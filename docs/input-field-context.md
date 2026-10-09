# Input-field context

Obadh reads the host editor's public `UITextInputTraits` through
`textDocumentProxy`. The UIKit adapter converts those optional properties into
`KeyboardFieldTraits`; the Foundation-only `KeyboardFieldPolicy` controls both
layout and typing. Other platform adapters can reuse the policy without importing
UIKit or putting field decisions into the transliteration engine.

## Field behavior

| Host hint | Layout and input | Language assistance |
| --- | --- | --- |
| Default text | Existing phonetic QWERTY; Bangla digits and punctuation pages | Bangla suggestions, corrections and personal learning |
| Email address or email content | Literal Latin, prominent `@` and `.` | No transliteration, correction, learning, emoji, voice or smart punctuation |
| URL or URL content | Literal Latin, `/`, `.`, and `.com` on iPhone; syntax keys and flicks on iPad | Same protections as email |
| ASCII capable | Literal Latin; ASCII digits, period and currency substitutions | Host capitalization and smart punctuation; no Bangla suggestions or learning |
| Number / ASCII number pad | ASCII digits, Delete, and a globe when required | No language transforms or space |
| Decimal pad | Number pad plus the current locale's decimal separator | No automatic separator validation or substitution |
| Numbers and punctuation | Opens the existing Bangla numbers page | Bangla assistance when the user returns to letters |
| Web search | Bangla letters plus prominent period | Suggestions; double-space punctuation suppressed |
| Social / Twitter | Bangla letters plus `@` and `#` | Bangla assistance |
| Username, postal/tracking/flight identifier | Literal input; no numeric pad inferred from content alone | No language assistance, learning, emoji or voice |
| Password, OTP, card details, cellular identifiers | Literal input, or the explicitly requested numeric pad | Same protections as identifiers |
| Person or cardholder name | Phonetic Bangla | No automatic correction or personal learning |

Explicit numeric and syntax keyboard types take precedence. Semantic email/URL
content fills in a missing syntax hint; credential content always protects input.
An alphanumeric OTP must not become a number pad merely because its content type
is `oneTimeCode`. Unknown types and absent hints retain normal Bangla behavior.
Unavailable emoji command slots on iPad and protected standard layouts are inert,
invisible, and omitted from accessibility while preserving surrounding geometry.

Apple takes over secure fields and phone/name-phone pads, and host apps can
disable third-party keyboards entirely. These restrictions cannot be overridden
by the extension. Obadh's phone-pad fallback is only defensive; it is not a way
to bypass that takeover. Voice restrictions above apply to Obadh's own control;
the system can still display its dictation button below the extension.

## Host preferences

- `autocorrectionType = .no` disables replacement and correction lookup, including
  the synchronous exact-loanword fallback on a rapid Space press. Deterministic
  phonetic composition and explicit next-word choices remain available.
- `spellCheckingType = .no` suppresses correction choices for committed words at
  the cursor independently of active-word autocorrection.
- Smart quote, dash, and insert/delete opt-outs are independent. Inserting an
  explicitly chosen suggestion adds no automatic spaces when smart spacing is
  disabled. Explicit Space presses still insert spaces.
- Automatic capitalization applies only to literal Latin input. Uppercasing
  Roman phonetic keystrokes would change Bangla spelling; Bangla never inherits
  host sentence/word capitalization. Manual Shift and Caps Lock remain available.
- Explicit light/dark appearance overrides system appearance; `.default` follows
  the normal presentation.

The internal emoji search editor has its own ASCII layout and Return state. It
does not inherit email/URL shortcuts or numeric restrictions from the host field.

## Focus, asynchronous work, and dictation

Traits are refreshed on appearance, text and selection callbacks. Before edits,
the controller checks the document identifier and keyboard type as a backstop
for hosts that omit focus callbacks. Fresh fingers refresh hints before the touch
surface resolves a key, so the new field's first letter is retained while old
contacts are discarded. A field transition cancels held Delete,
queued touches, previews, and pending suggestions; invalidates posted results;
clears composition ownership and session context; closes the emoji panel; and
resets the starting page and automatic case. Existing text in the old field stays
as written. The transition never commits or rewrites text in the new field.

The serial engine queue orders session clearing after any previous field's
already-enqueued learning. Literal/private fields never enqueue new learning.
Trait snapshots are cached so ordinary keystrokes do not repeatedly request every
optional property from the host. UIKit sometimes returns a nil document identifier
before connecting the editor despite its nonnull declaration; the adapter reads
the same public Objective-C accessor without forcing a Swift UUID bridge.

Dictation records its destination document ID when available. A focus change or
newly ineligible field abandons keyboard delivery, leaves the app's transcript
unacknowledged, and offers Copy. A recreated controller can deliver to the same
document, but cannot silently deliver to a different identified document.
Destination eligibility is rechecked at the edit boundary, and a refused edit
does not acknowledge the app's transcript. Older
pending records without IDs remain readable; their existing context reconciliation
continues to apply.

## Return and qualification limits

Obadh displays the Return action actually exposed by the proxy, with accessible
labels and disabled state. Automatic availability uses active composition or
whole-document `hasText`, including text after the cursor. Web-search fields on
the tested iOS 26.5 runtime expose **Go** even when the host assigns `.search`;
native English shows Go in the same field.

Activation commits the composed word first, then sends `insertText("\n")` as a
separate public Return input. The host controls whether this inserts a newline
or invokes an action. **Single-line UITextField submission diverges on the tested
iOS 26.5 simulator:** native Send calls the delegate, whereas the extension's
newline becomes a space. This is an open acceptance gate, not native parity;
see [KI-005](../KNOWN-ISSUES.md#ki-005). No private Return dispatch is shipped.

The DEBUG `--keyboard-field-test` host and `KeyboardFieldContextUITests` exercise
real first responders through the keyboard service. Pure policy/layout tests and
production-controller tests cover missing traits, private fields, opt-outs,
focus races and dictation destination binding. Physical iPhone 11-family testing,
iPad visual qualification, third-party/web editors, and other OS runtimes remain
required before shipping. The simulator's device name does not measure A13 speed
or memory. Literal Latin input does not gain an English prediction model here.

Platform references: Apple's [custom keyboard configuration](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface),
[input traits](https://developer.apple.com/documentation/uikit/uitextinputtraits),
and [document proxy](https://developer.apple.com/documentation/uikit/uitextdocumentproxy).
