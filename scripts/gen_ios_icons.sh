#!/usr/bin/env bash
# Regenerate iOS app icons from the WAEC Direct brand logo
# (docs/waec_direct_logo-new.png).
#
# The new logo is a navy/mint glyph on a TRANSPARENT canvas. Per the current
# brand direction the icon uses a WHITE background (no navy). We composite the
# transparent glyph onto a white square at each required iOS icon size.
#
# This mirrors what scripts/gen_brand_assets.sh + flutter_launcher_icons do for
# Android/iOS, so this script only needs to be run when regenerating the iOS
# icon set directly (e.g. on macOS without a Flutter toolchain available).
set -euo pipefail
cd /home/edward-nyame/Desktop/waec-app/mobile
LOGO=/home/edward-nyame/Desktop/waec-app/docs/waec_direct_logo-new.png
ICONDIR=ios/Runner/Assets.xcassets/AppIcon.appiconset

# base size in px (point * scale) -> output filename
gen() {
  local px="$1"; local out="$2"
  ffmpeg -y -loglevel error \
    -f lavfi -i "color=c=0xFFFFFF:s=${px}x${px}" \
    -i "$LOGO" -filter_complex "[1:v]scale=$((px*62/100)):-1[fg];[0:v][fg]overlay=(W-w)/2:(H-h)/2" \
    -frames:v 1 -update 1 "$ICONDIR/$out"
  echo "wrote $out (${px}px)"
}

gen 20   Icon-App-20x20@1x.png
gen 40   Icon-App-20x20@2x.png
gen 60   Icon-App-20x20@3x.png
gen 29   Icon-App-29x29@1x.png
gen 58   Icon-App-29x29@2x.png
gen 87   Icon-App-29x29@3x.png
gen 40   Icon-App-40x40@1x.png
gen 80   Icon-App-40x40@2x.png
gen 120  Icon-App-40x40@3x.png
gen 120  Icon-App-60x60@2x.png
gen 180  Icon-App-60x60@3x.png
gen 76   Icon-App-76x76@1x.png
gen 152  Icon-App-76x76@2x.png
gen 167  Icon-App-83.5x83.5@2x.png
gen 1024 Icon-App-1024x1024@1x.png
echo "iOS icons regenerated."
