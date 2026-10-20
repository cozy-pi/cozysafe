#!/usr/bin/env bash
# Mockups come from the app itself (docs/ui.md, mockups): render every screen of
# test/preview_test.dart in dark and light, then build test/preview/index.html, a page
# showing each screen dark | light with its caption. Publish that page (with the PNGs
# next to it) to show a proposal; never redraw screens by hand.
#   tool/mockup.sh ["Title"]
set -euo pipefail
cd "$(dirname "$0")/.."
rm -f test/preview/*.png test/preview/manifest.json
flutter test test/preview_test.dart --update-goldens --dart-define=PREVIEW=true
python3 -I tool/mockup_page.py test/preview "${1:-Cozy Safe screens}"
echo "test/preview/index.html"
