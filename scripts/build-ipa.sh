#!/bin/bash
# Builds an unsigned SpotiTinder.ipa for AltStore, which signs it with your Apple ID on install.
# Usage: scripts/build-ipa.sh [output-dir]   (default: dist)
# Optional env: VERSION (e.g. 1.0.12) and BUILD_NUMBER (e.g. 12) override the project's version.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-dist}"
ARCHIVE=build/archive/SpotiTinder.xcarchive
rm -rf build/archive "$OUT"
mkdir -p "$OUT"

xcodebuild archive -quiet \
  -project SpotiTinder.xcodeproj -scheme SpotiTinder -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  ${VERSION:+MARKETING_VERSION=$VERSION} ${BUILD_NUMBER:+CURRENT_PROJECT_VERSION=$BUILD_NUMBER}

STAGE=$(mktemp -d)
mkdir -p "$STAGE/Payload"
cp -R "$ARCHIVE/Products/Applications/SpotiTinder.app" "$STAGE/Payload/"
IPA="$(pwd)/$OUT/SpotiTinder.ipa"
(cd "$STAGE" && zip -qry "$IPA" Payload)
rm -rf "$STAGE"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ARCHIVE/Products/Applications/SpotiTinder.app/Info.plist")
echo "Built $OUT/SpotiTinder.ipa (version $VERSION, $(du -h "$IPA" | cut -f1))"
