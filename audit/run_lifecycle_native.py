#!/usr/bin/env python3
"""Build/run native shutdown UI fixtures using copied app models and disposable data."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error('--output-dir must be empty')
    package = output / 'MDriveHealthCore'
    shutil.copytree(repo / 'Packages/MDriveHealthCore', package,
                    ignore=shutil.ignore_patterns('.build', '.swiftpm', '.DS_Store'))
    manifest = package / 'Package.swift'
    text = manifest.read_text()
    anchor = '        .testTarget('
    assert text.count(anchor) == 1
    manifest.write_text(text.replace(anchor, '        .executableTarget(name: "LifecycleNativeFixture", dependencies: ["MDriveHealthCore"]),\n' + anchor))
    target = package / 'Sources/LifecycleNativeFixture'
    target.mkdir()
    models = ['ApplicationDelegate', 'ApplicationLifecycle', 'LoginItemController', 'BenchmarkRunner', 'CapacityVerifyRunner', 'DriveOperations',
              'DriveServices', 'DriveStore', 'HealthDisplay', 'MeasurementServices', 'MonitoringController', 'NotificationDelivery', 'SelfTestController', 'WorkspaceRecoveryController']
    inputs = [repo / 'audit/repros/LifecycleNativeFixture.swift', repo / 'App/Views/LifecycleStatusView.swift', repo / 'App/Localizable.xcstrings']
    inputs += [repo / ('App/Models/' + model + '.swift') for model in models]
    for source in inputs[:2] + inputs[3:]:
        shutil.copy2(source, target / source.name)
    with (output / 'build.log').open('w') as log:
        subprocess.run(['swift', 'build', '--package-path', str(package), '--product', 'LifecycleNativeFixture'], stdout=log, stderr=subprocess.STDOUT, check=True)
    build = Path(subprocess.check_output(['swift', 'build', '--package-path', str(package), '--show-bin-path'], text=True).strip())
    app = output / 'LifecycleNativeFixture.app'
    executable = app / 'Contents/MacOS/LifecycleNativeFixture'
    resources = app / 'Contents/Resources'
    executable.parent.mkdir(parents=True); resources.mkdir()
    shutil.copy2(build / 'LifecycleNativeFixture', executable)
    for bundle in build.glob('*.bundle'):
        shutil.copytree(bundle, resources / bundle.name)
    metadata = dict(CFBundleExecutable='LifecycleNativeFixture', CFBundleIdentifier='com.maclife.mdrivehealth.lifecycle-native-fixture',
                    CFBundlePackageType='APPL', CFBundleName='Lifecycle fixture', CFBundleDevelopmentRegion='vi',
                    CFBundleLocalizations=['vi', 'en'], LSUIElement=True, NSHighResolutionCapable=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
    with (output / 'localization.log').open('w') as log:
        subprocess.run(['xcrun', 'xcstringstool', 'compile', str(inputs[2]), '--output-directory', str(resources)], stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    for language in ['vi', 'en']:
        for mode in ['quit', 'relaunch', 'unsaved', 'cleanup']:
            run = output / (language + '-' + mode); run.mkdir()
            with (run / 'native.log').open('w') as log:
                result = subprocess.run([str(executable), str(run), mode, '-AppleLanguages', '(' + language + ')'], stdout=log, stderr=subprocess.STDOUT, timeout=20)
            assert result.returncode == 0, (language, mode, result.returncode)
            proof = json.loads((run / 'proof.json').read_text())
            assert proof['notificationSDKCalls'] == proof['measurementDataWrites'] == 0
            assert proof['preferredLocalizations'][0] == language
            if mode in ['quit', 'relaunch']:
                assert proof['allowed'] and proof['isReadyAtReply'] and proof['historyClosedAtReply'] and proof['openDatabaseFDsAtReply'] == 0
                assert proof['deviceLeaseHeldDuringCleanup'] and proof['mainActorTicksDuringTerminateLater'] == 8
                assert proof['launchCalls'] == int(mode == 'relaunch')
                if mode == 'relaunch': assert proof['launchedAfterHistoryClosed']
            else:
                assert not proof['allowed'] and proof['retainedAfterResumeAndReset']
            results.append(dict(language=language, **proof))
    summary = dict(nativeAppKitTermination=True, fixtureModes=results,
                   limitations=['Fake measurement cleanup; actual small-file child engine exit covered by separate model tests.',
                                'Relaunch callback is injected; no production app or second real app instance is launched.',
                                'No actual hardware mutation, notification SDK delivery, power loss or physical unplug.'],
                   inputSHA256={str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                   executableSHA256=hashlib.sha256(executable.read_bytes()).hexdigest())
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(nativeRuns=len(results), languages=['vi', 'en'], result='passed')))


if __name__ == '__main__':
    main()
