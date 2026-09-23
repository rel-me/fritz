# Fritz identity

Fritz's mark is a raven in profile: a charcoal silhouette, a heavy beak, and one amber eye. The Dock icon adds slate feather facets on a warm cream tile. `FritzLogo.svg` and `FritzLogoDark.svg` pair the simplified raven with the lowercase wordmark for light and dark backgrounds.

The three numbered SVGs are the editable vector source: background, raven silhouette, and details. `app/Resources/AppIcon.icon` is the Icon Composer document used by Xcode, with separate background and raven groups. Open it in Icon Composer to preview the system's masking, lighting, and appearances. Keep the source layers square and let the system mask the corners.

After editing the numbered vectors, run `python3 design/branding/export.py` from the repository root (requires `rsvg-convert` from librsvg). It copies the source layers into the Icon Composer document and exports the light/dark SVG logos and vector PDF chat marks. The wordmarks use Avenir Next with Avenir and sans-serif fallbacks. The small chat mark omits the feather facets to keep its silhouette clear.

Build with `make build` to compile the icon and appearance variants into the staged app. Icon Composer settings are preserved by the export script.
