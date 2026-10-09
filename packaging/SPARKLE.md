# Sparkle updates

MDriveHealth embeds Sparkle **2.10.0**, pinned exactly in `project.yml`.
The binary archive checksum is recorded in `Config/Sparkle.json` and verified
by Swift Package Manager. Original notices are distributed in `COPYING.Sparkle`.

## App behavior

- Menu **MDriveHealth → Check for Updates…** and **Settings → App updates** use
  Sparkle's download, signature verification, installation and relaunch UI.
- Automatic checks default to once per day. Users can turn them off.
- Automatic download/install is available in Settings and defaults to off.
  When enabled, updates install on quit. Sparkle persists these preferences;
  launching the app does not overwrite user choices.
- Before restarting for an update, the app stops new work, cancels and drains
  measurement workers, confirms cleanup, saves results and closes SQLite.
  Failure keeps the app open and the update pending for retry. Sparkle launches
  the new app; the lifecycle does not launch the old bundle.
- Updates and the appcast must be Ed25519-signed. Archive signatures are checked
  before extraction. System profiling is disabled.

Releases without Sparkle need a **one-time manual installation** of build 5 or
later before they can use the updater.

## Signing key and feed

The private signing key is in this Mac's login Keychain under Sparkle account
**`com.maclife.MDriveHealth`**. Only the public key is in the repository.
Do not replace the key for each release. Back it up securely before replacing
or erasing this Mac. To display the public key using the tools resolved by Xcode:

```sh
SPARKLE_BIN=/path/to/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin
"$SPARKLE_BIN/generate_keys" --account com.maclife.MDriveHealth -p
```

The stable feed is
`https://github.com/maclifevn/MDriveHealth/releases/latest/download/appcast.xml`.
Each stable GitHub release must include its signed **`appcast.xml`**, matching
DMG, source ZIP and checksums. Tag releases as `v<MARKETING_VERSION>`.
The latest feed contains one full update, allowing older Sparkle-enabled builds
to update directly. This initial integration does not generate delta updates.

To change hosting, update `project.yml` and `Config/Sparkle.json` together.
Retain the signing key for existing users. Increase `CURRENT_PROJECT_VERSION`
on **every** release; Sparkle compares build numbers even when the visible
version is unchanged.

## Release workflow

The signed/notarized `scripts/release.sh` path signs Sparkle's nested helpers
before the framework and host app, then generates and verifies the appcast
with the project-specific Keychain account. A missing or incorrect key fails
the release. `SHA256SUMS` includes the final signed feed. Unsigned rehearsals
do not generate a public release feed.

To generate the feed separately from a packaged app and its DMG:

```sh
python3 scripts/sparkle_appcast.py /path/to/MDriveHealth-0.1.3.dmg \
  /path/to/MDriveHealth.app /path/to/new-feed-directory \
  --tools-dir "$SPARKLE_BIN"
```

The output directory must be new. The script verifies the app's feed/key,
Keychain public key, build/version, minimum macOS, download URL, byte length,
archive signature and feed signature. It **does not upload** anything.
Upload the generated files together to the corresponding release.
Do not edit a signed feed after generation.

Building locally does not activate the GitHub feed. The release assets must
be published before public update checks succeed. Production Developer ID,
notarization and an actual installed older-to-newer update on supported
hardware remain release validation steps.

References: [Sparkle setup](https://sparkle-project.org/documentation/),
[preferences and signature settings](https://sparkle-project.org/documentation/customization/).
