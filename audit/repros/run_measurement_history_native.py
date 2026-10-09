#!/usr/bin/env python3
"""Render the actual history/recovery view in VI/EN and light/dark on private fixtures."""
import argparse, hashlib, json, plistlib, shutil, subprocess
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    out = args.output_dir.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()): parser.error('--output-dir must be empty')
    package = out / 'MDriveHealthCore'
    shutil.copytree(repo / 'Packages/MDriveHealthCore', package, ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
    manifest = package / 'Package.swift'
    source = manifest.read_text()
    anchor = '        .testTarget('
    assert source.count(anchor) == 1
    manifest.write_text(source.replace(anchor, '        .executableTarget(name: "HistoryNativeFixture", dependencies: ["MDriveHealthCore"]),\n' + anchor))
    target = package / 'Sources/HistoryNativeFixture'
    target.mkdir()
    names = ['ApplicationDelegate', 'ApplicationLifecycle', 'LoginItemController', 'BenchmarkRunner', 'CapacityVerifyRunner', 'DriveOperations', 'DriveServices', 'DriveStore',
             'HealthDisplay', 'MeasurementServices', 'MeasurementRecoveryController', 'MonitoringController', 'NotificationDelivery', 'SelfTestController', 'WorkspaceRecoveryController']
    inputs = [repo / ('App/Models/' + name + '.swift') for name in names]
    inputs += [repo / 'App/Views/LifecycleStatusView.swift', repo / 'App/Views/MeasurementHistoryView.swift', repo / 'audit/repros/MeasurementHistoryNativeFixture.swift']
    for path in inputs: shutil.copy2(path, target / path.name)
    with (out / 'build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(package), '--product', 'HistoryNativeFixture'], stdout=log, stderr=subprocess.STDOUT, check=True)
    build = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '--show-bin-path'], text=True).strip())
    app = out / 'HistoryNativeFixture.app'
    executable = app / 'Contents/MacOS/HistoryNativeFixture'
    resources = app / 'Contents/Resources'
    executable.parent.mkdir(parents=True); resources.mkdir()
    shutil.copy2(build / 'HistoryNativeFixture', executable)
    for bundle in build.glob('*.bundle'): shutil.copytree(bundle, resources / bundle.name)
    metadata = dict(CFBundleExecutable='HistoryNativeFixture', CFBundleIdentifier='com.maclife.mdrivehealth.history-native-fixture', CFBundlePackageType='APPL',
                    CFBundleName='History fixture', CFBundleDevelopmentRegion='vi', LSUIElement=True, NSHighResolutionCapable=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
    inputs.append(repo / 'App/Localizable.xcstrings')
    with (out / 'localization.log').open('w') as log:
        subprocess.run(['xcrun', 'xcstringstool', 'compile', str(inputs[-1]), '--output-directory', str(resources)], stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    for language in ['vi', 'en']:
        for appearance in ['light', 'dark']:
            for mode in ['archived', 'interrupted', 'omitted', 'unverified']:
                run = out / (language + '-' + appearance + '-' + mode)
                run.mkdir()
                with (run / 'native.log').open('w') as log:
                    subprocess.run([str(executable), str(run), mode, appearance, '-AppleLanguages', '(' + language + ')'], stdout=log, stderr=subprocess.STDOUT, timeout=20, check=True)
                proof = json.loads((run / 'proof.json').read_text())
                assert proof['preferredLocalizations'][0] == language
                assert proof['outsideSentinelPreserved'] and proof['realHardwareMutations'] == proof['notificationSDKCalls'] == 0
                assert proof['archived'] == (2 if mode == 'archived' else 0 if mode == 'omitted' else 1)
                assert proof['jobs'] == (0 if mode == 'archived' else 1)
                assert proof['reviews'] == (1 if mode == 'interrupted' else 0)
                assert proof['unverified'] == (mode == 'unverified') and proof['omitted'] == (mode == 'omitted')
                results.append(dict(language=language, **proof))
    summary = dict(nativeRuns=results, executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest(),
                   inputSHA256={str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                   limitations=['Rendering and model assertions only; no native button clicks, production app, actual drive, signing/TCC or VoiceOver certification.'])
    (out / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(nativeRuns=len(results), result='passed')))

if __name__ == '__main__': main()
