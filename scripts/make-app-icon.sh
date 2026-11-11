#!/bin/sh
# Rebuilds the app icon from content/branding/logo.webp (run on a Mac after replacing the logo).
# The icon is the logo, 800 px wide, centred on the brand background colour, 1024 x 1024, no alpha.
#
# Needs ImageMagick (brew install imagemagick): macOS's own `sips` cannot flatten the logo's transparency
# onto a colour.
set -eu
cd "$(dirname "$0")/.."
LOGO=../content/branding/logo.webp
OUT=MonastyrAR/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
magick -size 1024x1024 "xc:#0B0C10" \
  \( "$LOGO" -resize 800x \) -gravity center -composite \
  -alpha off -strip "$OUT"
echo "written $OUT"
