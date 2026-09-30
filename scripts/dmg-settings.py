"""Finder layout for the signed Fritz installer; loaded by dmgbuild."""

from pathlib import Path
import subprocess

format = "UDZO"
filesystem = "HFS+"
files = ["dist/Fritz.app"]
symlinks = {"Applications": "/Applications"}
background = "resources/dmg/background.tiff"
window_rect = ((160, 160), (640, 442))
icon_size = 128
text_size = 14
icon_locations = {"Fritz.app": (160, 242), "Applications": (480, 242)}
show_icon_preview = True


def create_hook(mount_point, _options):
    # FinderInfo changes on a signed app (including hiding its extension) break
    # strict signature verification. Verify the copied bundle before compression.
    subprocess.run(["codesign", "--verify", "--deep", "--strict",
                    str(Path(mount_point) / "Fritz.app")], check=True)
