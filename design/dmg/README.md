# Disk image artwork

`Background.svg` uses the Fritz wordmark and cream palette for the installer.
Run `bash design/dmg/export.sh` after editing it or the branding logo. It uses
the same `rsvg-convert` dependency as the branding exporter and macOS's `sips`
and `tiffutil` to write `resources/dmg/background.tiff`. The checked-in TIFF has
640 × 420 and 1280 × 840 representations for standard and Retina displays;
archive creation does not need the artwork tools.

The Finder layout in `scripts/dmg-settings.py` places 128-point
Fritz and Applications icons at (160, 242) and (480, 242), over the two tiles.
Keep its window bounds, icon positions, and the background coordinated.
