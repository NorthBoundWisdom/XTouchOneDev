#!/usr/bin/env python3
"""Prepare or verify the locked ControlSurfaceKit build input."""

from functools import partial

from managed_git_dependency import DependencyLayout, ensure_dependency, main


LAYOUT = DependencyLayout(
    name="ControlSurfaceKit",
    lock_file="configs/control_surface_kit.lock.json",
    marker="control-surface-kit-manager.json",
    source_env="CONTROL_SURFACE_KIT_SOURCE",
    legacy_source_env="CONTROL_SURFACE_KIT_PATH",
)


if __name__ == "__main__":
    raise SystemExit(main(layout=LAYOUT, ensure=partial(ensure_dependency, layout=LAYOUT)))
