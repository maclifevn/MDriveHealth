#!/bin/bash
# Build from a sealed source snapshot. GPL-3.0-or-later. See RELEASE.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY=""
PROFILE=""
if [[ "${1:-}" == "--unsigned" ]]; then
  shift
elif [[ "${1:-}" == "--help" ]]; then
  echo 'Usage: release.sh --unsigned [new-output-directory]'
  echo '       release.sh "Developer ID Application: Name (TEAMID)" [notary-profile] [new-output-directory]'
  exit 0
else
  IDENTITY="${1:?Use --unsigned or supply a Developer ID Application identity.}"
  [[ "$IDENTITY" == 'Developer ID Application: '* ]] || { echo 'Expected a Developer ID Application identity.' >&2; exit 2; }
  PROFILE="${2:-mdrivehealth}"
  shift
  if [[ $# -gt 0 ]]; then shift; fi
fi
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2; exit 2; }
VERSION=$(python3 "$ROOT/scripts/release_artifacts.py" version "$ROOT")
if [[ $# -eq 1 ]]; then
  [[ ! -e "$1" ]] || { echo 'Output directory already exists; nothing was removed.' >&2; exit 2; }
  mkdir -m 700 -p "$1"
  DIST="$(cd "$1" && pwd)"
else
  mkdir -p "$ROOT/dist"
  DIST=$(mktemp -d "$ROOT/dist/release-$VERSION-XXXXXX")
fi

echo "Release work directory: $DIST"
python3 "$ROOT/scripts/release_artifacts.py" snapshot "$ROOT" "$DIST/source"
cd "$DIST/source"
python3 scripts/release_artifacts.py toolchain . "$DIST/toolchain.json"
xcodegen generate > "$DIST/xcodegen.log" 2>&1
SOURCE_PACKAGES="$DIST/source-packages"
xcodebuild -resolvePackageDependencies -project MDriveHealth.xcodeproj -scheme MDriveHealth \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" > "$DIST/package-resolution.log" 2>&1
python3 -m unittest discover -s scripts/tests -v > "$DIST/packaging-tests.log" 2>&1
SOURCE="$DIST/MDriveHealth-$VERSION-source.zip"
python3 scripts/release_artifacts.py seal . "$SOURCE"
echo 'Running Core and app model tests from the sealed snapshot.'
swift test --package-path Packages/MDriveHealthCore > "$DIST/core-tests.log" 2>&1
xcodebuild -project MDriveHealth.xcodeproj -scheme MDriveHealth -configuration Debug \
  -derivedDataPath "$DIST/test-derived-data" -resultBundlePath "$DIST/app-tests.xcresult" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  CODE_SIGNING_ALLOWED=NO test > "$DIST/app-tests.log" 2>&1
echo 'Archiving universal Release with the pinned, actual SDK.'
xcodebuild -project MDriveHealth.xcodeproj -scheme MDriveHealth -configuration Release \
  -archivePath "$DIST/MDriveHealth.xcarchive" -derivedDataPath "$DIST/archive-derived-data" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO archive > "$DIST/archive.log" 2>&1
python3 scripts/release_artifacts.py verify-source "$SOURCE" --root . > "$DIST/source-verified.json"
APP="$DIST/MDriveHealth.app"
ditto "$DIST/MDriveHealth.xcarchive/Products/Applications/MDriveHealth.app" "$APP"
python3 scripts/release_artifacts.py embed "$APP" "$SOURCE"
SDK=$(python3 -c 'import json; print(json.load(open("Config/ReleaseToolchain.json"))["macOSSDK"])')
python3 scripts/release_artifacts.py verify-app "$APP" "$SOURCE" "$SDK" "$DIST/app-before-signing.json"
if [[ -n "$IDENTITY" ]]; then
  echo 'Signing Sparkle, measurement helper, then app; verifying nested signatures.'
  python3 scripts/release_artifacts.py sign-sparkle "$APP" "$IDENTITY"
  codesign --force --sign "$IDENTITY" --timestamp --options runtime --identifier com.maclife.MDriveHealth.worker "$APP/Contents/MacOS/MDriveHealthWorker"
  codesign --force --sign "$IDENTITY" --timestamp --options runtime "$APP"
  codesign --verify --deep --strict --verbose=4 "$APP" > "$DIST/signature-verification.log" 2>&1
  codesign --display --verbose=4 "$APP" > "$DIST/app-signature.log" 2>&1
  codesign --display --verbose=4 "$APP/Contents/MacOS/MDriveHealthWorker" > "$DIST/worker-signature.log" 2>&1
  ditto -c -k --keepParent "$APP" "$DIST/MDriveHealth-notary.zip"
  xcrun notarytool submit "$DIST/MDriveHealth-notary.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$DIST/app-notary.json"
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="Accepted" else 1)' "$DIST/app-notary.json"
  xcrun stapler staple "$APP" > "$DIST/app-staple.log" 2>&1
  xcrun stapler validate "$APP" > "$DIST/app-staple-validation.log" 2>&1
fi
python3 scripts/release_artifacts.py verify-app "$APP" "$SOURCE" "$SDK" "$DIST/app-final.json"
STAGE="$DIST/dmg-stage"
mkdir "$STAGE"
ditto "$APP" "$STAGE/MDriveHealth.app"
cp "$SOURCE" "$STAGE/"
cp LICENSE NOTICE.txt RELEASE.md "$STAGE/"
cp third_party/COPYING.smartmontools "$STAGE/"
cp "$DIST/toolchain.json" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
SUFFIX=""
if [[ -z "$IDENTITY" ]]; then SUFFIX='-UNSIGNED'; fi
DMG="$DIST/MDriveHealth-$VERSION$SUFFIX.dmg"
hdiutil create -volname "MDriveHealth $VERSION$SUFFIX" -srcfolder "$STAGE" -format UDZO "$DMG" > "$DIST/dmg-create.log" 2>&1
hdiutil verify "$DMG" > "$DIST/dmg-verify.log" 2>&1
if [[ -n "$IDENTITY" ]]; then
  codesign --sign "$IDENTITY" --timestamp "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$DIST/dmg-notary.json"
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])).get("status")=="Accepted" else 1)' "$DIST/dmg-notary.json"
  xcrun stapler staple "$DMG" > "$DIST/dmg-staple.log" 2>&1
  xcrun stapler validate "$DMG" > "$DIST/dmg-staple-validation.log" 2>&1
  spctl --assess --type execute --verbose=4 "$APP" > "$DIST/gatekeeper-app.log" 2>&1
  spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG" > "$DIST/gatekeeper-dmg.log" 2>&1
fi
python3 scripts/release_artifacts.py verify-dmg "$DMG" "$APP" "$SOURCE" "$SDK" "$DIST/dmg-readback.json"
if [[ -n "$IDENTITY" ]]; then
  python3 scripts/sparkle_appcast.py "$DMG" "$APP" "$DIST/sparkle" \
    --tools-dir "$SOURCE_PACKAGES/artifacts/sparkle/Sparkle/bin" > "$DIST/sparkle-appcast.log" 2>&1
  cp "$DIST/sparkle/appcast.xml" "$DIST/appcast.xml"
fi
python3 - "$DIST" "$DMG" "$SOURCE" "$IDENTITY" <<'PY'
import hashlib, json, pathlib, sys
from scripts.release_artifacts import write_checksums
directory, dmg, source = map(pathlib.Path, sys.argv[1:4])
report = json.loads((directory / 'dmg-readback.json').read_text())
report['distribution'] = 'signed-notarized' if sys.argv[4] else 'unsigned-rehearsal'
artifacts = [dmg, source] + ([directory / 'appcast.xml'] if (directory / 'appcast.xml').is_file() else [])
report['artifacts'] = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts}
report['toolchain'] = json.loads((directory / 'toolchain.json').read_text())
write_checksums(directory, artifacts)
(directory / 'release-manifest.json').write_text(json.dumps(report, indent=2) + '\n')
PY
echo "Artifacts: $DMG and $SOURCE"
echo 'Packaging checks passed. Runtime acceptance on supported OS/hardware remains a separate release gate.'
