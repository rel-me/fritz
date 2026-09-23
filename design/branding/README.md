# Fritz identity

`FritzRaven.svg` is a hand-traced vector of the user-supplied bird reference, preserving its full silhouette, long tail, and angular cutouts. It contains editable paths on a transparent background. `FritzLogo.svg` and `FritzLogoDark.svg` pair the mark with the lowercase wordmark for light and dark backgrounds.

`app/Resources/AppIcon.icon` is the Icon Composer document used by Xcode, with separate white background and raven groups. Glass effects are disabled on the bird to preserve the flat reference artwork. Open it in Icon Composer to preview the system's masking and appearances. Keep the icon layers square and let the system mask the corners.

After editing `FritzRaven.svg` or `00-Background.svg`, run `python3 design/branding/export.py` from the repository root (requires `rsvg-convert` from librsvg). It generates `01-Raven.svg` with the icon's placement, copies both icon layers into the Icon Composer document, and exports the light/dark SVG logos and vector PDF chat marks. The wordmarks use Avenir Next with Avenir and sans-serif fallbacks.

Build with `make build` to compile the icon and appearance variants into the staged app. Icon Composer settings are preserved by the export script.
