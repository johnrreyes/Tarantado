#!/bin/bash
# Captures App Store screenshots at the sizes App Store Connect requires.
#
#   6.5" iPhone : 1284 x 2778  (iPhone 14 Plus)
#   13"  iPad   : 2064 x 2752  (iPad Pro 13-inch)
#
# The app has nothing to show without a player attached, so this seeds a
# synthetic volume built by `demoseed` into the simulator's own app container
# and launches with TARANTADO_DEMO_VOLUME / TARANTADO_DEMO_SCREEN. That hook
# is behind #if DEBUG in RootView, so it cannot exist in a shipping build.
#
#   Scripts/screenshots.sh [output-dir]
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-screenshots}"
BUNDLE_ID="com.johnreyes.Tarantado"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Screens to capture, in listing order. Names are RootView.Step raw values.
#
# Local Library, Review and Sync are omitted: all three need real imported
# audio, which the demo volume does not provide, so they capture as empty
# states. Playlists is iPad-only — PlaylistsView lays its two panes out in a
# fixed HStack, which does not collapse on a phone, so the compact capture is
# a cramped split rather than a full-width list.
IPHONE_SCREENS=(device library)
IPAD_SCREENS=(device library playlists)

echo "==> Building demo volume"
swift run demoseed "$WORK/DemoVolume" Tests/DAPDBTests/Resources/golden-mini2g.itunesdb >/dev/null

echo "==> Building app for simulator"
xcodebuild -project App/Tarantado.xcodeproj -scheme Tarantado \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$WORK/dd" build >/dev/null
APP="$WORK/dd/Build/Products/Debug-iphonesimulator/Tarantado.app"

shoot() {
  local udid="$1" label="$2"
  shift 2
  local screens=("$@")
  local dir="$OUT/$label"
  mkdir -p "$dir"

  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
  # A freshly booted simulator posts first-run notifications ("Ready for Apple
  # Intelligence" and friends) that overlay the app. Let them appear and
  # auto-dismiss before anything is captured.
  sleep 20
  # Clean status bar: full signal, full battery, and a fixed clock.
  xcrun simctl status_bar "$udid" override \
    --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 \
    2>/dev/null || true

  xcrun simctl install "$udid" "$APP"

  # The container path only exists once the app is installed. Seeding the
  # volume inside it keeps everything within the app's own sandbox, which is
  # why no document picker or security-scoped bookmark is involved.
  local container
  container="$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)"
  rm -rf "$container/DemoVolume"
  cp -R "$WORK/DemoVolume" "$container/DemoVolume"

  for screen in "${screens[@]}"; do
    xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
    SIMCTL_CHILD_TARANTADO_DEMO_VOLUME="$container/DemoVolume" \
    SIMCTL_CHILD_TARANTADO_DEMO_SCREEN="$screen" \
      xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
    # Give the connect + database parse time to land before capturing. The
    # iPad is slower to settle its split view than the phone.
    sleep 10
    xcrun simctl io "$udid" screenshot --type=png "$dir/$screen.png" >/dev/null 2>&1
    echo "    $label/$screen.png  $(sips -g pixelWidth -g pixelHeight "$dir/$screen.png" | awk '/pixel/{printf "%s ", $2}')"
  done

  xcrun simctl terminate "$udid" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl shutdown "$udid" 2>/dev/null || true
}

device_udid() {
  xcrun simctl list devices available | grep "$1 (" | grep -oE "[0-9A-F-]{36}" | head -1
}

IPHONE="$(device_udid 'iPhone 14 Plus')"
IPAD="$(device_udid 'iPad Pro 13-inch')"

echo "==> iPhone 6.5\" ($IPHONE)"
shoot "$IPHONE" "iphone-6.5" "${IPHONE_SCREENS[@]}"
echo "==> iPad 13\" ($IPAD)"
shoot "$IPAD" "ipad-13" "${IPAD_SCREENS[@]}"

echo "==> Done. Files in $OUT/"
