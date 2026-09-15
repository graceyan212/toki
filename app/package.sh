#!/usr/bin/env bash
# Build the downloadable disk image: Toki.app beside an Applications shortcut,
# so the install is exactly "open the DMG, drag Toki across".
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
DIST="dist"

# Stage OUTSIDE the source tree, for the same reason build.sh installs outside
# it: this repo lives under ~/Desktop, which is iCloud-synced, and the sync
# daemon re-attaches extended attributes faster than codesign can clear them.
# Staging here produced exactly that failure — "resource fork, Finder
# information, or similar detritus not allowed" — which build.sh had already
# documented and this script initially ignored.
WORK="$(mktemp -d /tmp/toki-package.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
DMG="$WORK/Toki-$VERSION.dmg"

echo "== build a fresh app into the staging area"
mkdir -p "$STAGE" "$DIST"
APP_OUT="$STAGE/Toki.app" ./build.sh | tail -8

# The Applications symlink IS the install UI. Without it the user is expected to
# know that an app in a mounted image must be copied out first — and an app run
# from a read-only DMG cannot keep its Input Monitoring grant, because the next
# mount is a different path and therefore a different app to macOS. Every such
# user arrives at support with "it forgets my permission every time".
ln -s /Applications "$STAGE/Applications"

echo "== make $DMG"
rm -f "$DMG"
hdiutil create -volname "Toki" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | sed 's/^/   /'

# Sign the image too, so Gatekeeper has something to check before it is opened.
DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -1)
if [ -n "$DEVID" ]; then
  codesign --force --sign "$DEVID" --timestamp "$DMG"
  echo "   dmg signed with: $DEVID"
  echo
  echo "next: ./notarize.sh \"$DIST/Toki-$VERSION.dmg\""
else
  echo
  cat <<'GATE'
   DMG built but UNSIGNED and UNNOTARISED — do not put this on the site.

   Downloaded from a browser it carries the quarantine bit, and Gatekeeper will
   refuse it on every Mac but this one. Needs a Developer ID Application
   certificate first (Apple Developer Program, $99/yr), then ./notarize.sh.
GATE
fi
# Only now bring it back into the synced tree; a finished .dmg carrying an
# xattr is harmless, an unsigned bundle is not.
FINAL="$DIST/Toki-$VERSION.dmg"
mv "$DMG" "$FINAL"
ls -lh "$FINAL"
