#!/usr/bin/env python3
"""Build, verify and keep a local X-Touch One ZIP and DMG."""
import argparse
import json
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from workflow import APP, PRODUCTS, ROOT, bundle_app


def command(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def text(*args):
    return command(*args, capture_output=True, text=True).stdout.strip()


def verify_app(app, architecture=None):
    command("codesign", "--verify", "--strict", "--deep", app)
    prefix = ("arch", f"-{architecture}") if architecture else ()
    process = command(*prefix, app / "Contents/MacOS" / APP, "--startup-smoke", capture_output=True, text=True)
    if process.stdout.strip() != "X-Touch One startup OK":
        raise ValueError("The isolated application did not reach startup.")


def package(architecture):
    if sys.platform != "darwin":
        raise ValueError("Release packaging requires macOS.")
    architectures = ("arm64", "x86_64") if architecture == "universal" else (
        platform.machine() if architecture == "native" else architecture,
    )
    options = ["--scratch-path", f"build/package-swiftpm/{architecture}", "--configuration", "release"]
    for arch in architectures:
        options.extend(("--arch", arch))
    command("swift", "build", *options)
    binaries = Path(text("swift", "build", *options, "--show-bin-path"))
    revision = text("git", "rev-parse", "HEAD")
    dirty = bool(text("git", "status", "--porcelain"))
    name = f"XTouchOne-{revision[:12]}-{architecture}" + ("-dirty" if dirty else "")
    deliveries = ROOT / "build" / "deliveries"
    if (ROOT / "build").is_symlink() or deliveries.is_symlink():
        raise ValueError("Expected a real build/deliveries directory.")
    deliveries.mkdir(parents=True, exist_ok=True)
    final = deliveries / name
    if final.exists() or final.is_symlink():
        raise FileExistsError(f"Package already exists: {final}")

    sys.path.insert(0, str(ROOT / "build/dependencies/ControlSurfaceKit/tools"))
    from delivery_support import copy_files, hash_files, inventory

    with tempfile.TemporaryDirectory(prefix=".xtouch-one-", dir=deliveries) as temporary:
        stage = Path(temporary)
        product = stage / "X-Touch One"
        product.mkdir()
        app = bundle_app(binary=binaries / APP, app=product / f"{APP}.app")
        (product / "bin").mkdir()
        copy_files(binaries, product, [(p, f"bin/{p}") for p in PRODUCTS])
        copy_files(ROOT, product, [("LICENSE", "LICENSE"), ("README.md", "README.md")])
        for binary in [app / "Contents/MacOS" / APP, *(product / "bin" / p for p in PRODUCTS)]:
            if set(text("lipo", "-archs", binary).split()) != set(architectures):
                raise ValueError(f"Unexpected architecture slices in {binary}")
        for binary in (product / "bin").iterdir():
            command("codesign", "--force", "--sign", "-", binary, capture_output=True)
        can_run = platform.machine() in architectures
        startup_architectures = []
        if can_run:
            verify_app(app)
            startup_architectures.append(platform.machine())
            command(product / "bin/xtouch-one-surface", "--help", capture_output=True)
            image = stage / "startup.png"
            command(app / "Contents/MacOS" / APP, "--snapshot", image, "--tab", "parameters", "--sample",
                    capture_output=True)
            if not image.is_file():
                raise ValueError("The application did not render an isolated window.")
        if "x86_64" in architectures and platform.machine() == "arm64":
            rosetta = subprocess.run(["arch", "-x86_64", "/usr/bin/true"], capture_output=True)
            if rosetta.returncode == 0:
                verify_app(app, architecture="x86_64")
                startup_architectures.append("x86_64")

        build = {
            "revision": revision,
            "dirty": dirty,
            "architectures": list(architectures),
            "startup_architectures": startup_architectures,
            "toolchain": text("swift", "--version"),
            "dependencies": {
                name: json.loads((ROOT / "configs" / f"{name}.lock.json").read_text())["revision"]
                for name in ("control_surface_kit", "surface_plugins")
            },
            "files": inventory(product),
        }
        (product / "build.json").write_text(json.dumps(build, indent=2, sort_keys=True) + "\n")
        artifacts = stage / "artifacts"
        artifacts.mkdir()
        zip_path = artifacts / f"{name}.zip"
        dmg_path = artifacts / f"{name}.dmg"
        command("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", product, zip_path)
        command("hdiutil", "create", "-quiet", "-volname", "X-Touch One", "-srcfolder", product, "-format", "UDZO", dmg_path)
        command("hdiutil", "verify", "-quiet", dmg_path)
        extracted = stage / "extracted"
        command("ditto", "-x", "-k", zip_path, extracted)
        unpacked = extracted / product.name
        if inventory(unpacked) != inventory(product):
            raise ValueError("Extracted ZIP does not match the verified staging files.")
        if can_run:
            verify_app(unpacked / app.name)
        mounted = stage / "mounted"
        mounted.mkdir()
        command("hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-mountpoint", mounted, dmg_path)
        try:
            if hash_files(mounted, inventory(product)) != inventory(product):
                raise ValueError("Mounted DMG does not match the verified staging files.")
            if can_run:
                verify_app(mounted / app.name)
        finally:
            command("hdiutil", "detach", "-quiet", mounted)
        shutil.copy2(product / "build.json", artifacts / "build.json")
        hashes = hash_files(artifacts, [zip_path.name, dmg_path.name, "build.json"])
        (artifacts / "SHA256SUMS").write_text("".join(f"{digest}  {item}\n" for item, digest in hashes.items()))
        artifacts.rename(final)
    print(final.relative_to(ROOT))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", choices=("native", "arm64", "x86_64", "universal"), default="universal")
    arguments = parser.parse_args()
    package(arguments.architecture)
