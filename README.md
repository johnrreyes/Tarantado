# Tarantado

Swift-native digital audio player (DAP) library manager for iPhone, iPad and Mac. Underlying supported DAP management
functionality from [iOpenPod](https://github.com/TheRealSavi/iOpenPod) (Python/PyQt6), rebuilt from
scratch in Swift so an iPhone or iPad can act as the host computer for a digital audio player over USB.

Connect a supported DAP via USB Mass Storage (see below for supported DAPs), import your legally owned, DRM-free music files, review what will change, and sync. No desktop required.

## How it works

Tarantado edits the existing DAP’s music database rather than regenerating it. The database is parsed
into a chunk tree that preserves every unrecognized chunk's **raw bytes**; only track and playlist
entries are mutated, and the tree is re-serialized. An untouched database round-trips to identical
bytes, including the fields this library doesn't interpret — which is what keeps firmware
compatibility intact.

Capabilities that can't be inferred from the database — whether a device's firmware checks a
signature, which `mhsd` section it browses for playlists — are recorded per model as
hardware-verified facts. When a device isn't recognized, the app refuses to write rather than guess.

| Module | What it does |
|---|---|
| `DAPDB` | The DAP binary format: parse, mutate, serialize |
| `DAPDevice` | Volume validation, device identity, filename allocation, backups |
| `DAPSync` | Source scanning (AVFoundation), diffing, transfer |
| `DAPUI` | Shared SwiftUI views: Device, DAP Library, Playlists, Local Library, Review, Sync |
| `dapctl` | macOS CLI harness for driving real hardware |

No third-party dependencies. Metadata via `AVAsset`, device I/O via `FileManager` and
security-scoped URLs.

## Supported devices

| Model | Order numbers |
|---|---|
| iPod mini (1st gen) | `M9160` |
| iPod mini (2nd gen) | `M9800`, `M9802` |
| iPod (4th gen) | `M9282`, `M9268` |
| iPod (5th gen, "video") | `MA002`, `MA146`, `MA003`, `MA147` |
| iPod (5th gen enhanced) | `MA444`, `MA446`, `MA448`, `MA450` |

Recognized but **not** writable, because their firmware checks a `hash58` signature Tarantado can't
compute yet: iPod classic 6G (`MB147`), classic late-2008 (`MB562`), nano 3G (`MB249`).

The iPod mini 2G and iPod 4G entries are verified against physical hardware. The rest come from
product documentation. An unrecognized iPod can share its identity from the Device screen, which is
what a new entry gets built from.

## Development

Join the Public TestFlight: https://testflight.apple.com/join/ryKYshWr

```bash
swift build && swift test        # unit tests, no hardware needed
./Scripts/make-test-ipod.sh      # synthetic FAT32 iPod at /Volumes/TESTPOD
./Scripts/make-test-ipod.sh detach
```

`App/` holds an `xcodegen` spec and little else — the entry point is one file, and every screen
lives in the `DAPUI` package library, so the whole UI layer stays buildable and testable with
`swift build` / `swift test` and no Xcode project.

Unit tests can only prove the parser agrees with the writer. Only the DAP's own firmware can prove
the byte layout is right, so anything touching the database format is validated against a physical
device before it's trusted.

## Reference material

- libgpod `itdb_itunesdb.c` — the authoritative C implementation of the format
- [`artm/ipod_db`](https://github.com/artm/ipod_db) — mirror of the wikiPodLinux spec
  (`ipodlinux.org` itself is dead and its domain now serves an unrelated certificate)
- iOpenPod's `itunesdb_parser` / `itunesdb_writer`

## License

MIT — see [LICENSE](LICENSE).

Device SysInfo fixtures under `Tests/` are real files from real hardware, with the serial number and
FireWire GUID replaced by placeholders. Nothing in the project reads either field to identify a
model, so the fixtures test exactly what they did before.
