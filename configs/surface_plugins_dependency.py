#!/usr/bin/env python3
"""Prepare or verify the locked SurfacePlugins build input."""

from functools import partial

from managed_git_dependency import DependencyLayout, ensure_dependency, main


LAYOUT = DependencyLayout(
    name="SurfacePlugins",
    lock_file="configs/surface_plugins.lock.json",
    marker="surface-plugins-manager.json",
    source_env="SURFACE_PLUGINS_SOURCE",
    legacy_source_env="SURFACE_PLUGINS_PATH",
)


if __name__ == "__main__":
    raise SystemExit(main(layout=LAYOUT, ensure=partial(ensure_dependency, layout=LAYOUT)))
