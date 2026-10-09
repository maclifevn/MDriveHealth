#!/usr/bin/env python3
"""Render shared login controls with fake SDK status in EN/VI, light/dark."""
import argparse, hashlib, json, plistlib, subprocess
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__); parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args(); root=Path(__file__).resolve().parents[2]; out=args.output_dir.resolve(); out.mkdir(mode=0o700,parents=True,exist_ok=False)
    app=out/'LoginItemNativeFixture.app'; executable=app/'Contents/MacOS/LoginItemNativeFixture'; resources=app/'Contents/Resources'
    executable.parent.mkdir(parents=True); resources.mkdir()
    inputs=[root/name for name in ['App/Models/LoginItemController.swift','App/Views/LoginItemControl.swift','App/Views/OnboardingView.swift','audit/repros/LoginItemNativeFixture.swift']]
    with (out/'build.log').open('w') as log:
        subprocess.run(['xcrun','swiftc','-parse-as-library','-target','arm64-apple-macos14.0',*map(str,inputs),'-o',str(executable)],stdout=log,stderr=subprocess.STDOUT,check=True)
    metadata=dict(CFBundleExecutable='LoginItemNativeFixture',CFBundleIdentifier='com.maclife.mdrivehealth.login-native-fixture',CFBundlePackageType='APPL',CFBundleName='LoginItemNativeFixture',CFBundleDevelopmentRegion='vi',LSUIElement=True,NSHighResolutionCapable=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(metadata)); inputs.append(root/'App/Localizable.xcstrings')
    with (out/'localization.log').open('w') as log:
        subprocess.run(['xcrun','xcstringstool','compile',str(inputs[-1]),'--output-directory',str(resources)],stdout=log,stderr=subprocess.STDOUT,check=True)
    results=[]
    for language in ['vi','en']:
        for appearance in ['light','dark']:
            for mode in ['off','enabled','approval','error','notFound','busy']:
                folder=out/f'{language}-{appearance}-{mode}'; folder.mkdir()
                with (folder/'native.log').open('w') as log:
                    subprocess.run([str(executable),str(folder),mode,appearance,'-AppleLanguages','('+language+')'],stdout=log,stderr=subprocess.STDOUT,timeout=20,check=True)
                proof=json.loads((folder/'proof.json').read_text())
                assert proof['realServiceManagementMutations']==proof['realSystemSettingsOpens']==0 and proof['settingsOpens']==0
                assert proof['preferredLocalizations'][0]==language
                assert proof['isRequested']==(mode in ['enabled','approval'])
                assert proof['isBusy']==(mode=='busy')
                assert bool(proof['error'])==(mode=='error')
                results.append(dict(language=language,appearance=appearance,**proof))
    summary=dict(runs=results,inputSHA256={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},limitations=['Actual view rendering with fake provider; native tour interactions are recorded separately. No real login-item registration, approval, System Settings, signed launch or VoiceOver certification.'])
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(nativeRenders=len(results),status='passed')))

if __name__=='__main__': main()
