# Keyboard appearance

The iOS Appearance feature uses native SwiftUI navigation, materials and sheets.
System is the untouched original keyboard: the optional palette is nil, the
artwork is hidden, and its existing material, geometry and key colors remain in
use. Automatic continues to follow the host's keyboard appearance hint. Light,
Dark and key outlines are explicit user choices.

## Shared reference catalog

`android-catalog.json` contains the 71 Android theme identifiers, names and numeric
palette/gradient samples, pinned to its source revision and SHA256. Platform
renderers remain separate. The generated Swift catalog contains no Android UI
implementation. Regenerate after a deliberate catalog change:

The theme names are written in the Android source catalog and imported verbatim
to iOS. All 71 have distinct, palette-specific names. Persistent theme IDs and
groups remain stable, so renaming does not change saved selections or artwork.
The iOS detail sheet displays the full name above its preview, even when it
would be too long for the navigation bar.

```sh
python3 Tools/Themes/import_android_catalog.py --android ../obadh-android
python3 Tools/Themes/import_android_catalog.py --check
```

Linear gradients retain their explicit vertical stops. Five 17×17 color grids
use bilinear layer filtering, with the outer sample centers at the view edges.
Custom keyboard keys use `UIGlassEffect(.regular)` within the existing native
`UIGlassContainerEffect`, on iOS 26+. Earlier systems use opaque keys. Reduce
Transparency or Increase Contrast also uses opaque keys; Reduce Motion retains
its existing press behavior. Contrast calculations cover the backdrop, key ink
and action key. Palette tints and a protective scrim support readable suggestion
text, rather than trusting arbitrary photo brightness. Emoji panel artwork is
hidden so its existing native surfaces remain readable.

A selection is one versioned JSON preference snapshot with a revision UUID.
The extension reads it on presentation and Darwin notifications, never per
keystroke. Appearance changes update visuals without clearing composition; System keys and
background-only updates avoid unnecessary row rebuilds. Production notification
subscriptions are weak and cancelled with their controller.
Each view owns its palette; previews cannot change the running keyboard's colors.
The gallery separates the System and photo actions from a searchable, segmented
catalog. It initially opens the collection containing the active preset and
leads each collection with a short, intentionally varied palette selection. Cards
use the production backdrop, palette and key geometry at the same 414:280 aspect
ratio; one Core Graphics pass draws the legends and key silhouettes. These are
lightweight illustrations of the final keyboard, while the detail sheet alone
creates live native glass keys. Scrolling never instantiates a full keyboard per
card, waits for glass compositing, or captures/cache-clones view hierarchies.
Photo thumbnail decoding remains bounded and off the main actor. No thumbnail
or full preview loads the typing engine. The app
preview uses a semantic gray underlay because host-owned keyboard chrome is only
available in the actual keyboard; the extension keeps that native chrome.

## Photos and permission

Only **Create from a Photo** opens Apple's Photos picker. There is no broad Photos
permission request, permission probe, asset enumeration, upload or network code
in this feature. The system picker handles access restrictions and explicitly
shares the selected item. Editing a saved theme uses Obadh's local copy.
Keyboard Full Access is not required for read-only shared theme files.
The app's privacy manifest declares file metadata reasons C617.1 for its own
containers and 3B52.1 for size checks on the explicitly selected picker file.

A file-based Transferable downscales the selected image before retaining bytes:
100 MB compressed / 100 megapixel source limits; 2048-pixel source, 1280-pixel
render and 240-pixel thumbnail. EXIF orientation is applied and JPEG reencoding
removes source EXIF/GPS metadata; the encoder may add color-space and pixel
dimension tags. The editor offers direct drag/pinch framing, a compact frame
options menu and VoiceOver actions for gesture-free adjustment, reset,
brightness, naming and a real keyboard preview. The
photo/keyboard switch keeps one preview visible above a scrolling adjustment
panel; it collapses while the user names the theme so the text field stays
usable above the keyboard. Crop and brightness
changes update the on-screen Core Animation layer immediately; there is no
debounce, repeated image encoding or native-key relayout while dragging. Final full-resolution JPEG
rendering happens off the main actor at save time. Import cancellation cancels
Photos' Progress, and generation checks reject
late results. iCloud, invalid format, failed decode and save errors leave the
active selection intact.

`ThemePhotoLibrary` is the containing app's sole writer actor.
`KeyboardPhotoThemeStore` writes immutable revision images before atomically
publishing `catalog.json` under the shared `KeyboardThemes` directory. Invalid or
unreadable manifests fail closed for mutations and cleanup. Edits retain the
bounded original. Failed publication removes only newly created files. Deletion
requires the native confirmation dialog, preserves the Photos asset, publishes
removal before changing an active selection to System, and releases the local source
and all revisions of that photo. Unreferenced revisions are reclaimed after one day to protect
concurrent keyboard reads. Files use protection until first authentication.
The extension looks up only the selected record and reads its bounded render
off the typing thread, rejects stale loads, retries failed reads on presentation,
falls back to System for unavailable artwork and sheds images when inactive.

## Validation

Run `swift test` for catalog, contrast, crop, preference and atomic-store tests.
`ObadhKeyboardLifecycleTests` covers the unchanged System renderer, real glass,
opaque accessibility fallback, artwork release and live changes during typing.
`ObadhVoiceTests/ThemePhotoProcessingTests` checks bounded JPEG processing and
metadata removal (the app-hosted test target also owns these app-only utilities).
`ObadhVoiceTests/ThemeThumbnailTests` checks edited photo revisions, that cards
allocate no live glass keys, and immediate crop/brightness updates in the editor.
`ObadhKeyboardUITests/KeyboardAppearanceUITests` exercises preview/cancel/apply,
persistence, restoring System, native picker cancellation and photo editing.
Its thumbnail fidelity flow captures solid, gradient and mesh cards beside
their full previews for visual review.
Simulator photo tests require ad-hoc signing (`CODE_SIGNING_ALLOWED=YES
CODE_SIGN_IDENTITY=-`) so the app and extension receive their real App Group
entitlements; an unsigned simulator build deliberately cannot save shared themes.
The photo test expects at least one photo in its dedicated simulator; use
`xcrun simctl addmedia DEVICE_ID /path/to/a/synthetic-fixture.jpg`.

Simulator results do not qualify iPhone 11/A13 glass performance or physical
keyboard memory pressure. Keep those hardware acceptance checks separate from
functional and installation evidence in the changelog.
