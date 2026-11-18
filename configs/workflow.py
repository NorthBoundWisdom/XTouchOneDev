#!/usr/bin/env python3
"""Build, test and run through SwiftPM with the repository's scratch directory."""

import argparse
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRATCH = ["--scratch-path", "build/swiftpm"]
PRODUCTS = ("xtouch-one-monitor", "xtouch-one-review")


def swift(*arguments: str, environment: dict[str, str] | None = None) -> int:
    return subprocess.run(["swift", *arguments], cwd=ROOT, env=environment).returncode


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
    args = parser.parse_args()

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
