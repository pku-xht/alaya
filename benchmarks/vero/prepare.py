#!/usr/bin/env python3
"""Attach this image's pinned Lake packages to a rendered Vero workspace."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import sys


IMAGE_MANIFEST = Path("/opt/vero-image/lake-manifest.json")
IMAGE_PACKAGES = Path("/opt/vero-packages")
LOCK_FIELDS = ("type", "url", "rev", "subDir")


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def package_lock(package: dict) -> tuple[object, ...]:
    return tuple(package.get(field) for field in LOCK_FIELDS)


def packages_directory(workspace: Path, manifest: dict) -> Path:
    relative = PurePosixPath(manifest.get("packagesDir", ".lake/packages"))
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"unsafe packagesDir in lake-manifest.json: {relative}")
    return workspace.joinpath(*relative.parts)


def prepare(workspace: Path) -> int:
    workspace = workspace.resolve()
    manifest_path = workspace / "lake-manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"rendered workspace has no {manifest_path.name}: {workspace}")

    requested = read_json(manifest_path)
    image = read_json(IMAGE_MANIFEST)
    available = {package["name"]: package for package in image.get("packages", [])}
    package_dir = packages_directory(workspace, requested)
    package_dir.mkdir(parents=True, exist_ok=True)

    attached = 0
    for package in requested.get("packages", []):
        name = package["name"]
        cached = available.get(name)
        if cached is None or package_lock(cached) != package_lock(package):
            raise ValueError(
                f"Lake package {name!r} does not match this image's dependency cohort; "
                "build and select the image for this benchmark's locked versions"
            )
        source = IMAGE_PACKAGES / name
        if not source.is_dir():
            raise FileNotFoundError(f"image has no prefetched Lake package {name!r}")
        destination = package_dir / name
        if destination.is_symlink():
            if destination.readlink() == source:
                continue
            destination.unlink()
        elif os.path.lexists(destination):
            raise ValueError(
                f"{destination} is a real directory/file; render a fresh sandbox "
                "without host packages before preparing it"
            )
        destination.symlink_to(source, target_is_directory=True)
        attached += 1

    print(
        f"prepared {workspace}: attached {attached} of "
        f"{len(requested.get('packages', []))} locked Lake packages"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    try:
        return prepare(args.workspace)
    except Exception as exc:
        print(f"vero workspace preparation failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
