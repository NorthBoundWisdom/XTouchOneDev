#!/usr/bin/env python3
"""Acquire the locked dependencies, then validate the FreeCM commands and the Swift package."""

import json
import subprocess
import sys
from pathlib import Path

import control_surface_kit_dependency
import surface_plugins_dependency
import validate_repo_commands
from managed_git_dependency import ensure_dependency

ROOT = Path(__file__).resolve().parents[1]
MARKER = ROOT / "build" / "configured.json"


def main() -> int:
    # A failed reconfiguration must not leave an earlier success marker behind.
    MARKER.unlink(missing_ok=True)
    if validate_repo_commands.main():
        return 1
    revisions = {}
    for module in (control_surface_kit_dependency, surface_plugins_dependency):
        ensure_dependency(ROOT, layout=module.LAYOUT)
        lock = json.loads((ROOT / module.LAYOUT.lock_file).read_text())
        revisions[module.LAYOUT.name] = lock["revision"]
    subprocess.run(["swift", "package", "--scratch-path", "build/swiftpm", "dump-package"],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    MARKER.parent.mkdir(parents=True, exist_ok=True)
    MARKER.write_text(json.dumps({"schema_version": 1, "dependencies": revisions}, indent=2) + "\n")
    print("XTouchOneDev local configuration is ready.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
