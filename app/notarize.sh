#!/usr/bin/env bash
# Submit a DMG to Apple for notarisation, then staple the ticket into it.
#
# Stapling matters: without it the user's Mac must reach Apple to verify the
# app on first open, so a customer opening Toki offline sees it fail. The
# stapled ticket makes the check local and permanent.
set -euo pipefail
DMG="${1:-}"
[ -f "$DMG" ] || { echo "usage: ./notarize.sh dist/Toki-x.y.z.dmg"; exit 1; }

# Credentials are stored once in the keychain, never in this repo:
#   xcrun notarytool store-credentials toki-notary \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
# The password is an APP-SPECIFIC password from appleid.apple.com, not the
# account password.
PROFILE="${NOTARY_PROFILE:-toki-notary}"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat <<EOF
No notarytool credentials found under profile "$PROFILE".

Store them once:
  xcrun notarytool store-credentials $PROFILE \\
    --apple-id <your Apple ID> --team-id <your team id> --password <app-specific password>

This requires Apple Developer Program membership.
EOF
  exit 1
fi

echo "== submitting $DMG (this waits for Apple; usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "== stapling"
xcrun stapler staple "$DMG"

echo "== verifying the way a customer's Mac will"
xcrun stapler validate "$DMG"
spctl -a -vvv -t install "$DMG" || true
echo
echo "If spctl says 'accepted / source=Notarized Developer ID', it is ready to ship."
