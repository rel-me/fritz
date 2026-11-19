# Fritz identity

`FritzRaven.svg` is a hand-traced vector of the user-supplied bird reference, preserving its full silhouette, long tail, and angular cutouts. It contains editable paths on a transparent background. `FritzLogo.svg` and `FritzLogoDark.svg` pair the mark with the lowercase wordmark for light and dark backgrounds.

`app/Resources/FritzRaven.icns` is the macOS bundle icon. Each size contains a white raven with a thin charcoal outline on a transparent canvas. The outline keeps the silhouette visible over light backgrounds. On macOS 26 and later, Fritz also sets its running app icon from this file. System-owned views can still apply a background or styling when displaying the bundle icon.

After editing `FritzRaven.svg`, run `python3 design/branding/export.py` from the repository root on macOS with librsvg installed. The script builds the ICNS with `iconutil`, exports the light and dark SVG logos and marks, and writes the home page's raven mask, adaptive favicon, transparent touch icon, and social card to `website/public/`. The wordmarks use Avenir Next with Avenir and sans-serif fallbacks.

Build with `make build` to include the exported ICNS in the staged app.
