#!/usr/bin/env bash
# Rasterises Resources/herda-mark.svg into the Icon Composer layer asset.
#
# The mark is a negative-space silhouette: the eye and the gaps between the
# mane arcs are holes, so it only reads against a ground. The ground is the
# gradient in icon.json; the mark's own colour is in the SVG. Neither belongs
# in this script.
#
# The placement is not centred, and that is the whole point. The mark's mane
# arcs and chest are cut flat against the edges of its own viewBox — it is a
# corner composition meant to bleed. Inset it and those flat cuts hang in the
# middle of the icon looking severed. So the mark runs off the bottom-left and
# lets the squircle absorb the cuts, while the key head is pulled clear of the
# top-right corner, which is the one part that must not be clipped.
#
# Both numbers were swept against a 231pt-radius squircle (macOS 26 clips every
# icon to that shape) rather than eyeballed. Centring at any scale clips the key:
# fit=1020 centred loses 690px of it, fit=1060 loses 2562px. Shifting by 70 with
# fit=1060 is the largest mark that clips none of the key at all — 441k mark
# pixels, with 1651px running off the bottom-left, which is the bleed we want.
# The visible mark then lands at exactly 950x972+0+52 on the 1024pt canvas: 74pt
# of clearance to the right of the muzzle, and nothing to spare above the key.
#
# Changing the mark artwork invalidates every number above. Re-sweep, do not
# assume the new silhouette has its mass in the same corner.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

if ! command -v resvg >/dev/null; then
  echo "resvg not found (brew install resvg)" >&2
  exit 1
fi
if ! command -v magick >/dev/null; then
  echo "magick not found (brew install imagemagick)" >&2
  exit 1
fi

out=Resources/Herda.icon/Assets/mark.png
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Height only: let resvg derive the width so the aspect ratio survives. Resizing
# a square pre-render to fit is off by a fraction of a percent, which is enough
# to move the key into the corner the sweep just cleared.
resvg --height 1060 Resources/herda-mark.svg "$tmp/mark.png"
magick -size 1024x1024 xc:none "$tmp/mark.png" -gravity center -geometry -70+70 -composite "$out"

bbox=$(magick "$out" -format "%@" info:)
if [ "$bbox" != "950x972+0+52" ]; then
  echo "placement drifted: got $bbox, expected 950x972+0+52" >&2
  exit 1
fi
echo "wrote $out ($bbox)"
