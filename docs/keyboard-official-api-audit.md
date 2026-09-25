# Keyboard development documentation audit

Checked 2026-09-25 on `investigate/keyboard-handoff-research`.
Current Apple documentation was read through its Markdown endpoints, alongside
the installed Xcode 26.6 Custom Keyboard Extension template. Search snippets and
forum reports are leads, not API contracts. This audit does not establish an
iOS 27 height fix.

## Sizing and lifecycle

Apple's current [interface guide](https://developer.apple.com/documentation/uikit/configuring-a-custom-keyboard-interface)
supports changing the extension's primary-view height through Auto Layout.
[allowsSelfSizing](https://developer.apple.com/documentation/uikit/uiinputview/allowsselfsizing)
makes UIKit use `systemLayoutSizeFitting`; it does not promise a fixed margin
outside that view. Obadh requests its content height this way. Both the minimal
control and explicit fitting-size experiment still reproduce the margin change.
There is no documented additional 17-point inset that the extension should add.

The local Xcode template puts sizing work in `updateViewConstraints`, calls the
superclass implementation, and handles globe visibility in
`viewWillLayoutSubviews`. Obadh already updates its requested height in
`updateViewConstraints`. The template contains no foreground reconnection step.
The current [controller API](https://developer.apple.com/documentation/uikit/uiinputviewcontroller)
also exposes no method to reset the host app's keyboard container.

The [archived guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/CustomKeyboard.html)
is dated 2017. Its height-after-first-draw note explicitly refers to iOS 8.0;
it is not evidence that modern keyboards must delay their height constraint.
Use the current guide and actual device measurements for current behavior.

## Input connection

The current [text interaction guide](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards)
says to use the controller's `textDocumentProxy` and observe both text and
selection delegate callbacks. Obadh does this and resets composition on external
changes. The guide explains that callback arguments are nil in an extension;
nil is not evidence of a lost connection.

[documentIdentifier](https://developer.apple.com/documentation/uikit/uitextdocumentproxy/documentidentifier)
is a public way to distinguish documents. Production does not currently use it
as a composition boundary; adding that guard needs a focused field-switch test.
The diagnostic keyboard now records identifiers and context lengths, without
recording document contents. A changed identifier by itself does not prove that
the proxy has become invalid.

Marked-text APIs are available, but the current Obadh design deliberately uses
ordinary text with composition bookkeeping. Switching to marked text would be
a separate editing behavior change, not a documented container-height remedy.

## Confirmed implementation gaps needing behavioral tests

| Area | Official capability and present implementation | Verification needed |
| --- | --- | --- |
| Host field traits | [UITextInputTraits](https://developer.apple.com/documentation/uikit/uitextinputtraits) includes keyboard type, Return style, autocorrection preferences and automatic Return availability. Shipping keyboard source does not read those traits. | Dedicated email/URL/number/search editors, empty Return state, and autocorrection-disabled fields. Preserve Bangla composition and host actions. |
| Custom globe | [Current creation guide](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) and local template route all touch events to `handleInputModeList(from:with:)`. Obadh's own globe invokes `advanceToNextInputMode()` on release. | Long press on iPad/Home-button layouts where Obadh supplies the globe. Face ID iPhone normally uses the system-owned globe, so this is not the iPhone height cause. |
| Appearance trait | The local template reads `textDocumentProxy.keyboardAppearance`. Obadh resolves colors from attached view traits instead. | Host explicitly requesting dark keyboard in a light app, and the reverse. Absence of a proxy read alone does not prove the attached traits are wrong. |
| Supplementary lexicon | `requestSupplementaryLexicon` can supply system text shortcuts and vocabulary. Shipping code uses Obadh's own engine instead. | Decide and test shortcut behavior separately. This is an optional capability, not missing initialization; the prior lexicon experiment did not repair height. |

No shipping change is justified solely by these source-level observations.

## Native appearance and typography

[UIInputView](https://developer.apple.com/documentation/uikit/uiinputview)
provides keyboard tint and blur when attached to a responder as an input or
accessory view. Its documentation does not promise that a nested instance acts
as a complete native keyboard skin. Obadh has a nested material view; the earlier
single-root experiment tested this concern and did not fix physical height or
captured native-layer overlap. Keep those results separate from the API contract.

[Liquid Glass adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
recommends system controls, limited custom backgrounds, and testing accessibility
settings. It does not require applying `UIGlassEffect` to every key. Shipping
Obadh uses the native keyboard material with translucent key fills; per-key glass
styles are diagnostic comparisons. Prior physical tests cover glass-setting
endpoints; Reduce Transparency, contrast, and motion handling are in source.

[UIFont.systemFont](https://developer.apple.com/documentation/uikit/uifont/systemfont(ofsize:weight:))
provides the supported system font. Obadh uses regular system fonts, with measured
modern portrait letter sizes of 25 points lowercase and 21.5 uppercase. These are
measurements, not Apple-published native-keyboard constants. Exact private font
identity and every device/orientation are not established by this audit.

## Current reports and release notes

The direct [17-point forum thread](https://developer.apple.com/forums/thread/843093)
still has two replies and no Apple-confirmed workaround. Larger reply counts in
search results belong to adjacent discussions. The
[switching overlay report](https://developer.apple.com/forums/thread/845726)
also has no verified remedy; it was already recorded in our earlier investigation.
The current [iOS 27 release notes](https://developer.apple.com/documentation/ios-ipados-release-notes/ios-ipados-27-release-notes)
do not list a matching extension-margin correction. Their SDK-gated UIKit trait
inheritance changes do not establish a fix for this separately reproduced case.

The maintainer's [YuanShu keyboard changelog](https://ihsiao.com/apps/hamster/v3/docs/logs/)
was also reviewed. It lists iOS 27 orientation detection, keyboard-notification
proxy-access crashes, and general iOS 27 corrections. It does not describe a
reproducible fix for this 17-point margin or our foreground insertion failure;
the broad release-note wording is insufficient to claim either has been solved.
