#!/usr/bin/env python3
"""Native recovery panel/confirmation QA on private 8 KiB fixture files only."""
import argparse, hashlib, json, plistlib, shutil, subprocess
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output-dir',type=Path,required=True);args=parser.parse_args()
    repo=Path(__file__).resolve().parent.parent;out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    if any(out.iterdir()): parser.error('--output-dir must be empty')
    package=out/'MDriveHealthCore'
    shutil.copytree(repo/'Packages/MDriveHealthCore',package,ignore=shutil.ignore_patterns('.build','.swiftpm','.DS_Store'))
    manifest=package/'Package.swift';text=manifest.read_text();anchor='        .testTarget(';assert text.count(anchor)==1
    manifest.write_text(text.replace(anchor,'        .executableTarget(name: "RecoveryNativeFixture", dependencies: ["MDriveHealthCore"]),\n'+anchor))
    target=package/'Sources/RecoveryNativeFixture';target.mkdir()
    models=['ApplicationDelegate','ApplicationLifecycle', 'LoginItemController','BenchmarkRunner','CapacityVerifyRunner','DriveOperations','DriveServices','DriveStore',
            'HealthDisplay','MeasurementServices','MonitoringController','NotificationDelivery','SelfTestController','WorkspaceRecoveryController']
    inputs=[repo/('App/Models/'+name+'.swift') for name in models]
    inputs += [repo/'App/Views/LifecycleStatusView.swift',repo/'App/Views/WorkspaceRecoveryView.swift',repo/'audit/repros/WorkspaceRecoveryNativeFixture.swift']
    for source in inputs: shutil.copy2(source,target/source.name)
    with (out/'build.log').open('w') as log:
        subprocess.run(['swift','build','--package-path',str(package),'--product','RecoveryNativeFixture'],stdout=log,stderr=subprocess.STDOUT,check=True)
    build=Path(subprocess.check_output(['swift','build','--package-path',str(package),'--show-bin-path'],text=True).strip())
    app=out/'RecoveryNativeFixture.app';exe=app/'Contents/MacOS/RecoveryNativeFixture';resources=app/'Contents/Resources';exe.parent.mkdir(parents=True);resources.mkdir()
    shutil.copy2(build/'RecoveryNativeFixture',exe)
    for bundle in build.glob('*.bundle'): shutil.copytree(bundle,resources/bundle.name)
    metadata=dict(CFBundleExecutable='RecoveryNativeFixture',CFBundleIdentifier='com.maclife.mdrivehealth.recovery-native-fixture',CFBundlePackageType='APPL',
                  CFBundleName='Recovery fixture',CFBundleDevelopmentRegion='vi',LSUIElement=True,NSHighResolutionCapable=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
    catalog=repo/'App/Localizable.xcstrings';inputs.append(catalog)
    with (out/'localization.log').open('w') as log:
        subprocess.run(['xcrun','xcstringstool','compile',str(catalog),'--output-directory',str(resources)],stdout=log,stderr=subprocess.STDOUT,check=True)
    results=[]
    for language in ['vi','en']:
        for mode in ['mixed','confirmation','offline','partial','cleaned']:
            run=out/(language+'-'+mode);run.mkdir()
            with (run/'native.log').open('w') as log:
                result=subprocess.run([str(exe),str(run),mode,'-AppleLanguages','('+language+')'],stdout=log,stderr=subprocess.STDOUT,timeout=20)
            assert result.returncode==0,(language,mode,result.returncode)
            proof=json.loads((run/'proof.json').read_text());assert proof['preferredLocalizations'][0]==language
            assert proof['outsideSentinelPreserved'] and proof['legacyDataPreserved'] and proof['realHardwareMutations']==proof['notificationSDKCalls']==0
            if mode=='cleaned': assert not proof['ownedDataExistsAfter'] and proof['cleanupCalls']==1 and proof['leftoverCount']==0 and proof['complete']
            elif mode=='confirmation' and proof['nativeButtonClicked']: assert not proof['ownedDataExistsAfter'] and proof['cleanupCalls']==1
            else: assert proof['ownedDataExistsAfter'] and proof['cleanupCalls']==0
            if mode=='offline': assert not proof['attached'] and not proof['isCurrent']
            if mode=='partial': assert not proof['complete']
            results.append(dict(language=language,**proof))
    summary=dict(nativeRuns=results,fixtureFileBytes=8192,actualPrivateFilesystemOwnership=True,
                 limitations=['Fake hardware provider calls the internal fixture recovery seam; no production instance/hardware mutation.',
                              'Native confirm button invoked only where an actual NSButton bridge is available; inspect proof before claiming coverage.'],
                 inputSHA256={str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},executableSHA256=hashlib.sha256(exe.read_bytes()).hexdigest())
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(nativeRuns=len(results),nativeConfirmButtonRuns=sum(x['nativeButtonClicked'] for x in results),result='passed')))

if __name__=='__main__': main()
