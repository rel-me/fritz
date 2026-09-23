#!/usr/bin/env python3
"""Export the raven source vectors. Requires librsvg's rsvg-convert."""

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


def artwork(filename):
    return list(ET.parse(HERE / filename).getroot())


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


for filename in ("00-Background.svg", "01-Raven.svg", "02-Details.svg"):
    shutil.copyfile(HERE / filename, ICON / filename)

# Keep the small logo to a silhouette and eye; the Dock icon has feather facets.
for suffix, color in (("", "#172D37"), ("Dark", "#F2E4CD")):
    body = artwork("01-Raven.svg")[0]
    body.set("fill", color)
    eye = artwork("02-Details.svg")[-1]
    mark = document(660, 580, "230 240 660 580", "Fritz raven")
    mark.extend((body, eye))
    save(mark, f"FritzMark{suffix}.svg")
    subprocess.run([
        "rsvg-convert", "-f", "pdf", str(HERE / f"FritzMark{suffix}.svg"),
        "-o", str(MARK / f"FritzMark{suffix}.pdf"),
    ], check=True)

    logo = document(720, 320, "0 0 720 320", "Fritz")
    group = ET.SubElement(logo, f"{{{SVG}}}g", {
        "transform": "translate(-65 -22) scale(.34)",
    })
    group.extend((body, eye))
    ET.SubElement(logo, f"{{{SVG}}}text", {
        "x": "270", "y": "235", "fill": color,
        "font-family": "Avenir Next, Avenir, sans-serif",
        "font-size": "208", "font-weight": "700",
    }).text = "fritz"
    save(logo, f"FritzLogo{suffix}.svg")
