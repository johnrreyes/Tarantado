# Tarantado

A Swift-native iPod library manager for iPhone, iPad and Mac. Inspired by
[iOpenPod](https://github.com/TheRealSavi/iOpenPod) (Python/PyQt6), rebuilt from scratch in Swift
so an iPad can act as the host computer for a classic iPod over USB.

## Status

**The database format is validated on real hardware.** On 2026-08-17 the engine wrote 5 MP3s and a
rebuilt `iTunesDB` to a physical iPod mini 2G (M9800, firmware 1.4.1); booting the Apple firmware
showed all 5 tracks correctly under Songs, Artists and Albums. That confirms the `mhit` field offsets
and `mhod` strings land where the firmware expects them — the project's single largest risk.

On 2026-08-18 the add path was joined by the other two: **playlists** (a created playlist appears in
Music → Playlists, lists its tracks and plays them) and **removal** (deleting 2 of 5 tracks left
exactly 3, all playing, with no orphaned files and no dangling database references). Removal is the
sterner test of the two — it rewrites the track list and every playlist entry referencing the
removed tracks, so the risk is a *surviving* track's entry being corrupted in the rewrite.

| Module | What it does | State |
|---|---|---|
| `DAPDB` | The `iTunesDB` binary format: parse, mutate, serialize | Done |
| `DAPDevice` | Volume validation, device identity, filename allocation, backups | Done |
| `DAPSync` | Source scanning (AVFoundation), diffing, transfer | Add, removal and playlists — all hardware-validated |
| `DAPUI` | Shared SwiftUI views | Device, iPod Library, Playlists, Local Library, Review, Sync |
| `dapctl` | macOS CLI harness for hardware testing | `info` `list` `scan` `plan` `sync` `remove` `playlists` `playlist` |

On 2026-08-18 the **app** synced music to the device end to end for the first time — connect, scan
a folder, review, sync — on macOS. Two sandbox-only bugs surfaced that the CLI had never hit; see
"What the sandbox broke" below.

**The iPad-as-host premise is confirmed.** Later the same day the app ran on a physical iPhone
(iPhone 17, iOS 26.6) with an iPod attached over USB, and the whole flow worked from the phone:
the iPod is reachable through the iOS document picker, music copied to it, and track removal worked.
That was the project's load-bearing assumption and it held.

### Verified on the physical device
Byte-identical file copies · idempotent re-sync (0 adds on a repeat run) · incremental sync (only new
tracks added) · playlist create, rename, reorder and delete · removing a track that a non-master
playlist holds, leaving that playlist intact minus the track · track removal leaving no orphaned
files and no dangling database references · correct free-space reporting · no AppleDouble litter ·
backups written before each mutation · the device's unrelated 961-file Rockbox library left untouched
throughout.

### Two bugs that only a real device could have found
- `volumeAvailableCapacityForImportantUsage` returns **0** on FAT32 USB volumes — i.e. every classic
  iPod — while 23 GB was genuinely free. Unfixed, every sync would refuse to run for lack of space.
- macOS stamps `com.apple.provenance` on written files, and any xattr on FAT32 materializes a 4 KB
  `._NAME` AppleDouble sidecar — roughly 900 junk files across a full library. The xattr itself is
  system-protected and cannot be removed (even `xattr -c` leaves it), so the copy path deletes the
  sidecar instead.

## Design notes

**Preserve-and-augment.** Most iPod tools regenerate `iTunesDB` from scratch and break firmware
compatibility in the process. We instead parse the device's existing database into a tree that keeps
every unrecognized chunk's **raw bytes**, mutate only the track and playlist entries, and re-serialize.
The gating test is a byte-identical round-trip of a real on-device database.

**Chunk navigation.** All integers are little-endian. Every chunk has a 4-byte ASCII tag and a
`headerLen` at offset 4, but offset 8 differs by family:

- *Sized containers* (`mhbd`, `mhsd`, `mhit`, `mhyp`, `mhip`, `mhod`) — offset 8 is `totalLen`,
  covering header + children.
- *Counted list headers* (`mhlt`, `mhlp`, `mhla`, `mhia`) — offset 8 is a **child count**, not a
  length. Children start at `headerLen`; you parse exactly `count` of them.

`headerLen` varies by chunk and by iPod generation, so it is always read from the file, never assumed.
Timestamps are seconds since **1904-01-01 UTC**. Strings in `mhod` chunks are UTF-16LE.

**No database signature needed** for pre-2007 iPods. `hash58` arrived with the iPod Classic 6G and
nano 3G; the mini predates it. `DeviceModel` carries the signature requirement as a capability flag so
newer devices can be added later, and refuses to write to unidentified models.

**No third-party dependencies.** Metadata via `AVAsset`, future transcoding via `AVAudioConverter`
(ALAC and AAC encode natively; note MP3 encoding is unavailable on Apple platforms, so MP3 is
pass-through only), device I/O via `FileManager` and security-scoped URLs.

## Why the app owns a copy of your music

On iOS there is no persistent view of the filesystem. A document picker hands back a
security-scoped URL that stops being readable once its scope ends, and a bookmark to a folder inside
another app's container is not something you can rely on re-resolving later. "Remember this music
folder and scan it again tomorrow" is simply not on offer.

So the app keeps a **local library**: a folder in its own container that music is imported into
(copied) before it can be synced. That is the only way to have a library that is still there next
launch. It lives in `Documents` with `UIFileSharingEnabled`, which makes it visible in the Files
app — the escape hatch for getting music in from another app, or back out again, without Tarantado
implementing either.

macOS keeps the older behaviour as well ("Sync From a Folder Instead…"), because a Mac already has
a music library on disk and duplicating it into the container to sync from it would be absurd. The
two modes differ in one way that matters beyond display: an external folder's security scope dies
with the picker, so its scan is discarded on disconnect, while the local library survives.

## Reference material

- libgpod `itdb_itunesdb.c` — the authoritative C implementation of the format
- [`artm/ipod_db`](https://github.com/artm/ipod_db) — mirror of the wikiPodLinux spec
  (`ipodlinux.org` itself is dead and its domain now serves an unrelated certificate)
- iOpenPod's `itunesdb_parser` / `itunesdb_writer`

## Development

```bash
swift build && swift test        # unit tests, no hardware needed
./Scripts/make-test-ipod.sh      # synthetic FAT32 iPod at /Volumes/TESTPOD
./Scripts/make-test-ipod.sh detach
```

### The app

`App/` holds an `xcodegen` spec and nothing else of substance — the entry point is one file, and
every screen lives in the `DAPUI` package library so the whole UI layer stays buildable and
testable with plain `swift test`, no Xcode project required.

```bash
cd App && xcodegen generate      # regenerate Tarantado.xcodeproj from project.yml
xcodebuild -project App/Tarantado.xcodeproj -scheme Tarantado -destination 'platform=macOS' build
xcodebuild -project App/Tarantado.xcodeproj -scheme Tarantado -destination 'generic/platform=iOS Simulator' build
```

The generated `.xcodeproj` is **not** tracked; `project.yml` is the source of truth. One target
covers iOS, iPadOS and macOS — anything platform-specific is an `#if os(...)` inside `DAPUI`
rather than a second target.

Signing is automatic against `DEVELOPMENT_TEAM: 7VB9A7H26M`. Override without editing the file:

```bash
xcodebuild ... DEVELOPMENT_TEAM=XXXXXXXXXX
```

**Installing on a real iPhone or iPad additionally needs the device registered to the team.** A
build for `generic/platform=iOS` currently fails with *"Your team has no devices from which to
generate a provisioning profile"* — the team is fine, it just has no registered devices. Connect the
iPhone or iPad to the Mac once, let Xcode register it, then:

```bash
xcodebuild -project App/Tarantado.xcodeproj -scheme Tarantado \
  -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

Test fixtures (`Tests/DAPDBTests/Resources/golden-mini2g.itunesdb`,
`Tests/DAPDeviceTests/SysInfo-mini2g.txt`) are verbatim copies from a physical iPod mini 2nd gen
(M9800, firmware 1.4.1, FAT32).

## What the sandbox broke

The CLI and the app run the same engine, but the app runs it inside App Sandbox, and two failures
only ever appear there. Both were found by auditing the device after the first successful UI sync —
the sync itself reported success.

**Security scope has to be held for both ends of a copy.** A folder from a document picker is
unreadable until `startAccessingSecurityScopedResource()`, and that scope ends when the scan does.
`SyncEngine` then couldn't read a single source file. Two things made this hard to see: the scan
path had the same gap, and `FileManager.enumerator` reports "no access" by *yielding nothing* rather
than failing — so an unscoped scan looks exactly like a folder with no music in it.

**`com.apple.provenance` can be stamped after a per-write strip.** Every write site already deletes
the sidecar it caused, which is sufficient from the CLI. Under the sandbox the xattr lands late and
re-materializes a sidecar for a file that was already cleaned — observed as a `._` beside every
track a sandboxed sync copied, where the same sync from the CLI left none. `SyncEngine.apply` now
finishes with `AppleDoubleCleanup.stripRecursively` over `iPod_Control` (scoped there deliberately:
the volume root holds the user's own files).

A third bug was not sandbox-specific, just exposed by it: a copy that failed *after* creating its
destination but *before* reading the source left a zero-byte file on the device, referenced by
nothing and cleaned up by nothing. The failed permission run stranded 13 of them.

## Playlist order lives in the entries, not in the position field

Each `mhip` entry carries a `playlistPosition` mhod, and it is tempting to treat that as where order
is stored. **It is not what the firmware reads.** Verified on the reference mini 2G 2026-08-18: a
playlist whose position mhods were rewritten to reverse it, while its `mhip` children stayed put,
displayed in the *original* order. Order is the physical order of the entries.

Two consequences, both fixed:

- `reorderingPlaylist` rewrote positions only, so every reorder was a no-op on the device. It now
  moves the entries and renumbers positions to match, so the two encodings never disagree.
- `MHYP.trackIDsInOrder` *sorted by position*, i.e. by the field the firmware ignores. So
  `dapctl playlist show` read back the order we had written and reported a reorder that never
  happened as a success. It now reads child order.

The second is the one worth remembering: **the verification tool agreed with the bug.** The unit
tests had the same blind spot — they asserted order through `trackIDsInOrder`, the same accessor the
reorder updated, so they were self-consistent whichever encoding was wrong and passed before and
after the fix. Tests that can catch this have to read the chunk tree directly; see
`physicalEntries` in `PlaylistMutationTests`.

A gapped playlist (positions `0, 2` after a removal) was confirmed to display correctly, which
follows from the above. `removingPlaylistEntries` renumbers survivors anyway, to keep this library's
own invariant that the two encodings agree.

## Which mhsd section holds the browsable playlists

A real iTunesDB carries playlists in more than one `mhsd` section. On the reference mini 2G the
master playlist is **mirrored across sections 3 and 2** under a single persistent ID, and iTunes'
own smart playlists sit in section 5. Nothing in the bytes says which section the firmware reads,
and it cannot be inferred — the section holding the *most* playlists is section 5, which is the
wrong answer, so the obvious heuristic picks wrong.

Determined on hardware 2026-08-18 by writing three identically-populated playlists, one into each
candidate section, and booting the Apple firmware: **only the section 3 playlist appeared** in
Music → Playlists, and opening it listed both its tracks and played them. Sections 2 and 5 showed
nothing. All three probes were then deleted and the database returned to its original state.

This is therefore a hardware-verified per-model fact, carried as
`DeviceModel.playlistSectionType` alongside `requiresDatabaseSignature`. It is `nil` for every
model outside mini 2G, and playlist creation **refuses rather than guessing** when it's `nil` —
`dapctl playlist create --section N` is the override used to establish it for a new model.

Two consequences for code that predates this:
- `SyncEngine` chose the master playlist with `playlists.first(where: \.isMaster)`, i.e. document
  order. That picks correctly on the mini 2G, but only because of how iTunes ordered the sections.
  It now prefers the model's verified section.
- `ChunkMutation.primaryPlaylistListChunk`'s "whichever `mhlp` has the most children" heuristic
  is wrong on this device. It is still the fallback for models with no verified section; anything
  that knows its section goes through `addingPlaylist(_:toSectionType:in:)`.

## Paused — resume here (2026-08-18)

`swift build` and `swift test` are green: **166 tests, 25 suites**.

Before simplifying anything in the tests: inlining `#expect(Set(a) == Set([b, c]))` crashes inside
the `#expect` macro's own expression capture (`EXC_BAD_ACCESS` in `objc_retain`), killing the whole
test process and taking unrelated tests with it. Hoist values into locals first — see the comment in
`SyncEngineTests.swift`. `#require(xs.first(where: \.someProperty))` hits the same macro-capture
problem and needs the same treatment.

`AppModel()` resolves `.documentDirectory` to create the local library. Outside an app container
that is the user's **real** `~/Documents`, so tests must construct it as `AppModel(localLibrary:)`
— passing `nil` for the common case — and never with the public no-argument initializer.

### Getting it onto a device
Three separate things gate a first device build, and each reports as a confusing account-side error:

1. **Developer Mode** must be enabled on the phone (Settings → Privacy & Security), or the device
   can't be registered — which surfaces as "Your team has no devices from which to generate a
   provisioning profile", pointing at the account rather than the phone.
2. **The screen must be unlocked** when the developer disk image mounts, or the destination never
   becomes available (`kAMDMobileImageMounterDeviceLocked`).
3. **The device must be registered with the team.** `xcodebuild -allowProvisioningUpdates` creates
   certificates and profiles but does *not* register a new device for a paid team; selecting the
   device in the Xcode GUI once does, and that is the only step that needs the GUI.

### Picked up next
- **The playlist screens have never run against real hardware.** Create, rename, delete, membership
  and drag-to-reorder are unit-tested against a synthetic volume only. Adding and removal are
  confirmed through the UI on both macOS and iPhone; playlists are the remaining gap.
- **The local library is untested on a device.** Import (files and folders), the dedupe rules and
  removal are unit-tested, but no music has been imported on a phone yet — in particular whether
  importing an album from the Files app behaves, and whether `UIFileSharingEnabled` really surfaces
  the folder.
- **iPad has not been tried at all**, only iPhone and Mac.

### Device state
The iPod holds **15** tracks and its original 4 playlists, with no AppleDouble litter, no orphaned
files, and no dangling database references; its 961-file Rockbox library is untouched. The playlists
created for the validation runs have all been deleted. *Loneliest Girl* was deleted by the
non-master-playlist removal test and is re-addable from `~/Music/Middle of Nowhere - Kacey
Musgraves/`. Baseline backup: `~/iPod-baseline-20260817-194040/`.

## License

MIT — see [LICENSE](LICENSE).

Device SysInfo fixtures under `Tests/` are real files from real hardware, with the serial number and
FireWire GUID replaced by placeholders. Nothing in the project reads either field to identify a
model, so the fixtures test exactly what they did before.
