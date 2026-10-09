#!/usr/bin/env python3
"""Same macOS contract checks locally and in CI; private fixtures, no device mutation."""
import argparse, hashlib, json, os, platform, plistlib, re, signal, subprocess, sys
from pathlib import Path
from release_artifacts import source_files, version

ROOT=Path(__file__).resolve().parent.parent
CORE_FILTER='BoundedProcessTests|ProcessStreamingTests|MeasurementWorkerTests|HistoryFaultTests|HistoryAccessTests|MeasurementJournalTests'
APP_STRESS=['DriveOperationTests','MonitoringTests','MeasurementModelTests','MeasurementPersistenceTests','LifecycleTests','UpdateCheckerTests','LoginItemTests','HistoryPublicationTests','TrimMetadataTests','BenchmarkPublicationTests','MenuBarStatusTests']

def capture(*args):return subprocess.check_output(args,text=True,stderr=subprocess.STDOUT).strip()
def validate_toolchain(profile):
    profiles=json.loads((ROOT/'Config/CIToolchains.json').read_text())
    expected=profiles[profile];xcode=capture('xcodebuild','-version').splitlines()
    actual=dict(xcodeVersion=xcode[0].removeprefix('Xcode '),xcodeBuild=xcode[1].removeprefix('Build version '),macOSSDK=capture('xcrun','--sdk','macosx','--show-sdk-version'),xcodeGenVersion=capture('xcodegen','--version').removeprefix('Version: '),macOSMajor=capture('sw_vers','-productVersion').split('.')[0],architecture=platform.machine())
    if any(actual[key]!=expected[key] for key in actual):raise ValueError('CI toolchain/host mismatch: '+json.dumps(dict(expected=expected,actual=actual)))
    return dict(profile=profile,expected=expected,actual=actual,swift=capture('xcrun','swift','--version'),developerDirectory=capture('xcode-select','-p'))

def execute(output, name, command, report, env=None, tests=False, timeout=900):
    print('Running '+name,flush=True)
    log=output/(name+'.log')
    entry=dict(command=command,log=log.name)
    report['checks'][name]=entry
    with log.open('w') as file:
        process=subprocess.Popen(command,cwd=ROOT,env=env,stdout=file,stderr=subprocess.STDOUT,start_new_session=True)
        entry['processID']=process.pid
        try: code=process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            entry['timedOut']=True
            if process.poll() is None:
                os.killpg(process.pid,signal.SIGTERM)
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid,signal.SIGKILL)
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: entry['exitUnconfirmed']=True
            entry['exitCode']=process.returncode
            raise ValueError(name+' exceeded its CI deadline; inspect '+str(log))
    text=log.read_text(errors='replace')
    entry['exitCode']=code
    if tests=='python':
        counts=re.findall(r'Ran (\d+) tests?',text)
        entry['tests']=int(counts[-1]) if counts else 0
        if not entry['tests']:raise ValueError(name+' executed no Python test cases')
    elif tests:
        counts=re.findall(r'Executed (\d+) tests?, with (\d+) failures?',text)
        if not counts or max(int(n) for n,_ in counts)==0:raise ValueError(name+' executed no XCTest cases')
        entry['tests']=max(int(n) for n,_ in counts);entry['failures']=max(int(n) for _,n in counts)
        entry['skips']=[line.strip()[:400] for line in text.splitlines() if re.search(r'Test Case .* skipped|Test skipped -',line)]
        if entry['failures']:raise ValueError(name+' has failing tests')
    if code:raise ValueError(name+' failed; inspect '+str(log))

def run(profile, output, package):
    if output.exists():raise ValueError('CI output already exists; nothing removed')
    output.mkdir(parents=True,mode=0o700)
    report=dict(profile=profile,status='running',checks={},hardwareGates=[dict(name=name,status='not-run',reason='Needs an explicit disposable hardware/OS acceptance run; CI fixtures do not certify it.') for name in ['SMART ATA/NVMe/USB bridges','HDD sleep/wake','disconnect/power-loss/kernel stall','external filesystems','TCC/notifications/signed launch','full UI/VoiceOver/large text','long-running soak']])
    try:
        toolchain=validate_toolchain(profile);report['toolchain']=toolchain
        (output/'toolchain.json').write_text(json.dumps(toolchain,indent=2)+'\n')
        execute(output,'packaging-tests',[sys.executable,'-m','unittest','discover','-s','scripts/tests','-v'],report,tests='python')
        execute(output,'xcodegen',['xcodegen','generate'],report)
        report['sourceSHA256']={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files(ROOT)}
        for configuration in ['debug','release']:
            command=['swift','test','--package-path','Packages/MDriveHealthCore','--scratch-path',str(output/('core-'+configuration+'-build')),'-c',configuration]
            execute(output,'core-'+configuration,command,report,tests=True)
        env=os.environ.copy();env['ASAN_OPTIONS']='detect_leaks=0'
        execute(output,'core-asan',['swift','test','--package-path','Packages/MDriveHealthCore','--scratch-path',str(output/'core-asan-build'),'--sanitize=address'],report,env,True)
        sdk=capture('xcrun','--sdk','macosx','--show-sdk-path')
        for source in sorted((ROOT/'Packages/MDriveHealthCore/Sources/CSMART').glob('*.c')):
            name='analyze-'+source.stem;plist=output/(name+'.plist')
            execute(output,name,['xcrun','clang','--analyze','-Xanalyzer','-analyzer-output=plist','-I',str(source.parent/'include'),'-isysroot',sdk,'-mmacosx-version-min='+version(ROOT)['MACOSX_DEPLOYMENT_TARGET'],str(source),'-o',str(plist)],report)
            diagnostics=plistlib.loads(plist.read_bytes()).get('diagnostics',[])
            report['checks'][name]['diagnostics']=len(diagnostics)
            if diagnostics:raise ValueError(name+' reports analyzer diagnostics')
        for iteration in range(1,4):
            execute(output,'core-stress-'+str(iteration),['swift','test','--package-path','Packages/MDriveHealthCore','--scratch-path',str(output/'core-debug-build'),'--filter',CORE_FILTER],report,tests=True)
        app=['xcodebuild','-project','MDriveHealth.xcodeproj','-scheme','MDriveHealth','-configuration','Debug','-destination','platform=macOS,arch='+platform.machine(),'-parallel-testing-enabled','NO','-derivedDataPath',str(output/'app-derived-data'),'CODE_SIGNING_ALLOWED=NO']
        execute(output,'app-tests',app+['-resultBundlePath',str(output/'app-tests.xcresult'),'test'],report,tests=True)
        for iteration in range(1,4):
            execute(output,'app-stress-'+str(iteration),app+['-resultBundlePath',str(output/('app-stress-'+str(iteration)+'.xcresult'))]+['-only-testing:MDriveHealthModelTests/'+name for name in APP_STRESS]+['test'],report,tests=True)
        if package:
            if profile!='latest-arm64':raise ValueError('Release package requires latest-arm64 and the release pins')
            execute(output,'release-package',['bash','scripts/release.sh','--unsigned',str(output/'release')],report)
            report['releaseManifest']=json.loads((output/'release/release-manifest.json').read_text())
        else:
            execute(output,'universal-build',['xcodebuild','-project','MDriveHealth.xcodeproj','-scheme','MDriveHealth','-configuration','Release','-derivedDataPath',str(output/'universal-derived-data'),'ARCHS=arm64 x86_64','ONLY_ACTIVE_ARCH=NO','CODE_SIGNING_ALLOWED=NO','build'],report)
            binaries={}
            for name in ['MDriveHealth','MDriveHealthWorker']:
                binary=output/'universal-derived-data/Build/Products/Release/MDriveHealth.app/Contents/MacOS'/name
                archs=set(capture('lipo','-archs',str(binary)).split())
                if archs!={'arm64','x86_64'}:raise ValueError('Missing universal binary: '+name)
                commands=capture('xcrun','vtool','-show-build',str(binary))
                if re.findall(r'\bsdk\s+([\d.]+)',commands)!=[toolchain['actual']['macOSSDK']]*2 or re.findall(r'\bminos\s+([\d.]+)',commands)!=[version(ROOT)['MACOSX_DEPLOYMENT_TARGET']]*2:raise ValueError('Unexpected actual SDK/minimum OS: '+name)
                binaries[name]=dict(architectures=sorted(archs),sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),buildCommands=commands)
            report['universalBinaries']=binaries
        after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files(ROOT)}
        if after!=report['sourceSHA256']:raise ValueError('Source changed during CI; results do not certify the current checkout')
        report['sourceUnchangedAfterChecks']=True
        report['status']='passed'
    except BaseException as error:
        report['status']='failed';report['error']=str(error);raise
    finally:
        (output/'ci-results.json').write_text(json.dumps(report,indent=2)+'\n')
    print('CI contract checks passed. Hardware, signed release and UI acceptance remain separate gates.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('profile');parser.add_argument('output',type=Path);parser.add_argument('--package',action='store_true');args=parser.parse_args()
    try:run(args.profile,args.output.resolve(),args.package)
    except (OSError,ValueError,KeyError,subprocess.CalledProcessError) as error:parser.exit(1,'CI validation failed: '+str(error)+'\n')
