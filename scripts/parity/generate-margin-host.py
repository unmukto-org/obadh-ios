#!/usr/bin/env python3
"""Generate an independent host to test the installed Obadh keyboard on a device.

No keyboard extension or app-group entitlements are included. The test app owns
its editor and can call reloadInputViews; this is not an extension-side fix.
"""
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / "build/MarginHost"
out.mkdir(parents=True, exist_ok=True)
settings = {"CODE_SIGN_STYLE": "Automatic", "SWIFT_VERSION": "5.0",
            "GENERATE_INFOPLIST_FILE": "YES"}
signing = {"Debug": str(root / "Config/Signing.local.xcconfig"),
           "Release": str(root / "Config/Signing.local.xcconfig")}
spec = {
    "name": "ObadhMarginHost",
    "options": {"deploymentTarget": {"iOS": "18.0"}},
    "targets": {
        "MarginHost": {
            "type": "application", "platform": "iOS",
            "sources": [{"path": str(root / "Tests/KeyboardMarginProbe/DeviceHost/HostApp.swift")}],
            "configFiles": signing,
            "settings": {"base": dict(settings,
                PRODUCT_BUNDLE_IDENTIFIER="org.unmukto.obadh.marginhostprobe",
                INFOPLIST_KEY_UILaunchScreen_Generation="YES",
                INFOPLIST_KEY_UIApplicationSceneManifest_Generation="YES")}},
        "MarginHostTests": {
            "type": "bundle.ui-testing", "platform": "iOS",
            "sources": [{"path": str(root / "Tests/KeyboardMarginProbe/DeviceHost/HostTests.swift")}],
            "configFiles": signing,
            "dependencies": [{"target": "MarginHost"}],
            "settings": {"base": dict(settings,
                PRODUCT_BUNDLE_IDENTIFIER="org.unmukto.obadh.marginhosttests",
                TEST_TARGET_NAME="MarginHost")}}
    },
    "schemes": {"MarginHostTests": {
        "build": {"targets": {"MarginHost": "all", "MarginHostTests": "all"}},
        "test": {"targets": ["MarginHostTests"]}}}
}
(out / "project.yml").write_text(json.dumps(spec, indent=2))
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml"),
                "--project", str(out)], check=True)
