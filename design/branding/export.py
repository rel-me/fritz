#!/usr/bin/env python3
"""Export the supplied raven trace. Requires librsvg's rsvg-convert."""

from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
ICON = ROOT / "app/Resources/AppIcon.icon/Assets"
MARK = ROOT / "app/Resources/Assets.xcassets/FritzMark.imageset"
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


icon = document(1024, 1024, "0 0 1024 1024", "Fritz raven app icon")
placement = ET.SubElement(icon, f"{{{SVG}}}g", {
    "transform": "translate(108 189) scale(.47)",
})
placement.append(artwork())
save(icon, "01-Raven.svg")

for filename in ("00-Background.svg", "01-Raven.svg"):
    shutil.copyfile(HERE / filename, ICON / filename)

for suffix, color in (("", "#231F20"), ("Dark", "#FFFFFF")):
    mark = document(1718, 1376, "0 0 1718 1376", "Fritz raven")
    mark.append(artwork(color))
    save(mark, f"FritzMark{suffix}.svg")
    subprocess.run([
        "rsvg-convert", "-f", "pdf", str(HERE / f"FritzMark{suffix}.svg"),
        "-o", str(MARK / f"FritzMark{suffix}.pdf"),
    ], check=True)

    logo = document(760, 320, "0 0 760 320", "Fritz")
    group = ET.SubElement(logo, f"{{{SVG}}}g", {
        "transform": "translate(26 49) scale(.16)",
    })
    group.append(artwork(color))
    ET.SubElement(logo, f"{{{SVG}}}text", {
        "x": "324", "y": "235", "fill": color,
        "font-family": "Avenir Next, Avenir, sans-serif",
        "font-size": "208", "font-weight": "700",
    }).text = "fritz"
    save(logo, f"FritzLogo{suffix}.svg")
