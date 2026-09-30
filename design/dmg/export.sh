#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
temporary="$(mktemp -d "${TMPDIR:-/tmp}/fritz-dmg-art.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
mkdir -p resources/dmg
python3 - <<'PY'
import xml.etree.ElementTree as ET

svg = 'http://www.w3.org/2000/svg'
ET.register_namespace('', svg)
background = ET.parse('design/dmg/Background.svg')
branding = background.getroot().find(f'{{{svg}}}g[@id="branding"]')
for child in list(branding):
    branding.remove(child)
for child in ET.parse('design/branding/FritzLogo.svg').getroot():
    if child.tag != f'{{{svg}}}title':
        branding.append(child)
ET.indent(background, space='  ')
background.write('design/dmg/Background.svg', encoding='unicode')
PY
rsvg-convert -w 640 -h 420 design/dmg/Background.svg -o "$temporary/background.png"
rsvg-convert -w 1280 -h 840 design/dmg/Background.svg -o "$temporary/background@2x.png"
sips -s dpiWidth 144 -s dpiHeight 144 "$temporary/background@2x.png" >/dev/null
tiffutil -cathidpicheck "$temporary/background.png" "$temporary/background@2x.png" \
  -out resources/dmg/background.tiff
