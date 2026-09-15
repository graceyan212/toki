#!/usr/bin/env bash
# Build Toki and assemble a real .app bundle.
#
# The bundle is not cosmetic. macOS ties a TCC grant (Input Monitoring) to the
# binary's code identity, so a bare SwiftPM executable loses its permission every
# time it is rebuilt at a new path — and the app then runs silently with no
# explanation. Bundling plus a stable signature keeps the grant alive.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
BUNDLE_ID="com.graceyan.toki"

# Install OUTSIDE the source tree. ~/Desktop is iCloud-synced, and the sync
# daemon continuously re-attaches com.apple.fileprovider / com.apple.FinderInfo
# extended attributes that codesign refuses with "resource fork, Finder
# information, or similar detritus not allowed" — clearing them before signing is
# a race against the daemon, and losing it leaves the bundle UNSIGNED while the
# log looks fine. ~/Applications is not synced, so signing is deterministic.
APP="${APP_OUT:-$HOME/Applications/Toki.app}"
BIN=".build/release/toki"

echo "== build"
swift build -c release

echo "== self-test (a synthesiser that outputs silence looks exactly like one that works)"
"$BIN" --self-test

echo "== assemble $APP"
rm -rf "$APP"
mkdir -p "$(dirname "$APP")"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp -X "$BIN" "$APP/Contents/MacOS/toki"   # -X drops extended attributes

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>              <string>Toki</string>
  <key>CFBundleDisplayName</key>       <string>Toki</string>
  <key>CFBundleIdentifier</key>        <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>        <string>toki</string>
  <key>CFBundlePackageType</key>       <string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key>           <string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key>    <string>13.0</string>
  <!-- menu-bar only: no dock icon. The first-run window is shown explicitly. -->
  <key>LSUIElement</key>               <true/>
  <key>NSHighResolutionCapable</key>   <true/>
  <key>NSHumanReadableCopyright</key>  <string>Grace Yan</string>
</dict>
</plist>
PLIST

# Sign. Three things here were learned the hard way:
#   * --deep on a bundle with no resources produces a signature that then fails
#     verification ("code has no resources but signature indicates they must be
#     present"), so it is omitted.
#   * a stale _CodeSignature directory makes --force sign on top of the wrong
#     expectations; remove it first.
#   * extended attributes left by cp make codesign refuse outright with
#     "resource fork, Finder information, or similar detritus not allowed" —
#     and it reports that on stderr while the script happily continues, so the
#     bundle ends up unsigned while the log says nothing is wrong.
rm -rf "$APP/Contents/_CodeSignature"
find "$APP" -exec xattr -c {} \; 2>/dev/null || true    # this macOS's xattr has no -r

# Identity preference, strictest first:
#   1. Developer ID Application — the ONLY kind that can be notarised and
#      therefore the only kind a stranger can open without Gatekeeper refusing.
#   2. any other real certificate — fine locally; keeps the TCC grant stable.
#   3. ad-hoc — works, but the designated requirement is the binary's hash, so
#      every rebuild is a different app to macOS and the grant is lost.
DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p' | head -1)
ANYID=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(.*\)".*/\1/p' | head -1)

# --options runtime (Hardened Runtime) is MANDATORY for notarisation. It costs
# nothing here: Input Monitoring is a TCC grant, not an entitlement, so a
# listen-only event tap keeps working under it.
if [ -n "$DEVID" ]; then
  IDENTITY="$DEVID"; DISTRIBUTABLE=yes
elif [ -n "$ANYID" ]; then
  IDENTITY="$ANYID"; DISTRIBUTABLE=no
else
  IDENTITY="-";      DISTRIBUTABLE=no
fi

codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" \
         --options runtime --timestamp=none "$APP" 2>&1 | sed 's/^/   /'
echo "   signed with: $IDENTITY"

if codesign -vv "$APP" 2>&1 | grep -q "satisfies its Designated Requirement"; then
  echo "   signature verifies"
else
  echo "   WARNING: signature does not verify — Input Monitoring will not stick"
  codesign -vv "$APP" 2>&1 | sed 's/^/   /'
fi

# Print the requirement, because "the grant will survive" is a claim about THIS
# string and nothing else. An ad-hoc signature prints "# designated =>" and a
# real certificate prints "designated =>" with no comment marker. Matching only
# the first form made this check print "<none>" and then fall through to the
# SUCCESS branch — claiming a stable identity on a parse failure. Accept both,
# and treat an unparsed requirement as a failure rather than as good news.
DR=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#\{0,1\} *designated => //p')
echo "   designated requirement: ${DR:-<UNREADABLE>}"
case "$DR" in
  "")        echo "   WARNING: unreadable requirement — treat the grant as unstable." ;;
  *cdhash*)  cat <<'WARN'

   !! The requirement is HASH-based, so a rebuild will invalidate the Input
      Monitoring grant. After rebuilding: REMOVE Toki in System Settings >
      Privacy & Security > Input Monitoring with the minus button, then re-add.
WARN
  ;;
  *certificate*) echo "   -> certificate-based identity: rebuilds keep the permission" ;;
  *)         echo "   NOTE: requirement is neither hash- nor certificate-based; unverified." ;;
esac

echo
if [ "$DISTRIBUTABLE" = yes ]; then
  echo "built $APP  (Developer ID — ready for ./notarize.sh)"
else
  cat <<'GATE'
built, but NOT DISTRIBUTABLE.

   No "Developer ID Application" certificate was found, so this build cannot be
   notarised. On anyone else's Mac it will fail to open — Gatekeeper reports
   "Toki is damaged and can't be opened", which is indistinguishable from a
   corrupt download and is the single most common way a small Mac app loses a
   customer before launching once.

   To fix: enrol in the Apple Developer Program ($99/yr), then create a
   "Developer ID Application" certificate in Xcode > Settings > Accounts >
   Manage Certificates. Re-run this script and it will pick it up automatically.
GATE
fi
echo
echo "  open \"$APP\"             # run it"
echo "  $BIN --self-test          # verify synthesis headlessly"
echo "  $BIN --diag               # verify the LISTENER (counts only)"
