#!/usr/bin/env bash
# Run the interface in a browser on pretend data (lib/preview_main.dart).
# Sample photos come from test/preview_assets (free photos, not in git).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p web/preview
rm -f web/preview/*.jpg
n=1
for f in test/preview_assets/*.jpg; do
  [ -e "$f" ] || continue
  cp "$f" "web/preview/photo$n.jpg"
  n=$((n + 1))
done
exec flutter run -d web-server --web-port "${PORT:-8765}" -t lib/preview_main.dart
