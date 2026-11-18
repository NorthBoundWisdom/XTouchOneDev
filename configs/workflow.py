#!/usr/bin/env python3
"""Build, test and run through SwiftPM with the repository's scratch directory."""

import argparse
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ["--scratch-path", "build/swiftpm"]
PRODUCTS = ("xtouch-one-monitor", "xtouch-one-review")
APP = "XTouchOneApp"
BUNDLE_ID = "com.northboundwisdom.xtouchone"


def swift(*arguments: str, environment: dict[str, str] | None = None) -> int:
    return subprocess.run(["swift", *arguments], cwd=ROOT, env=environment).returncode


def bundle_app() -> Path:
    """Wrap the debug executable in an ad-hoc signed .app so macOS treats it as a regular application."""
    binary = Path(subprocess.run(["swift", "build", *SCRATCH, "--show-bin-path"], cwd=ROOT, check=True,
                                 capture_output=True, text=True).stdout.strip()) / APP
    app = ROOT / "build" / "app" / f"{APP}.app"
    if app.is_symlink() or (ROOT / "build").is_symlink() or (ROOT / "build" / "app").is_symlink():
        raise ValueError("Refusing a symlinked build path.")
    shutil.rmtree(app, ignore_errors=True)
    (app / "Contents" / "MacOS").mkdir(parents=True)
    shutil.copy2(binary, app / "Contents" / "MacOS" / APP)
    with open(app / "Contents" / "Info.plist", "wb") as handle:
        plistlib.dump({
            "CFBundleName": "X-Touch One", "CFBundleExecutable": APP, "CFBundleIdentifier": BUNDLE_ID,
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
        }, handle)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, capture_output=True)
    return app


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    build = actions.add_parser("build")
    build.add_argument("--configuration", choices=("debug", "release"), default="debug")
    test = actions.add_parser("test")
    test.add_argument("--coremidi-loopback", action="store_true",
                      help="Also run the loopback test over virtual endpoints the test creates.")
    run = actions.add_parser("run")
    run.add_argument("--usage", action="store_true", help="Print the command's usage text and succeed.")
    run.add_argument("product", choices=PRODUCTS)
    run.add_argument("arguments", nargs=argparse.REMAINDER)
    app = actions.add_parser("app", help="Build, bundle and run the panel app; Ctrl+C stops it.")
    app.add_argument("--bundle-only", action="store_true")
    app.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    if args.action == "app":
        if sys.platform != "darwin":
            print("The panel app runs on macOS only.", file=sys.stderr)
            return 2
        status = swift("build", *SCRATCH, "--product", APP)
        if status:
            return status
        bundle = bundle_app()
        print(f"Bundled {bundle.relative_to(ROOT)}")
        if args.bundle_only:
            return 0
        return subprocess.run([str(bundle / "Contents" / "MacOS" / APP), *args.arguments], cwd=ROOT).returncode

    if args.action == "build":
        return swift("build", *SCRATCH, "--configuration", args.configuration)
    if args.action == "test":
        environment = dict(os.environ)
        if args.coremidi_loopback:
            environment["XTOUCH_ONE_COREMIDI_TESTS"] = "1"
        else:
            environment.pop("XTOUCH_ONE_COREMIDI_TESTS", None)
        return swift("test", *SCRATCH, environment=environment)
    status = swift("run", *SCRATCH, args.product, *args.arguments)
    # Both commands print their usage and exit 2 when called without arguments.
    return 0 if args.usage and status == 2 else status


if __name__ == "__main__":
    sys.exit(main())
