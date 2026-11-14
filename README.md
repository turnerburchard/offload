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

- **One-time setup:** in Lightroom Classic, choose **File > New Catalog** to make an empty catalog, then quit Lightroom. In Offload's Settings, pick that file as the *Lightroom template catalog*. You can also choose a *Catalogs folder* (default `~/Pictures`).
- **Template check:** Offload checks the template read-only, on a temporary copy. It must be an SQLite catalog with no photos, and must not be open in Lightroom (no `.lock` file next to it).
- **What the button does:** it copies **only** the template `.lrcat` file to `<Catalogs folder>/<import name>/<import name>.lrcat`, using the same name as the SSD folder (e.g. `import-2026-11-bears-ears`). It then opens the new catalog in Lightroom Classic. If that catalog already exists, it is opened and never overwritten.
- **Then, in Lightroom:** Import → select the SSD folder → turn on **Include Subfolders** → choose **Add** (not Copy or Move).

Offload never writes to a catalog database. There is no Lightroom plugin.

## Install

1. Download `Offload-x.y.z.zip` from [Releases](../../releases) and unzip it.
2. Move `Offload.app` to `/Applications`.
3. **First launch:** the app has an ad-hoc signature rather than a Developer ID, so macOS will block a normal double-click. **Right-click Offload.app → Open → Open.** (On macOS 15 you may need **System Settings → Privacy & Security → Open Anyway**.) You only need to do this once.
4. Allow access to removable volumes when asked.

### Updates

Offload checks GitHub Releases at launch, and you can check any time with **Check for Updates…** in the app menu. It always asks before installing, and it never updates during a copy or verification. Before installing, it checks that:

- the downloaded zip's SHA-256 matches the checksum published with the release,
- the app inside has the same bundle id,
- `codesign --verify` passes.

It then swaps the new app into place and relaunches. If anything fails, the current version is left untouched.

Limitations of an ad-hoc-signed updater:

- The checksum and the zip come from the same GitHub release. That protects against corrupted or truncated downloads, not against someone who controls the GitHub repository.
- Each build has a different ad-hoc signature, so macOS may ask for removable-volume access again after an update.

Forks: the update source comes from the `OffloadUpdateRepo` Info.plist key. `build.sh` sets it from `$OFFLOAD_REPO`, or `$GITHUB_REPOSITORY` in Actions.

## Build

You only need the Xcode Command Line Tools (Swift 6.0 or newer). Full Xcode isn't required.

```sh
./build.sh            # release build -> ./Offload.app
./build.sh debug
```

The version comes from the `VERSION` file.

## Self-test

The self-test exercises the copy and verify engine against fake drives in a temp folder, and the updater offline. Neither touches real volumes.

```sh
.build/release/offload-selftest                 # uses a fresh temp dir
.build/release/offload-selftest /tmp/x a.ARW    # optional: also checks EXIF reading on a real raw file
```

## Releasing

1. Bump `VERSION` and commit.
2. Tag the commit `v<VERSION>` and push the tag.

The release workflow builds the app, runs the self-test, zips the app with `ditto`, and publishes the zip with a `.sha256` file. The checksum is also in the release notes.

## License

MIT. See [LICENSE](LICENSE).
