#!/usr/bin/env python3
"""Export the supplied raven trace. Requires librsvg and macOS iconutil."""

from pathlib import Path
import shutil
import subprocess
from tempfile import TemporaryDirectory
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICON = ROOT / "app/Resources/AppIcon.icns"
WEBSITE = ROOT / "website/public"
SVG = "http://www.w3.org/2000/svg"
ET.register_namespace("", SVG)


def artwork(color="#231F20"):
    group = ET.parse(HERE / "FritzRaven.svg").getroot().find(f"{{{SVG}}}g")
    group.set("fill", color)
    return group


def document(width, height, view_box, title):
    root = ET.Element(f"{{{SVG}}}svg", {
        "width": str(width), "height": str(height), "viewBox": view_box,
        "role": "img", "aria-labelledby": "title",
    })
    ET.SubElement(root, f"{{{SVG}}}title", {"id": "title"}).text = title
    return root


def save(root, filename):
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(HERE / filename, encoding="unicode")
    with (HERE / filename).open("a") as output:
        output.write("\n")


def render_png(root, path, width, height):
    subprocess.run([
        "rsvg-convert", "-f", "png", "-w", str(width), "-h", str(height), "-o", str(path),
    ], input=ET.tostring(root), check=True)


def text(parent, content, x, y, size, color, weight):
    ET.SubElement(parent, f"{{{SVG}}}text", {
        "x": str(x), "y": str(y), "fill": color,
        "font-family": "Avenir Next, Avenir, sans-serif",
        "font-size": str(size), "font-weight": weight,
    }).text = content


icon = document(1024, 1024, "0 0 1024 1024", "Fritz raven app icon")
placement = ET.SubElement(icon, f"{{{SVG}}}g", {
    "transform": "translate(108 189) scale(.47)",
})
placement.append(artwork())
with TemporaryDirectory() as temporary:
    iconset = Path(temporary) / "AppIcon.iconset"
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        render_png(icon, iconset / f"icon_{size}x{size}.png", size, size)
        render_png(icon, iconset / f"icon_{size}x{size}@2x.png", size * 2, size * 2)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICON)], check=True)

for suffix, color in (("", "#231F20"), ("Dark", "#FFFFFF")):
    mark = document(1718, 1376, "0 0 1718 1376", "Fritz raven")
    mark.append(artwork(color))
    save(mark, f"FritzMark{suffix}.svg")

    logo = document(760, 320, "0 0 760 320", "Fritz")
    group = ET.SubElement(logo, f"{{{SVG}}}g", {
        "transform": "translate(26 49) scale(.16)",
    })
    group.append(artwork(color))
    text(logo, "fritz", 324, 235, 208, color, "700")
    save(logo, f"FritzLogo{suffix}.svg")

# The home page colors raven.svg through a CSS mask; the favicon follows the browser appearance.
shutil.copyfile(HERE / "FritzMark.svg", WEBSITE / "raven.svg")

favicon = document(1718, 1718, "0 -171 1718 1718", "Fritz")
ET.SubElement(favicon, f"{{{SVG}}}style").text = (
    "g{fill:#231F20}@media (prefers-color-scheme:dark){g{fill:#FFFFFF}}"
)
favicon.append(artwork())
save(favicon, WEBSITE / "favicon.svg")

render_png(icon, WEBSITE / "apple-touch-icon.png", 180, 180)

card = document(1200, 630, "0 0 1200 630", "Fritz")
ET.SubElement(card, f"{{{SVG}}}rect", {"width": "1200", "height": "630", "fill": "#F3EFE7"})
ET.SubElement(card, f"{{{SVG}}}g", {
    "transform": "translate(520 70) scale(.4)",
}).append(artwork())
text(card, "fritz", 72, 250, 168, "#231F20", "700")
for line, y in (("A personal assistant", 350), ("for Mac.", 404)):
    text(card, line, 80, y, 44, "#231F20", "500")
render_png(card, WEBSITE / "social.png", 1200, 630)
