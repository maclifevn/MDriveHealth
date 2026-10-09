#!/usr/bin/env python3
"""Build an isolated SwiftUI app with actual full production views and fake services."""
import argparse, hashlib, json, plistlib, shutil, subprocess
from pathlib import Path

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args(); root=Path(__file__).resolve().parents[2]
    out=args.output_dir.resolve(); out.mkdir(mode=0o700,parents=True,exist_ok=False)
    inputs=sorted((root/'App').rglob('*.swift'))+[root/'audit/repros/FullWindowNativeFixture.swift',root/'App/Localizable.xcstrings',Path(__file__).resolve(),root/'LICENSE',root/'NOTICE.txt']
    captured={str(p.relative_to(root)):p.read_bytes() for p in inputs}
    original_hashes={name:hashlib.sha256(data).hexdigest() for name,data in captured.items()}
    core_captured={str(p.relative_to(root)):p.read_bytes() for p in sorted((root/'Packages/MDriveHealthCore/Sources').rglob('*')) if p.is_file()}
    core_hashes={name:hashlib.sha256(data).hexdigest() for name,data in core_captured.items()}
    package_bytes=(root/'Packages/MDriveHealthCore/Package.swift').read_bytes()
    package_hash=hashlib.sha256(package_bytes).hexdigest()
    for name,data in captured.items():
        snapshot=out/'original-inputs'/name;snapshot.parent.mkdir(parents=True,exist_ok=True);snapshot.write_bytes(data)
    package=out/'MDriveHealthCore'
    shutil.copytree(root/'Packages/MDriveHealthCore',package,ignore=shutil.ignore_patterns('.build','.swiftpm','.DS_Store'))
    (package/'Package.swift').write_bytes(package_bytes)
    for name,data in core_captured.items():
        (package/Path(name).relative_to('Packages/MDriveHealthCore')).write_bytes(data)
    manifest=package/'Package.swift'; text=manifest.read_text(); anchor='        .testTarget('
    assert text.count(anchor)==1
    assert text.count('    targets: [')==1
    text=text.replace('    targets: [','    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")],\n    targets: [')
    manifest.write_text(text.replace(anchor,'        .executableTarget(name: "FullWindowNativeFixture", dependencies: ["MDriveHealthCore", .product(name: "Sparkle", package: "Sparkle")]),\n'+anchor))
    target=package/'Sources/FullWindowNativeFixture';target.mkdir()
    for p in [p for p in inputs if p.suffix=='.swift']:
        text=captured[str(p.relative_to(root))].decode('utf-8')
        if p.name=='MDriveHealthApp.swift':
            assert text.count('@main\nstruct MDriveHealthApp: App')==1
            text=text.replace('@main\nstruct MDriveHealthApp: App','struct MDriveHealthApp: App')
        (target/p.name).write_text(text)
    with (out/'build.log').open('w') as log:
        subprocess.run(['swift','build','--package-path',str(package),'--product','FullWindowNativeFixture'],stdout=log,stderr=subprocess.STDOUT,check=True)
    build=Path(subprocess.check_output(['swift','build','--package-path',str(package),'--show-bin-path'],text=True).strip())
    app=out/'FullWindowNativeFixture.app';exe=app/'Contents/MacOS/FullWindowNativeFixture';res=app/'Contents/Resources'
    exe.parent.mkdir(parents=True);res.mkdir();shutil.copy2(build/exe.name,exe)
    frameworks=app/'Contents/Frameworks';frameworks.mkdir()
    sparkle=package/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    subprocess.run(['ditto',str(sparkle),str(frameworks/'Sparkle.framework')],check=True)
    subprocess.run(['install_name_tool','-add_rpath','@executable_path/../Frameworks',str(exe)],check=True)
    subprocess.run(['codesign','--force','--sign','-',str(exe)],check=True)
    for bundle in build.glob('*.bundle'):shutil.copytree(bundle,res/bundle.name)
    metadata=dict(CFBundleExecutable=exe.name,CFBundleIdentifier='com.maclife.mdrivehealth.full-window-fixture',CFBundlePackageType='APPL',CFBundleName='MDriveHealth UI fixture',CFBundleDevelopmentRegion='vi',CFBundleShortVersionString='0.1.2',CFBundleVersion='3',NSHighResolutionCapable=True)
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(metadata))
    with (out/'localization.log').open('w') as log:subprocess.run(['xcrun','xcstringstool','compile',str(out/'original-inputs/App/Localizable.xcstrings'),'--output-directory',str(res)],stdout=log,stderr=subprocess.STDOUT,check=True)
    for name in ['LICENSE','NOTICE.txt']:
        (res/name).write_bytes(captured[name])
    for name,digest in {**original_hashes,**core_hashes,'Packages/MDriveHealthCore/Package.swift':package_hash}.items():
        assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,'Source changed during fixture build: '+name
    (out/'core-input-proof.json').write_text(json.dumps(dict(sourceSHA256=core_hashes,count=len(core_hashes),packageManifestSHA256=package_hash),indent=2)+'\n')
    proof=dict(inputSHA256=original_hashes,executableSHA256=hashlib.sha256(exe.read_bytes()).hexdigest(),inputsCapturedBeforeBuild=True,sourceMatchesCapturedInputsAfterBuild=True,sourceTransformation='Removed only @main from the private copy of MDriveHealthApp.swift; it is compiled but not instantiated. Fixture entry uses production ContentView, SettingsView and MenuBarView with fake services and private stores. Menu-content Window has real SwiftUI routing but does not certify status-item opening/popover dismissal.',limitations=['Local native fixture, not production app/signing/real hardware/notification/ServiceManagement/browser/Finder/VoiceOver acceptance.'])
    (out/'build-proof.json').write_text(json.dumps(proof,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(status='built',app=str(app),inputFiles=len(inputs))))

if __name__=='__main__':main()
