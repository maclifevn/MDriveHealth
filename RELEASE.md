# Build and distribution / Build và phân phối

Release version/build/minimum OS come from `Config/Version.xcconfig`.
`Config/ReleaseToolchain.json` pins the actual Xcode build, SDK and XcodeGen.
A mismatch fails before building. Change pins deliberately and repeat the
compatibility checks; linked SDK metadata is never rewritten after build.

For an unsigned, local packaging rehearsal:

```sh
scripts/release.sh --unsigned /tmp/MDriveHealth-release-check
```

The output directory must not exist. The script copies a private source
snapshot, generates the Xcode project there, seals its exact source hashes,
runs Core and app tests, and archives arm64/x86_64. Source changes after
sealing fail validation. The original checkout and existing outputs are not
reset or removed. Inspect all logs; unsigned packages use `-UNSIGNED.dmg`.

With a Developer ID Application identity and stored notarytool credentials:

```sh
scripts/release.sh "Developer ID Application: Your Name (TEAMID)" mdrivehealth
```

The helper is signed before the app. Verification uses `--deep --strict`;
recursive signing with `--deep` is not used. The pipeline checks accepted
notary JSON, validates staples and saves Gatekeeper results for app and DMG.
Source/notice resources are installed before signing. These steps have not
yet been accepted with this project's production signing credentials.
[Apple's signing guidance](https://developer.apple.com/library/archive/technotes/tn2206/_index.html)
explains signing order and bundle integrity.

Every binary release includes `LICENSE`, `NOTICE.txt`, upstream GPL text,
and the exact corresponding-source archive both in the app Resources and
beside the app in its DMG. Settings reveals that archive. It contains app,
Core/C bridge, resources, third-party source/reference notices, tests,
conversion tools, Xcode configuration, CI and packaging scripts. Unpack the
source and run the commands above with the pinned tools. The manifest records
source bytes; this is not a promise of bit-for-bit compiler/signature output.

Distribute the source ZIP with the binary and keep equivalent source access
available at the same release location. This implements the chosen source
access approach for the existing license; [GPLv3 section 6](LICENSE) contains
the governing terms. No commercial terms or relicensing are introduced.

`SHA256SUMS` uses artifact basenames. After downloading the DMG, source ZIP
and checksum file into one directory, run `shasum -a 256 -c SHA256SUMS` there.

The Homebrew cask is an uninstantiated `.rb.in` template, not an installable
draft. Generate a new cask only from the final signed release directory:

```sh
python3 scripts/generate_cask.py /path/to/final-release /path/to/new/mdrivehealth.rb
```

The generator refuses unsigned rehearsals, mismatched DMG/source hashes,
metadata inconsistent with sealed source, missing final readback, and existing
output paths. It derives the OS requirement from the source minimum using a
reviewed Homebrew major-release mapping. It trusts the signing assertion in
`release.sh`'s manifest; generating a cask does not sign, publish, install or
certify runtime compatibility. Inspect it before submitting to a tap. See the
[Homebrew cask requirements](https://docs.brew.sh/Cask-Cookbook#stanza-depends_on).

Before public distribution, run the final app from the final signed DMG on
the declared OS/hardware matrix. Minimum deployment target 14.0 and a universal
binary are build facts, not runtime certification. macOS 14, macOS 15.7 UI,
Intel, external bridges/filesystems, TCC/notifications, power loss and actual
device operations still require their separate acceptance evidence.
Unsigned rehearsal never submits to Apple's notary service or changes trust.

Publish the final DMG/source ZIP and SHA256SUMS together only after those
gates pass. Homebrew metadata must use the final DMG's actual SHA256; no
`:no_check` artifact should be published. Nothing in this script publishes
GitHub releases, changes branch protection or enables billing.
