#!/usr/bin/env python3
"""Generate a cask from final signed release output, without publishing. GPL-3.0-or-later."""
import argparse, json, re, stat, zipfile
from pathlib import Path
from release_artifacts import digest, verify_source

TEMPLATE = Path(__file__).resolve().parents[1] / 'packaging/homebrew-cask/mdrivehealth.rb.in'
# Homebrew expresses minimum OS as major-release symbols. Do not round down
# an unknown or minor-release minimum; add a reviewed mapping when changing it.
MACOS_SYMBOLS = {'14.0': 'sonoma', '15.0': 'sequoia'}

def generate(directory, output):
    manifest_path = directory / 'release-manifest.json'
    if manifest_path.stat().st_size > 1024 * 1024: raise ValueError('Release manifest too large')
    manifest = json.loads(manifest_path.read_text())
    if not isinstance(manifest, dict): raise ValueError('Release manifest must be an object')
    if manifest.get('distribution') != 'signed-notarized': raise ValueError('Cask requires a signed-notarized release; unsigned rehearsal refused')
    version = manifest.get('version')
    if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version): raise ValueError('Invalid release version')
    dmg = directory / f'MDriveHealth-{version}.dmg'
    source = directory / f'MDriveHealth-{version}-source.zip'
    artifacts = [dmg, source]
    declared = manifest.get('artifacts')
    if isinstance(declared, dict) and 'appcast.xml' in declared:
        artifacts.append(directory / 'appcast.xml')
    for artifact in artifacts:
        info = artifact.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1: raise ValueError('Artifact must be a regular, unlinked file')
    actual = {p.name: digest(p) for p in artifacts}
    if manifest.get('artifacts') != actual: raise ValueError('Final artifact checksum mismatch')
    if manifest.get('dmgSHA256') != actual[dmg.name] or manifest.get('sourceSHA256') != actual[source.name]: raise ValueError('Readback checksum mismatch')
    if manifest.get('finalDiskImageReadback') != 'passed': raise ValueError('Final DMG readback is required')
    sealed = verify_source(source)
    if (manifest.get('version'), manifest.get('build'), manifest.get('minimumMacOS')) != (sealed['version'], sealed['build'], sealed['minimumMacOS']): raise ValueError('Release metadata differs from sealed source')
    minimum = sealed['minimumMacOS']
    if minimum not in MACOS_SYMBOLS: raise ValueError('Minimum OS requires a reviewed Homebrew mapping: ' + minimum)
    text = TEMPLATE.read_text()
    for marker, value in [('@VERSION@', version), ('@SHA256@', actual[dmg.name]), ('@MACOS_SYMBOL@', MACOS_SYMBOLS[minimum])]:
        if text.count(marker) != 1: raise ValueError('Invalid cask template marker: ' + marker)
        text = text.replace(marker, value)
    # The signing assertion is provided by release.sh, which writes its
    # manifest only after notarization, staple and Gatekeeper checks succeed.
    # This generator verifies artifact integrity; it is not a signing service.
    with output.open('x') as file: file.write(text)
    return text

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('release_directory', type=Path)
    parser.add_argument('new_cask_path', type=Path)
    args = parser.parse_args()
    try: generate(args.release_directory, args.new_cask_path)
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error: parser.exit(1, 'Cask generation refused: ' + str(error) + '\n')

if __name__ == '__main__': main()
