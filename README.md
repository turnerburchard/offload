# Offload

A small native macOS app for getting photos off an SD card safely. You set up your drives once. When you insert a card, Offload finds it, and you type a name like `escalante` and click **Copy & Verify**. It copies the card with `rsync` to your editing SSD and backup drives, checks every file by MD5, and tells you plainly whether the card is **safe to wipe**.

It is built around a Sony layout (raw files in `DCIM/`, video in `PRIVATE/M4ROOT/CLIP/`), but any card with a `DCIM/` folder works.

## What it does

- **Drive roles.** Mark one drive as your *editing SSD* and one or more as *backups*. Roles are saved by volume name.
- **Card detection.** Any newly mounted volume with a `DCIM/` folder counts as a card. The volume name is ignored, because cards often share the same name. The card summary shows file counts, total size, the capture date range from EXIF, and the volume UUID so you can tell cards apart.
- **Naming.** Photos go to `import-YYYY-MM-<name>/` on every drive. Video goes to `video/YYYY-MM-<name>/` on backup drives only. The month is filled in from the earliest capture date, and you can edit it.
- **SSD first.** The card is copied to the editing SSD and verified there first, so you can start in Lightroom ("Ready for Lightroom", with a Show in Finder button). Meanwhile it copies to the backups, all at the same time, and verifies those.
- **Copy:** `rsync -rt --modify-window=2 --exclude='._*'`. It uses `-rt` rather than `-a` because exFAT has no POSIX permissions, and the 2-second window allows for exFAT's coarse timestamps.
- **Verify.** Every card file is MD5-hashed and compared with the copy on every drive.
- **Log.** An `offload-verify-<timestamp>.log` file in each destination folder lists every file with both hashes and the final verdict.
- **Sleep.** Idle system sleep is blocked during a run. Closing the lid still sleeps the Mac, so keep it open.

## Safety model

The card is **Safe to wipe** only if *every* file on the card matched by MD5 on *every* configured backup drive. Anything else gives **NOT safe to wipe**, with the reasons listed. The editing SSD never counts toward the verdict.

The verdict is NOT safe if any of these happen:

- a configured backup drive isn't connected (Offload still copies to the drives that are),
- a file is missing, different, or unreadable on any backup,
- **any file can't be read from the card**. These files are listed at the top of the window and of every log, and a *Retry unreadable files* button tries just those files again,
- part of the card couldn't be listed, the run was cancelled, or no backups are configured.

Other guard rails:

- **Never skips by name.** Cameras reuse file numbers like `DSC00001`, so rsync's quick check is never trusted on its own. MD5 verification catches a "same name, same size, different photo" file.
- **Won't mix imports.** It refuses to write into an existing non-empty folder unless every file already there came from this card (same path and size). That case is treated as resuming the same import.
- **Ignores stale mount folders.** A drive counts as connected only if `/Volumes/<name>` is a real mount point. If a drive is unplugged, a leftover folder with its name on the internal disk is never written to.
- **Checks free space** before copying.

Offload never deletes or formats anything. Wiping the card is up to you.

## Lightroom catalog (optional)

Once the SSD copy is verified, the green **Ready for Lightroom** section has a **Create catalog & open in Lightroom** button.

- **One-time setup:** in Lightroom Classic, choose **File > New Catalog**, name it `template` and save it in your Pictures folder (so it ends up at `~/Pictures/template/template.lrcat`). Then quit Lightroom. Offload finds it automatically.
- **How the template is found:** Offload checks `<Catalogs folder>/template/template.lrcat` first, then any `.lrcat` in the Catalogs folder or one level below it whose name contains "template". It uses the first one that is valid: an SQLite catalog with no photos that isn't open in Lightroom (no `.lock` file next to it). The check is read-only and runs on a temporary copy. The Catalogs folder (default `~/Pictures`) and an explicit template can be set in Settings, but you don't have to set either.
- **What the button does:** it copies **only** the template `.lrcat` file to `<Catalogs folder>/<import name>/<import name>.lrcat`, using the same name as the SSD folder (e.g. `import-2026-11-bears-ears`). It then opens the new catalog in Lightroom Classic. If that catalog already exists, it is opened and never overwritten.
- **Then, in Lightroom:** Import → select the SSD folder → turn on **Include Subfolders** → choose **Add** (not Copy or Move).

Offload never writes to a catalog database. There is no Lightroom plugin.

## Install

1. Download `Offload-x.y.z.zip` from [Releases](../../releases) and unzip it.
2. Move `Offload.app` to `/Applications`.
3. **First launch:** the app is signed with a self-signed certificate rather than an Apple Developer ID and isn't notarized, so macOS will block a normal double-click. **Right-click Offload.app → Open → Open.** (On macOS 15 you may need **System Settings → Privacy & Security → Open Anyway**.) You only need to do this once.
4. Allow access to removable volumes when asked.

### Updates

By default Offload updates itself. It checks GitHub Releases at launch and every 24 hours. When there's a new version, it downloads and verifies it quietly in the background, and installs it **when you quit**, so the next launch is the new version. A small "Update ready — Restart now" bar lets you install right away. Updates are never installed while a copy or verification is running.

You can turn off *Automatically download and install updates* in Settings. Offload will then ask you before downloading anything. **Check for Updates…** in the app menu works in either mode.

Before installing, Offload checks that:

- the zip's SHA-256 matches the checksum published with the release,
- the app inside has the same bundle id,
- `codesign --verify` passes,
- the update is **signed by the same certificate as the installed app** (its designated requirement: identifier plus certificate leaf).

If any check fails, the installed app is left untouched.

Notes:

- Releases are signed with a self-signed certificate (not a Developer ID, not notarized). The stable certificate means macOS keeps the app's removable-volume permission across updates.
- An ad-hoc-signed install (a local build or v0.2.x) accepts the first certificate-signed update. That one-time step is how existing installs switch over to the certificate.

Forks: the update source comes from the `OffloadUpdateRepo` Info.plist key. `build.sh` sets it from `$OFFLOAD_REPO`, or `$GITHUB_REPOSITORY` in Actions.

## App icon

`Resources/AppIcon.icns` is generated by `swift scripts/make-icon.swift`, which draws it with CoreGraphics. Run that script again after changing the design.

## Build

You only need the Xcode Command Line Tools (Swift 6.0 or newer). Full Xcode isn't required.

```sh
./build.sh            # release build -> ./Offload.app
./build.sh debug
```

The version comes from the `VERSION` file.

## Signing

`build.sh` signs with the identity whose SHA-1 hash is in `$OFFLOAD_SIGN_IDENTITY`, or ad-hoc if it's unset. A self-signed certificate is untrusted, so codesign can't look it up by name. Pass the hash, and make sure its keychain is in the user search list.

The release workflow needs two repository secrets:

- `OFFLOAD_SIGNING_P12`: base64 of the `.p12`, exported with `openssl pkcs12 -export -legacy`.
- `OFFLOAD_SIGNING_P12_PASSWORD`: its password.

The workflow fails if either secret is missing, or if the build's certificate leaf doesn't match `EXPECTED_LEAF` in the workflow. Installed copies only accept updates signed with that certificate, so keep the certificate and never rotate it casually.

## Self-test

The self-test exercises the copy and verify engine against fake drives in a temp folder, and the updater offline. Neither touches real volumes.

```sh
.build/release/offload-selftest                 # uses a fresh temp dir
.build/release/offload-selftest /tmp/x a.ARW    # optional: also checks EXIF reading on a real raw file
scripts/test-signing.sh                         # also runs the certificate-pinning tests (throwaway certs in a temp keychain)
```

## Releasing

1. Bump `VERSION` and commit.
2. Tag the commit `v<VERSION>` and push the tag.

The release workflow builds the app, runs the self-test, zips the app with `ditto`, and publishes the zip with a `.sha256` file. The checksum is also in the release notes.

## License

MIT. See [LICENSE](LICENSE).
