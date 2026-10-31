#!/bin/zsh
# Builds Commander in build/release.
#
# For this Mac, signed with an Apple Development certificate. The identity stays the same between builds,
# so Full Disk Access carries over. It isn't notarized, so it won't open cleanly on another Mac:
#   IDENTITY="Apple Development: you@example.com (ABCDE12345)" scripts/release.sh
#
# To share, with a Developer ID Application certificate, which needs the paid Apple Developer Program.
# This also notarizes, using a profile saved once with:
#   xcrun notarytool store-credentials commander --apple-id YOU --team-id TEAM --password APP_SPECIFIC_PASSWORD
#   IDENTITY="Developer ID Application: Your Name (TEAM)" scripts/release.sh
#
# With no IDENTITY it makes an ad hoc build, to check that the build itself works.
set -euo pipefail
cd "$(dirname "$0")/.."

out=build/release
app=$out/Build/Products/Release/Commander.app
identity=${IDENTITY:--}
profile=${NOTARY_PROFILE:-commander}

# From nothing, so a file left by an earlier build can't end up in a signed app.
rm -rf "$out"
mkdir -p "$out"
log=$out/build.log
if ! xcodebuild -project Commander.xcodeproj -scheme Commander -configuration Release -derivedDataPath "$out" \
    CODE_SIGN_IDENTITY="$identity" CODE_SIGN_STYLE=Manual OTHER_CODE_SIGN_FLAGS=--timestamp build > "$log" 2>&1; then
    tail -30 "$log"
    echo "The build failed. Full log: $log"
    exit 1
fi

codesign --verify --strict --verbose=1 "$app"
signature=$(codesign --display --verbose=2 "$app" 2>&1)
[[ $signature == *flags=*runtime* ]] || { echo "Hardened runtime is off."; exit 1; }

if [[ $identity != "Developer ID"* ]]; then
    echo "Built $app, for this Mac only."
    exit 0
fi

ditto -c -k --keepParent "$app" "$out/notarize.zip"
xcrun notarytool submit "$out/notarize.zip" --keychain-profile "$profile" --wait
xcrun stapler staple "$app"
spctl --assess --type execute --verbose "$app"
ditto -c -k --keepParent "$app" "$out/Commander.zip"
echo "Ready: $out/Commander.zip"
