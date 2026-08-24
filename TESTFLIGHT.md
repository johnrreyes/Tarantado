# Shipping Tarantado to TestFlight

Bundle ID `com.johnreyes.Tarantado` is registered and a store provisioning
profile exists — both were created automatically during the first archive.
Signing uses a **cloud-managed** Apple Distribution certificate, so there is
no private key to install on this Mac or to copy to CI.

## One-time setup

### 1. Create the App Store Connect API key

App Store Connect → **Users and Access → Integrations → App Store Connect API**
→ **+**. Give it the **App Manager** role.

Note the **Key ID** and the **Issuer ID**, then install the key — the `.p8`
downloads exactly once and cannot be re-downloaded:

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 ~/.appstoreconnect/private_keys/
```

### 2. Create the app record

App Store Connect → **Apps → + → New App**:

| Field | Value |
|---|---|
| Platforms | iOS |
| Name | Tarantado |
| Primary language | English (U.S.) |
| Bundle ID | `com.johnreyes.Tarantado` |
| SKU | anything unique, e.g. `tarantado-001` |

The **Name** must be unique across the whole App Store. If it is taken, pick
another here — it is independent of `CFBundleDisplayName` on the home screen.

## Every release

```bash
ASC_KEY_ID=XXXXXXXXXX ASC_ISSUER_ID=aaaaaaaa-bbbb-... \
  Scripts/upload-testflight.sh
```

The script archives, exports, validates, and uploads. The build number comes
from `git rev-list --count HEAD`, so it always increases; override with
`BUILD_NUMBER=N` if you need to. Marketing version lives in `App/project.yml`
as `MARKETING_VERSION` (currently `1.0`) — bump it there and re-run
`xcodegen generate`.

Processing takes 5–15 minutes, after which the build appears under TestFlight.

## Going from internal to public

**Internal testing** works as soon as processing finishes — up to 100 members
of your team, no review.

**Public testing** needs more:

1. **TestFlight → Test Information** — fill in feedback email, description,
   and what to test. Required before any external build is submitted.
2. **Submit for Beta App Review.** External builds are reviewed; this is
   lighter than full App Store review but is a real human pass, typically
   24–48 hours.
3. **Create a public link.** TestFlight → your external group → enable
   **Public Link**. That gives a URL anyone can use, with a tester cap you set
   (up to 10,000).

### Worth knowing before review

- **A privacy policy URL is required** for external testing. The app needs one
  even though it collects nothing — a short static page saying so is enough.
- **App Privacy** (App Store Connect → App Privacy) must be filled in. Tarantado
  reads local files and writes to an attached device; if it genuinely sends
  nothing anywhere, this is a short "Data Not Collected" declaration.
- **Export compliance** is pre-answered by `ITSAppUsesNonExemptEncryption: false`
  in `App/project.yml`, so uploads no longer stop to ask.
- **Explain the hardware in review notes.** The app's function — writing a music
  database to an attached USB mass-storage device — is unusual enough that a
  reviewer without the hardware cannot exercise it. Say so explicitly and
  describe what the app does when nothing is attached, or expect a rejection
  for "incomplete functionality."

## Placeholder that still needs replacing

`App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png` is a generated
placeholder, not a designed icon. It satisfies the upload requirement and
nothing more. Replace the file at the same path and size (1024×1024, no alpha,
no rounded corners — the system masks it).
