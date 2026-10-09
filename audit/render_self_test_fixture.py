#!/usr/bin/env python3
"""Render actual self-test UI with synthetic providers and compiled app localization."""
import argparse
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    parser.add_argument('--app', type=Path, required=True, help='Built app: localization resources only')
    parser.add_argument('--language', choices=['vi', 'en'], default='vi')
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output-dir must be empty')
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='mdrivehealth-self-test-render-') as temporary:
        package = Path(temporary) / 'MDriveHealthCore'
        shutil.copytree(repo / 'Packages/MDriveHealthCore', package, ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
        manifest = package / 'Package.swift'
        source = manifest.read_text()
        anchor = '        .testTarget('
        if source.count(anchor) != 1:
            parser.error('Package.swift changed; review target injection')
        manifest.write_text(source.replace(anchor, '        .executableTarget(name: "SelfTestFixture", dependencies: ["MDriveHealthCore"]),\n' + anchor))
        target = package / 'Sources/SelfTestFixture'
        target.mkdir()
        for name in ['DriveStore', 'DriveOperations', 'DriveServices', 'SelfTestController']:
            shutil.copy2(repo / f'App/Models/{name}.swift', target)
        shutil.copy2(repo / 'App/Views/SelfTestTab.swift', target)
        shutil.copy2(repo / 'audit/repros/RenderSelfTestFixture.swift', target)
        subprocess.run(['swift', 'build', '--package-path', str(package), '--product', 'SelfTestFixture'], check=True)
        bindir = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '--show-bin-path'], text=True).strip())
        bundle = Path(temporary) / 'SelfTestFixture.app/Contents'
        (bundle / 'MacOS').mkdir(parents=True)
        (bundle / 'Resources').mkdir()
        shutil.copy2(bindir / 'SelfTestFixture', bundle / 'MacOS')
        for language in ['vi', 'en']:
            shutil.copytree(args.app / 'Contents/Resources' / (language + '.lproj'), bundle / 'Resources' / (language + '.lproj'))
        with (bundle / 'Info.plist').open('wb') as stream:
            plistlib.dump({'CFBundleIdentifier': 'com.maclife.audit.self-test-fixture', 'CFBundleExecutable': 'SelfTestFixture',
                          'CFBundleDevelopmentRegion': 'vi', 'CFBundleLocalizations': ['vi', 'en']}, stream)
        subprocess.run([str(bundle / 'MacOS/SelfTestFixture'), str(output), '-AppleLanguages', '(' + args.language + ')',
                        '-AppleLocale', 'vi_VN' if args.language == 'vi' else 'en_US'], check=True)
    print('Synthetic self-test UI:', output)


if __name__ == '__main__':
    main()
