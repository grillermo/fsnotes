# Deploying FSNotes to your iPhone (OTA)

`./deploy-ios` builds FSNotes iOS from this checkout, signs it **ad hoc** with
your paid Apple Developer team (`Q3WS4MWCW3`, the one PatataTube uses), and
publishes it to `files.chiq.me` so the iPhone installs it straight from Safari.
It works exactly like `../patatatube/deploy`'s OTA route, minus the AltStore
source and GitHub release (this repo is upstream's, not yours to push to).

**Install / update link (open on the iPhone in Safari):**

<https://files.chiq.me/files/e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html>

Add it to the Home Screen once (Share → Add to Home Screen). The URL never
changes, and each deploy overwrites what it installs.

---

## Every time: ship a new build

```bash
./deploy-ios             # build + publish; prints the install link
./deploy-ios --install   # same, and also push it to the paired iPhone directly
./deploy-ios --build-only  # just produce build/FSNotes-<ver>-<build>.ipa
```

Then on the iPhone: tap the Home Screen bookmark → **Install FSNotes** →
confirm. It installs over the previous build and keeps your notes and settings.

Takes ~3–5 min (mostly the Release archive). Needs `../file_to_s3` serving
`files.chiq.me` from this Mac, as it does for PatataTube.

`--install` uses `xcrun devicectl` over Wi‑Fi or cable. **Unlock the phone
first**, or it fails with `kAMDMobileImageMounterDeviceLocked`. That failure
is only a warning, since the Safari link is already published by then.

## What the script does

1. Copies this working tree (uncommitted changes included) to a tmp dir.
2. Rewrites the upstream identifiers in that copy only. Apple won't let your
   team sign for identifiers registered to the upstream author's team:

   | upstream                          | your build                          |
   |-----------------------------------|-------------------------------------|
   | `co.fluder.mobile.FSNotes-iOS`    | `com.grillermo.fsnotes`             |
   | `…FSNotes-iOS.FSNotes-iOS-Share`  | `com.grillermo.fsnotes.FSNotes-iOS-Share` |
   | `iCloud.co.fluder.fsnotes`        | `iCloud.com.grillermo.fsnotes`      |
   | `group.es.fsnot.user.defaults`    | `group.com.grillermo.fsnotes`       |
   | team `866P6MTE92`                 | team `Q3WS4MWCW3`                   |

   Your checkout is never touched, so `git pull` from upstream never conflicts.
3. `xcodebuild archive` (Release, `generic/platform=iOS`) with
   `-allowProvisioningUpdates`. Xcode creates the App IDs, iCloud container,
   app group and profiles on your team by itself.
4. `xcodebuild -exportArchive` with `method = release-testing` (ad hoc). It
   emits the `manifest.plist` that the `itms-services://` link points at.
5. Checks that the iPhone's UDID is inside the ad hoc profile, and warns if not.
6. Copies the `.ipa`, manifest, icon and install page into
   `../file_to_s3/files` (atomic rename), and prunes all but the last two `.ipa`s.

Version: `MARKETING_VERSION` stays upstream's (7.3.3). The build number is a
timestamp (`YYYYMMDD.HHMM`).

## One-time setup (already done on this Mac, 2026‑09‑23)

Only redo these if something changes:

1. **Xcode signed in** with the Apple ID of the paid team: Xcode → Settings →
   Accounts. That's what lets `-allowProvisioningUpdates` work.
2. **iPhone 16e registered** on the portal: UDID `00008140-001509200E02801C`,
   <https://developer.apple.com/account/resources/devices/list>.
   The first deploy confirmed it is in the ad hoc profile.
3. **A new device?** Register its UDID there (Xcode → Window → Devices and
   Simulators → Identifier), then **re-run `./deploy-ios`**. An ad hoc
   profile only contains devices registered *before* the build.

## Things to know

- **Separate iCloud folder.** This build uses the `iCloud.com.grillermo.fsnotes`
  container, so its "FSNotes" iCloud Drive folder is **not** the App Store
  FSNotes' folder. To bring existing notes over, copy them into the new
  FSNotes folder with the Files app.
- **Coexists with the App Store app.** The bundle ID is different, so both can
  be installed at once.
- **Signature lasts until the profile expires** (currently 2027‑09‑06, about
  the membership renewal). Just redeploy after renewing.
- Overrides, all optional: `FSNOTES_TEAM_ID`, `FSNOTES_BUNDLE_PREFIX`,
  `FSNOTES_DEVICE_UDID`, `FSNOTES_PUBLISH_DIR`, `FSNOTES_FILES_BASE`, and
  `FSNOTES_KEEP_WORK=1`, which keeps the tmp dir and its `archive.log`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Tapping Install does nothing | Must be **Safari**, and the page must be the `files.chiq.me` one (it needs HTTPS and `text/html`). |
| "Unable to Install FSNotes" | Device not in the profile. The script prints ⚠ for this. Register the UDID and redeploy. |
| Archive fails with `No Account for Team` / `No profiles for 'com.grillermo.fsnotes'` | Xcode → Settings → Accounts: sign in again. Then rerun with `FSNOTES_KEEP_WORK=1` and read `archive.log`. |
| `upstream identifiers survived the rebrand` | Upstream added an identifier in a new file. Add that file to `REBRAND_FILES` in `deploy-ios`. |
| `expected <file> — did upstream move it?` | Upstream renamed a file. Update `REBRAND_FILES`. |
| `--install` fails: `device is locked` | Unlock the iPhone and rerun, or just use the Safari link. |
