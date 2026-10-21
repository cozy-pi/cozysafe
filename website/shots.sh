#!/usr/bin/env bash
# Screenshots for the site, rendered from the app itself (app/test/website_shots_test.dart):
#   website/shots.sh            render (needs Flutter and app/test/preview_assets), then convert
#   website/shots.sh --convert  only convert app/test/website/*.png already rendered
# Each shot gets two WebP sizes: 1x = its display width on the site, 2x = double (Retina).
# Change a display width here together with the matching CSS in public/style.css.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${1:-}" != "--convert" ]; then
  (cd app && flutter test test/website_shots_test.dart --update-goldens --dart-define=SHOTS=true)
fi
out=website/public/img/s
rm -rf "$out"; mkdir -p "$out"
used() {  # device and screen pairs the site shows (build.py SHOTS)
  python3 -I -c 'import sys; sys.path.insert(0, "website"); import build; print("\n".join(f"{d} {s} {w}" for d, s, w in build.SHOTS))'
}
used | while read -r device screen w; do
  for lang in en vi; do
    for mode in light dark; do
      src="app/test/website/$device-$screen-$lang-$mode.png"
      cwebp -quiet -q 82 -resize "$w" 0 "$src" -o "$out/$device-$screen-$lang-$mode-1x.webp"
      cwebp -quiet -q 80 -resize $((w * 2)) 0 "$src" -o "$out/$device-$screen-$lang-$mode-2x.webp"
    done
  done
done
ls "$out" | wc -l | xargs echo "files:"; du -sh "$out"
