#!/usr/bin/env bash
# Cozy Safe Beta's app icon: the app's own icon with a gold band saying BETA across the
# bottom, so the two apps are told apart on the home screen. Run after branding/icon-1024.png
# changes (needs ImageMagick); the PNGs it writes are committed.
#   tools/beta-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."
src=branding/icon-1024.png
out=branding/icon-beta-1024.png
font=${BETA_ICON_FONT:-/System/Library/Fonts/Supplemental/Arial Bold.ttf}
magick "$src" -resize 1024x1024 \
  -fill '#f3d08e' -draw 'rectangle 0,772 1024,1024' \
  -font "$font" -fill '#165b4c' -pointsize 176 -kerning 14 -gravity south -annotate +0+34 'BETA' \
  -alpha off "$out"
# Android: one PNG a density, next to the app's own (the manifest picks by build).
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  magick "$out" -resize "${d#*:}x${d#*:}" -strip "app/android/app/src/main/res/mipmap-${d%%:*}/ic_launcher_beta.png"
done
# iPhone and iPad: a second icon set with the same file names as AppIcon.
a=app/ios/Runner/Assets.xcassets
rm -rf "$a/AppIconBeta.appiconset"
mkdir -p "$a/AppIconBeta.appiconset"
cp "$a/AppIcon.appiconset/Contents.json" "$a/AppIconBeta.appiconset/"
for f in "$a"/AppIcon.appiconset/*.png; do
  px=$(magick identify -format '%w' "$f")
  magick "$out" -resize "${px}x${px}" -strip -alpha off "$a/AppIconBeta.appiconset/$(basename "$f")"
done
echo "$out"
