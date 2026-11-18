#!/usr/bin/env python3
"""Validate configs/freecm.commands.jsonc with the repository-local helpers."""

import sys
from pathlib import Path

from _vendor.freecm.errors import RepoCommandManifestError
from _vendor.freecm.repo_commands import validate_repo_command_manifest

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    try:
        summary = validate_repo_command_manifest(ROOT)
    except RepoCommandManifestError as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Validated {summary.manifest_path} ({summary.configuration_count} Configs, {summary.variant_count} variants)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
