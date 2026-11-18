#!/usr/bin/env python3
"""FreeCM adapter: local setup and explicit cleanup. Dependency acquisition uses Git."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

import setup_local_project

ROOT = Path(__file__).resolve().parents[1]
# The managed dependency checkouts under build/dependencies are never removed here.
CLEAN_TARGETS = ("configured.json", "swiftpm", "app")


def clean_build(dry_run: bool) -> None:
    build = ROOT / "build"
    if build.is_symlink() or (build.exists() and not build.is_dir()):
        raise ValueError("Refusing to clean a symlinked or non-directory build path.")
    for name in CLEAN_TARGETS:
        path = build / name
        if not path.exists() and not path.is_symlink():
            continue
        print(f"{'Would remove' if dry_run else 'Removing'} build/{name}")
        if dry_run:
            continue
        if path.is_symlink() or path.is_file():
            path.unlink()
        else:
            shutil.rmtree(path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--init", action="store_true", help="Compatibility with older FreeCM versions.")
    action.add_argument("--initlock", action="store_true")
    action.add_argument("--initrepo", action="store_true")
    action.add_argument("--update", action="store_true")
    action.add_argument("--cleanbuild", action="store_true")
    parser.add_argument("--quiet", action="store_true", help="Accepted for plugin invocations.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.dry_run and not args.cleanbuild:
        parser.error("--dry-run requires --cleanbuild")
    if args.cleanbuild:
        clean_build(args.dry_run)
        return 0
    if args.initlock:
        print("Revisions are pinned in configs/control_surface_kit.lock.json and configs/surface_plugins.lock.json.")
        return 0
    return setup_local_project.main()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
