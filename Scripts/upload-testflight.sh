#!/bin/bash
# Archive, export and upload Tarantado to TestFlight.
#
# Authentication uses an App Store Connect API key, not an Apple ID, so this
# runs unattended and no password is stored. Generate the key once at
#   App Store Connect > Users and Access > Integrations > App Store Connect API
# and note the Key ID and Issuer ID shown there.
#
# The .p8 downloads exactly once. Put it where the tools look for it:
#   mkdir -p ~/.appstoreconnect/private_keys
#   mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
#
# Usage:
#   ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee \
#     Scripts/upload-testflight.sh
set -euo pipefail

: "${ASC_KEY_ID:?Set ASC_KEY_ID to the App Store Connect API Key ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID to the App Store Connect Issuer ID}"

cd "$(dirname "$0")/.."

PROJECT="App/Tarantado.xcodeproj"
SCHEME="Tarantado"
ARCHIVE="build/Tarantado.xcarchive"
EXPORT_DIR="build/export"

# Every TestFlight upload needs a build number no ASC build has used before.
# A UTC timestamp, YYMMDD.HHMM, so it always moves forward without a manual
# edit; override by exporting BUILD_NUMBER.
#
# This used to be `git rev-list --count HEAD`, which was fine until the repo's
# history was replaced with a single root commit before publishing: the count
# dropped from 17 to 3, and every upload after that would have been rejected
# for reusing a build number. A clock cannot be rewound by a rebase.
#
# Split across a period rather than one YYMMDDHHMM integer because Apple caps
# each component of a build number at INT32, and the ten-digit form (2608242121)
# is over it. Two components sort the same way and stay readable. Taken from a
# single `date` call so the two halves cannot straddle a minute boundary, and in
# UTC so a machine in another timezone can't produce a lower number than the
# previous upload.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%y%m%d.%H%M)}"
echo "==> Building build number ${BUILD_NUMBER}"

rm -rf "$ARCHIVE" "$EXPORT_DIR"

xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  -allowProvisioningUpdates \
  archive

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist App/ExportOptions.plist \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates

IPA="$EXPORT_DIR/Tarantado.ipa"

# Validate before uploading: catches missing icons, bad entitlements and
# version collisions in seconds instead of via a rejection email later.
echo "==> Validating"
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploading"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploaded. Processing in App Store Connect usually takes 5-15 minutes."
