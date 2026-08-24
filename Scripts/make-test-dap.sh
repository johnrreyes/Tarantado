#!/bin/bash
# Creates a synthetic FAT32 "iPod" on a disk image, so integration tests never
# need the physical device. Mirrors the layout of the real iPod mini 2G.
#
#   ./Scripts/make-test-ipod.sh          # create + mount at /Volumes/TESTPOD
#   ./Scripts/make-test-ipod.sh detach   # unmount and delete
set -euo pipefail

IMG="${TMPDIR:-/tmp}/testpod.dmg"
VOL="/Volumes/TESTPOD"
FIXTURES="$(cd "$(dirname "$0")/.." && pwd)/Tests"

if [ "${1:-}" = "detach" ]; then
  hdiutil detach "$VOL" 2>/dev/null || true
  rm -f "$IMG"
  echo "detached and removed $IMG"
  exit 0
fi

hdiutil detach "$VOL" 2>/dev/null || true
rm -f "$IMG"
hdiutil create -fs MS-DOS -size 200m -volname TESTPOD -quiet "${IMG%.dmg}"
hdiutil attach "$IMG" -quiet

mkdir -p "$VOL/iPod_Control/Device" "$VOL/iPod_Control/iTunes"
for i in $(seq -w 0 49); do mkdir -p "$VOL/iPod_Control/Music/F$i"; done

cp "$FIXTURES/DAPDeviceTests/SysInfo-mini2g.txt" "$VOL/iPod_Control/Device/SysInfo"
cp "$FIXTURES/DAPDBTests/Resources/golden-mini2g.itunesdb" "$VOL/iPod_Control/iTunes/iTunesDB"

echo "Test iPod mounted at $VOL"
df -h "$VOL" | tail -1
