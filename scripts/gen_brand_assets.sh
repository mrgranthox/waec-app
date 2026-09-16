#!/usr/bin/env bash
# Regenerate WAEC Direct brand masters from docs/waec_direct_logo-new.png.
#
# Source logo: navy/mint glyph on a TRANSPARENT canvas (500x500, glyph fills
# ~99% of the canvas). Per the current brand direction the launcher icon and
# splash use a WHITE background (no navy).
#
# ALL text (app name, tagline, splash description) is read from
# mobile/assets/brand_kit.json -- the single source of truth for the brand --
# so the native splash always matches what the Flutter UI shows.
#
# Masters emitted (all 1024px, Lanczos resampling so the 500px glyph is never
# upscaled more than necessary):
#   logo_mark.png          transparent glyph, padded -- Flutter UI (splash/About)
#   icon_master.png        white square + glyph ~82%  (legacy launcher + iOS)
#   adaptive_foreground.png transparent glyph ~66%   (Android adaptive safe zone)
#   android12_icon.png     transparent glyph ~62%    (Android 12+ splash icon;
#                          the OS scales + masks it to a CIRCLE, so anything
#                          near the edges/wordmark would be cut off -- keep
#                          this one glyph-only)
#   splash_logo.png        white pre-12 splash composition: glyph + name +
#                          tagline + progress bar + status (4px == 1dp)
set -euo pipefail

ROOT=/home/edward-nyame/Desktop/waec-app
cd "$ROOT/mobile"

LOGO="$ROOT/docs/waec_direct_logo-new.png"
KIT=assets/brand_kit.json
OUT=assets/brand
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf

mkdir -p "$OUT"

# ---------------------------------------------------------------- brand text
# Read the brand copy from brand_kit.json and escape it for ffmpeg drawtext
# (values are placed inside single-quoted filter strings: map apostrophes to a
# typographic quote and drop backslashes; ':' and spaces are safe in quotes).
eval "$(python3 - "$KIT" <<'PY'
import json, sys

kit = json.load(open(sys.argv[1], encoding="utf-8"))

def esc(s: str) -> str:
    return s.replace("\\", "").replace("'", "\u2019").replace("%", r"\%")

def out(name: str, value: str) -> None:
    print(f"{name}={value!r}")

def hx(s: str) -> str:
    # "#0A2540" -> "0x0A2540" (ffmpeg color syntax)
    return "0x" + s.lstrip("#").upper()

out("BRAND_APPNAME", esc(kit["appName"]))
out("BRAND_TAGLINE", esc(kit["tagline"]))
out("BRAND_DESC", esc(kit["splashDescription"]))
out("BRAND_STATUS", esc(kit["splashStatuses"][0]))
out("BRAND_INK", hx(kit["colors"]["ink"]))
out("BRAND_TEAL", hx(kit["colors"]["teal"]))
out("BRAND_BORDER", hx(kit["colors"]["border"]))
PY
)"

# ---------------------------------------------------------------- masters
# NOTE: lavfi `color` sources are infinite; always pass `-frames:v 1`.
# nullsrc (not `color=c=0x00000000`) for a truly transparent canvas.

# 1) logo_mark.png : glyph centered on a transparent 1024 canvas (~92%).
ffmpeg -y -loglevel error \
  -f lavfi -i "nullsrc=s=1024x1024:d=1,format=rgba" \
  -i "$LOGO" \
  -filter_complex "[1:v]scale=1024:1024:flags=lanczos,format=rgba,scale=940:940:force_original_aspect_ratio=decrease:flags=lanczos[g];[0:v][g]overlay=(W-w)/2:(H-h)/2" \
  -frames:v 1 -update 1 "$OUT/logo_mark.png"
echo "wrote $OUT/logo_mark.png"

# 2) icon_master.png : white square + glyph at ~82% (legacy launcher + iOS).
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0xFFFFFF:s=1024x1024" \
  -i "$LOGO" \
  -filter_complex "[1:v]scale=1024:1024:flags=lanczos,format=rgba,scale=840:840:force_original_aspect_ratio=decrease:flags=lanczos[g];[0:v][g]overlay=(W-w)/2:(H-h)/2" \
  -frames:v 1 -update 1 "$OUT/icon_master.png"
echo "wrote $OUT/icon_master.png"

# 3) adaptive_foreground.png : transparent glyph at ~66% (adaptive safe zone).
ffmpeg -y -loglevel error \
  -f lavfi -i "nullsrc=s=1024x1024:d=1,format=rgba" \
  -i "$LOGO" \
  -filter_complex "[1:v]scale=1024:1024:flags=lanczos,format=rgba,scale=676:676:force_original_aspect_ratio=decrease:flags=lanczos[g];[0:v][g]overlay=(W-w)/2:(H-h)/2" \
  -frames:v 1 -update 1 "$OUT/adaptive_foreground.png"
echo "wrote $OUT/adaptive_foreground.png"

# 4) android12_icon.png : GLYPH ONLY at ~62%, centered. Android 12+ scales this
#    into the splash icon circle -- wordmarks/edge content get cut off.
ffmpeg -y -loglevel error \
  -f lavfi -i "nullsrc=s=1024x1024:d=1,format=rgba" \
  -i "$LOGO" \
  -filter_complex "[1:v]scale=1024:1024:flags=lanczos,format=rgba,scale=635:635:force_original_aspect_ratio=decrease:flags=lanczos[g];[0:v][g]overlay=(W-w)/2:(H-h)/2" \
  -frames:v 1 -update 1 "$OUT/android12_icon.png"
echo "wrote $OUT/android12_icon.png"

# 5) splash_logo.png : white pre-Android-12 splash composition.
#    4px in this master == 1dp on screen (drawables are 1x/1.5x/2x/3x/4x), so:
#    glyph 96dp, name 24dp, tagline 14dp, status 11.5dp, bar 160x3.5dp.
ffmpeg -y -loglevel error \
  -f lavfi -i "color=c=0xFFFFFF:s=1024x1024" \
  -i "$LOGO" \
  -filter_complex "\
[1:v]scale=1024:1024:flags=lanczos,format=rgba,scale=384:384:force_original_aspect_ratio=decrease:flags=lanczos[g];\
[0:v][g]overlay=(W-w)/2:110[base];\
[base]drawbox=x=192:y=768:w=640:h=14:color=${BRAND_BORDER}@1:t=fill[track];\
[track]drawbox=x=192:y=768:w=224:h=14:color=${BRAND_TEAL}@1:t=fill[bar];\
[bar]drawtext=text='${BRAND_APPNAME}':fontfile=${FONT}:fontcolor=${BRAND_INK}:fontsize=96:x=(w-text_w)/2:y=545,\
drawtext=text='${BRAND_TAGLINE}':fontfile=${FONT}:fontcolor=${BRAND_INK}:fontsize=52:x=(w-text_w)/2:y=675,\
drawtext=text='${BRAND_DESC}':fontfile=${FONT}:fontcolor=${BRAND_INK}:fontsize=44:x=(w-text_w)/2:y=736,\
drawtext=text='${BRAND_STATUS}':fontfile=${FONT}:fontcolor=${BRAND_INK}:fontsize=46:x=(w-text_w)/2:y=824" \
  -frames:v 1 -update 1 "$OUT/splash_logo.png"
echo "wrote $OUT/splash_logo.png"

echo "Brand masters regenerated (white background, brand_kit.json sourced)."


