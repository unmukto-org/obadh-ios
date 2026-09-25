#!/usr/bin/env python3
"""Generate a portable, public-API keyboard reproduction with a separate identity.

No signing identity, user data, private API probes or Obadh engine is packaged.
Use DEVELOPMENT_TEAM=<your team> when building for a device.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / "build/KeyboardMarginFeedback"
out.mkdir(parents=True, exist_ok=True)
for source, name in [
    ("Tests/KeyboardMarginProbe/DeviceHost/HostApp.swift", "HostApp.swift"),
    ("Tests/KeyboardMarginProbe/Standalone/KeyboardViewController.swift", "KeyboardViewController.swift"),
    ("Tests/KeyboardMarginProbe/Standalone/ReproTests.swift", "ReproTests.swift"),
]:
    shutil.copy2(root / source, out / name)

info = {"CFBundleDisplayName": "Margin Repro", "NSExtension": {
    "NSExtensionPointIdentifier": "com.apple.keyboard-service",
    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).KeyboardViewController",
    "NSExtensionAttributes": {"PrimaryLanguage": "en-US", "IsASCIICapable": True,
                              "PrefersRightToLeft": False, "RequestsOpenAccess": False}}}
(out / "KeyboardInfo.plist").write_bytes(plistlib.dumps(info))
base = {"SWIFT_VERSION": "5.0", "CODE_SIGN_STYLE": "Automatic",
        "GENERATE_INFOPLIST_FILE": "YES", "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.0"}
spec = {
    "name": "KeyboardMarginRepro",
    "options": {"deploymentTarget": {"iOS": "18.0"}},
    "settings": {"base": base},
    "targets": {
        "MarginRepro": {"type": "application", "platform": "iOS",
            "sources": ["HostApp.swift"],
            "dependencies": [{"target": "MarginKeyboard", "embed": True}],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "org.unmukto.obadh.marginrepro",
                "INFOPLIST_KEY_CFBundleDisplayName": "Margin Repro",
                "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
                "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES"}}},
        "MarginKeyboard": {"type": "app-extension", "platform": "iOS",
            "sources": ["KeyboardViewController.swift"],
            "settings": {"base": {
                "PRODUCT_BUNDLE_IDENTIFIER": "org.unmukto.obadh.marginrepro.keyboard",
                "INFOPLIST_FILE": "KeyboardInfo.plist",
                "APPLICATION_EXTENSION_API_ONLY": "YES"}}},
        "MarginReproTests": {"type": "bundle.ui-testing", "platform": "iOS",
            "sources": ["ReproTests.swift"], "dependencies": [{"target": "MarginRepro"}],
            "settings": {"base": {"TEST_TARGET_NAME": "MarginRepro",
                "PRODUCT_BUNDLE_IDENTIFIER": "org.unmukto.obadh.marginrepro.tests"}}}},
    "schemes": {"MarginRepro": {
        "build": {"targets": {"MarginRepro": "all", "MarginReproTests": "test"}},
        "test": {"targets": ["MarginReproTests"]}}}}
(out / "project.yml").write_text(json.dumps(spec, indent=2))
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml"), "--project", str(out)], check=True)
(out / "README.md").write_text("""# Keyboard container height reproduction

Uses only public UIKit APIs. No app groups, Full Access, engine, network or private
runtime probes. This app has a separate identity and does not replace Obadh.

1. Open KeyboardMarginRepro.xcodeproj. Select your development team for all targets
   (and change bundle identifiers if your team requires it; update the application
   identifier in ReproTests.swift to match).
2. Run MarginRepro on an iPhone. Enable **Margin Repro** in Settings → General →
   Keyboard → Keyboards → Add New Keyboard. Full Access is not needed.
   Ensure the native English (US) and Emoji keyboards are also enabled.
3. In the test editor, select English (US) then Margin Repro using the globe menu.
   Record the host height label and the extension's actual content-height label.
4. Select Emoji then Margin Repro. Compare the host height; content stays 180.
5. Press Home and return. Compare again without changing the editor.

The white border encloses the extension's 180-point pink view. Any extra area
outside it belongs to the system container. The editor owns a 44-point toolbar.

For UI automation, run testEnableKeyboard once, then testHeightIsStable. The latter
has an ordinary failing assertion when total height changes; it also verifies
content height and preserves test text through switching. testInputWorks separately
checks that a real tap reaches the button and then inserts text into the host.
Only the local seeded editor is used. Device runs should include
`-collect-test-diagnostics never`. The generated project requires no XcodeGen
installation to open; project.yml is included for regenerating it if desired.

See Findings.md for independently measured results and their limits.
""")
shutil.copy2(root / "docs/keyboard-margin-feedback-draft.md", out / "Findings.md")
archive = shutil.make_archive(str(root / "build/KeyboardMarginFeedback"), "zip", root_dir=out)
print(archive)
