#!/usr/bin/env python3
"""Generate an isolated simulator project with a minimal 180pt keyboard.

Uses the normal DEBUG host and UI test, but none of Obadh's keyboard sources.
Outputs build/MarginProbe/project.yml. Requires PyYAML and xcodegen. The normal
project is untouched. Installing this on a dedicated simulator temporarily
replaces its Obadh keyboard; reinstall the normal build after the experiment.
"""
import json
from pathlib import Path
import subprocess
import yaml

root = Path(__file__).resolve().parents[2]
spec = yaml.safe_load((root / "project.yml").read_text())
spec["name"] = "ObadhMarginProbe"
names = ["Obadh", "ObadhKeyboard", "ObadhKeyboardUITests"]
spec["targets"] = {name: spec["targets"][name] for name in names}
spec["schemes"] = {"ObadhKeyboardUITests": spec["schemes"]["ObadhKeyboardUITests"]}
keyboard = spec["targets"]["ObadhKeyboard"]
keyboard["sources"] = [{"path": "Tests/KeyboardMarginProbe/MinimalKeyboardViewController.swift"}]
keyboard["dependencies"] = []

# Resolve all paths against the repository, not the generated project directory.
def absolute_paths(node):
    if isinstance(node, list):
        return [absolute_paths(x) for x in node]
    if isinstance(node, dict):
        result = {}
        for key, value in node.items():
            if key in ("path", "framework", "INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS") and isinstance(value, str):
                result[key] = str(root / value)
            elif key == "configFiles":
                result[key] = {config: str(root / path) for config, path in value.items()}
            else:
                result[key] = absolute_paths(value)
        return result
    return node

out = root / "build/MarginProbe"
out.mkdir(parents=True, exist_ok=True)
(out / "project.yml").write_text(json.dumps(absolute_paths(spec), indent=2))
subprocess.run(["xcodegen", "generate", "--spec", str(out / "project.yml"), "--project", str(out)], check=True)
print(out / "ObadhMarginProbe.xcodeproj")
