#!/usr/bin/env python3
"""Build an isolated native update fixture and render actual view states."""
import argparse, hashlib, json, plistlib, subprocess
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args(); root = Path(__file__).resolve().parents[2]; out = args.output_dir.resolve()
    out.mkdir(mode=0o700, parents=True, exist_ok=False)
    app = out / 'UpdateNativeFixture.app'; executable = app / 'Contents/MacOS/UpdateNativeFixture'; resources = app / 'Contents/Resources'
    executable.parent.mkdir(parents=True); resources.mkdir()
    inputs = [root / name for name in ['App/Models/SemanticVersion.swift','App/Models/UpdateChecker.swift','App/Models/UpdateCheckController.swift','App/Views/UpdateCheckView.swift','audit/repros/UpdateNativeFixture.swift']]
    with (out / 'build.log').open('w') as log:
        subprocess.run(['xcrun','swiftc','-parse-as-library','-target','arm64-apple-macos14.0', *map(str,inputs),'-o',str(executable)],stdout=log,stderr=subprocess.STDOUT,check=True)
    metadata = dict(CFBundleExecutable='UpdateNativeFixture', CFBundleIdentifier='com.maclife.mdrivehealth.update-native-fixture', CFBundlePackageType='APPL',
                    CFBundleName='UpdateNativeFixture', CFBundleDevelopmentRegion='vi', LSUIElement=True, NSHighResolutionCapable=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
    inputs.append(root / 'App/Localizable.xcstrings')
    with (out / 'localization.log').open('w') as log:
        subprocess.run(['xcrun','xcstringstool','compile',str(inputs[-1]),'--output-directory',str(resources)],stdout=log,stderr=subprocess.STDOUT,check=True)
    results = []
    for language in ['vi','en']:
        for appearance in ['light','dark']:
            for mode in ['available','page','failed','cancelled','busy']:
                folder = out / f'{language}-{appearance}-{mode}'; folder.mkdir()
                with (folder / 'native.log').open('w') as log:
                    subprocess.run([str(executable),str(folder),mode,appearance,'-AppleLanguages','('+language+')'],stdout=log,stderr=subprocess.STDOUT,timeout=20,check=True)
                proof = json.loads((folder / 'proof.json').read_text())
                assert proof['calls']==1 and proof['networkCalls']==0 and proof['openedURLs']==[] and proof['preferredLocalizations'][0]==language
                results.append(dict(language=language,appearance=appearance,**proof))
    summary = dict(runs=results, inputSHA256={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
                   limitations=['Render/model evidence only; interactive native button checks are recorded separately. No production app, network, browser launch, signing or VoiceOver certification.'])
    (out / 'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(nativeRenders=len(results),status='passed')))

if __name__ == '__main__': main()
