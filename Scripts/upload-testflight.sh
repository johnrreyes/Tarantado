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
# Derived from the commit count so it always moves forward without a manual
# edit; override by exporting BUILD_NUMBER.
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
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
