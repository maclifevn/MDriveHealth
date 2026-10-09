#!/usr/bin/env python3
"""Snapshot corresponding source and verify release artifacts. GPL-3.0-or-later."""
import argparse, hashlib, json, os, plistlib, re, shutil, stat, subprocess, tempfile, zipfile
from pathlib import Path

ROOT_FILES = ['LICENSE', 'NOTICE.txt', 'README.md', 'RELEASE.md', 'project.yml', '.gitignore']
ROOT_DIRS = ['App', 'AppTests', 'Packages', 'Config', 'third_party', 'tools', 'scripts', 'packaging', '.github']
EXCLUDED = {'.build', '.swiftpm', '.DS_Store', 'xcuserdata', '__pycache__'}

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def run(*args): return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()

def write_checksums(directory, artifacts):
    """Portable basenames so the release can be verified after download/move."""
    names = set(); lines = []
    for path in artifacts:
        if path.parent.resolve() != directory.resolve() or not re.fullmatch(r'[A-Za-z0-9._-]+', path.name) or path.name in names:
            raise ValueError('Unsafe or duplicate checksum artifact name')
        if not stat.S_ISREG(path.lstat().st_mode): raise ValueError('Checksum artifact must be a regular file')
        names.add(path.name); lines.append(digest(path) + '  ' + path.name + '\n')
    if not lines: raise ValueError('No checksum artifacts')
    with (directory / 'SHA256SUMS').open('x') as file: file.writelines(lines)

def version(root):
    text = (root / 'Config/Version.xcconfig').read_text(); values = {}
    for key in ['MARKETING_VERSION', 'CURRENT_PROJECT_VERSION', 'MACOSX_DEPLOYMENT_TARGET']:
        matches = re.findall(r'^' + key + r'\s*=\s*([^\s/]+)\s*$', text, re.M)
        if len(matches) != 1: raise ValueError('Missing/duplicate version field: ' + key)
        values[key] = matches[0]
    if not re.fullmatch(r'\d+\.\d+\.\d+', values['MARKETING_VERSION']): raise ValueError('Expected stable x.y.z release version')
    if not re.fullmatch(r'[1-9]\d*', values['CURRENT_PROJECT_VERSION']): raise ValueError('Invalid build number')
    if not re.fullmatch(r'\d+\.\d+', values['MACOSX_DEPLOYMENT_TARGET']): raise ValueError('Invalid minimum macOS')
    return values

def source_files(root, generated=False):
    paths = [root / name for name in ROOT_FILES]
    def files(folder):
        for parent, directories, names in os.walk(folder, followlinks=False):
            directories[:] = [name for name in directories if name not in EXCLUDED]
            for name in directories + names:
                path = Path(parent) / name
                if name in EXCLUDED: continue
                if path.is_symlink(): raise ValueError('Source symlink is not allowed: ' + str(path.relative_to(root)))
            yield from (Path(parent) / name for name in names if name not in EXCLUDED)
    for name in ROOT_DIRS + (['MDriveHealth.xcodeproj'] if generated else []):
        folder = root / name
        if not folder.is_dir() or folder.is_symlink(): raise ValueError('Missing/unsafe source directory: ' + name)
        paths.extend(files(folder))
    audit = root / 'audit'
    if audit.is_dir():
        paths += list(audit.glob('*.py'))
        if (audit / 'repros').is_symlink(): raise ValueError('Unsafe audit repro directory')
        if (audit / 'repros').is_dir(): paths.extend(files(audit / 'repros'))
    for path in paths:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1: raise ValueError('Unsafe source file: ' + str(path))
    return sorted(set(paths))

def hashes(root, generated=True): return {str(p.relative_to(root)): digest(p) for p in source_files(root, generated)}

def snapshot(repo, destination):
    if destination.exists(): raise ValueError('Snapshot destination already exists')
    paths = source_files(repo); destination.mkdir(parents=True, mode=0o700)
    for source in paths:
        target = destination / source.relative_to(repo); target.parent.mkdir(parents=True, exist_ok=True); shutil.copy2(source, target)
    version(destination)
    print(json.dumps({'snapshot': str(destination), 'files': len(paths)}))

def toolchain(root, output):
    expected = json.loads((root / 'Config/ReleaseToolchain.json').read_text()); xcode = run('xcodebuild', '-version').splitlines()
    actual = {'xcodeVersion': xcode[0].removeprefix('Xcode '), 'xcodeBuild': xcode[1].removeprefix('Build version '),
              'macOSSDK': run('xcrun', '--sdk', 'macosx', '--show-sdk-version'), 'xcodeGenVersion': run('xcodegen', '--version').removeprefix('Version: ')}
    if actual != expected: raise ValueError('Release toolchain mismatch: ' + json.dumps({'expected': expected, 'actual': actual}))
    actual.update(swift=run('xcrun', 'swift', '--version'), developerDirectory=run('xcode-select', '-p'), host=run('sw_vers'))
    output.write_text(json.dumps(actual, indent=2) + '\n'); return actual

def seal(root, archive):
    if archive.exists(): raise ValueError('Source archive already exists')
    values = version(root)
    manifest = {'version': values['MARKETING_VERSION'], 'build': values['CURRENT_PROJECT_VERSION'], 'minimumMacOS': values['MACOSX_DEPLOYMENT_TARGET'], 'files': hashes(root)}
    source_manifest = root / 'SOURCE_MANIFEST.json'; source_manifest.write_text(json.dumps(manifest, sort_keys=True, indent=2) + '\n')
    prefix = 'MDriveHealth-' + manifest['version'] + '-source/'
    with zipfile.ZipFile(archive, 'w', compression=zipfile.ZIP_DEFLATED) as container:
        for path in source_files(root, generated=True) + [source_manifest]:
            entry = zipfile.ZipInfo(prefix + str(path.relative_to(root)), date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED; entry.external_attr = (stat.S_IFREG | (path.stat().st_mode & 0o777)) << 16
            container.writestr(entry, path.read_bytes())
    verify_source(archive)
    print(json.dumps({'sourceArchive': str(archive), 'sha256': digest(archive), 'files': len(manifest['files'])}))

def verify_source(archive, root=None):
    with zipfile.ZipFile(archive) as container:
        entries = container.infolist()
        if len(entries) > 4000 or sum(e.file_size for e in entries) > 64 << 20: raise ValueError('Source archive exceeds budget')
        names = [entry.filename for entry in entries]
        if len(set(names)) != len(names): raise ValueError('Duplicate source entry')
        manifests = [name for name in names if name.endswith('/SOURCE_MANIFEST.json')]
        if len(manifests) != 1: raise ValueError('Missing/duplicate source manifest')
        prefix = manifests[0].removesuffix('SOURCE_MANIFEST.json')
        for entry in entries:
            path = Path(entry.filename)
            if not entry.filename.startswith(prefix) or path.is_absolute() or '..' in path.parts or not stat.S_ISREG(entry.external_attr >> 16): raise ValueError('Unsafe source archive entry')
        manifest = json.loads(container.read(manifests[0]))
        if not isinstance(manifest, dict) or set(manifest) != {'version', 'build', 'minimumMacOS', 'files'}: raise ValueError('Invalid source manifest schema')
        if not isinstance(manifest['version'], str) or not re.fullmatch(r'\d+\.\d+\.\d+', manifest['version']): raise ValueError('Invalid manifest version')
        if not isinstance(manifest['build'], str) or not re.fullmatch(r'[1-9]\d*', manifest['build']): raise ValueError('Invalid manifest build')
        if not isinstance(manifest['minimumMacOS'], str) or not re.fullmatch(r'\d+\.\d+', manifest['minimumMacOS']): raise ValueError('Invalid manifest minimum OS')
        if prefix != 'MDriveHealth-' + manifest['version'] + '-source/': raise ValueError('Invalid archive root')
        if not isinstance(manifest['files'], dict): raise ValueError('Invalid source file map')
        for name, checksum in manifest['files'].items():
            if not isinstance(name, str) or not name or str(Path(name)) != name or Path(name).is_absolute() or '..' in Path(name).parts or '\\' in name: raise ValueError('Invalid manifest path')
            if not isinstance(checksum, str) or not re.fullmatch(r'[a-f0-9]{64}', checksum): raise ValueError('Invalid source checksum')
        expected = {prefix + name for name in manifest['files']} | {manifests[0]}
        if set(names) != expected: raise ValueError('Source archive does not match manifest entries')
        for name, checksum in manifest['files'].items():
            if hashlib.sha256(container.read(prefix + name)).hexdigest() != checksum: raise ValueError('Source checksum mismatch: ' + name)
        for required in ['LICENSE', 'NOTICE.txt', 'third_party/COPYING.smartmontools', 'third_party/drivedb.h', 'scripts/release.sh', 'Config/Version.xcconfig', 'project.yml']:
            if required not in manifest['files']: raise ValueError('Missing corresponding source: ' + required)
    if root is not None and hashes(root) != manifest['files']: raise ValueError('Source changed after sealing; refusing to package that binary')
    return manifest

def embed(app, archive):
    manifest = verify_source(archive)
    with (app / 'Contents/Info.plist').open('rb') as file: info = plistlib.load(file)
    if (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (manifest['version'], manifest['build']): raise ValueError('App and source versions differ')
    resources = app / 'Contents/Resources'; target = resources / 'CorrespondingSource.zip'
    if target.exists(): raise ValueError('Corresponding source already embedded')
    shutil.copy2(archive, target)
    metadata = {key: manifest[key] for key in ['version', 'build', 'minimumMacOS']}; metadata['sha256'] = digest(archive)
    (resources / 'ReleaseSource.json').write_text(json.dumps(metadata, sort_keys=True, indent=2) + '\n')

def verify_app(app, archive, sdk, output):
    manifest = verify_source(archive); resources = app / 'Contents/Resources'
    if digest(resources / 'CorrespondingSource.zip') != digest(archive): raise ValueError('Embedded source differs from companion archive')
    with zipfile.ZipFile(archive) as container:
        prefix = 'MDriveHealth-' + manifest['version'] + '-source/'
        for name, relative in [('LICENSE', 'LICENSE'), ('NOTICE.txt', 'NOTICE.txt'), ('COPYING.smartmontools', 'third_party/COPYING.smartmontools')]:
            if (resources / name).read_bytes() != container.read(prefix + relative): raise ValueError('Bundle legal text mismatch: ' + name)
    with (app / 'Contents/Info.plist').open('rb') as file: info = plistlib.load(file)
    if info.get('CFBundleIdentifier') != 'com.maclife.MDriveHealth' or (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion')) != (manifest['version'], manifest['build']): raise ValueError('Packaged app identity/version mismatch')
    if info.get('LSMinimumSystemVersion') != manifest['minimumMacOS']: raise ValueError('App minimum OS differs from source configuration')
    metadata = json.loads((resources / 'ReleaseSource.json').read_text())
    if metadata != dict(version=manifest['version'], build=manifest['build'], minimumMacOS=manifest['minimumMacOS'], sha256=digest(archive)): raise ValueError('Source metadata mismatch')
    binaries = {}
    for name in ['MDriveHealth', 'MDriveHealthWorker']:
        binary = app / 'Contents/MacOS' / name; archs = set(run('lipo', '-archs', str(binary)).split())
        if archs != {'arm64', 'x86_64'}: raise ValueError('Expected universal executable: ' + name)
        commands = run('xcrun', 'vtool', '-show-build', str(binary)); minimum = re.findall(r'\bminos\s+([\d.]+)', commands); linked = re.findall(r'\bsdk\s+([\d.]+)', commands)
        if len(minimum) != 2 or set(minimum) != {manifest['minimumMacOS']} or len(linked) != 2 or set(linked) != {sdk}: raise ValueError('Unexpected actual SDK/minimum OS: ' + name)
        binaries[name] = {'sha256': digest(binary), 'architectures': sorted(archs), 'buildCommands': commands}
    magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf'}
    for path in app.rglob('*'):
        if path.is_symlink(): raise ValueError('Unexpected bundle symlink: ' + str(path))
        if path.is_file():
            with path.open('rb') as file: header = file.read(4)
            if header in magic and path.relative_to(app).as_posix() not in ['Contents/MacOS/MDriveHealth', 'Contents/MacOS/MDriveHealthWorker']: raise ValueError('Unexpected nested executable: ' + str(path))
    report = {'version': manifest['version'], 'build': manifest['build'], 'minimumMacOS': manifest['minimumMacOS'], 'sourceSHA256': digest(archive), 'binaries': binaries,
              'runtimeAcceptance': 'UNVERIFIED: structural validation does not prove minimum OS, UI or hardware support'}
    output.write_text(json.dumps(report, indent=2) + '\n'); return report

def verify_dmg(dmg, app, archive, sdk, output):
    """Read back the final disk image; never launch the app or touch user drives."""
    directory = Path(tempfile.mkdtemp(prefix='mdrivehealth-dmg-check-'))
    mount = directory / 'mounted'; mount.mkdir(); attached = False
    try:
        subprocess.check_output(['hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(dmg)], stderr=subprocess.STDOUT)
        attached = True
        report = verify_app(mount / 'MDriveHealth.app', archive, sdk, output)
        def bundle_hashes(root):
            return {str(path.relative_to(root)): digest(path) for path in root.rglob('*') if path.is_file()}
        if bundle_hashes(mount / 'MDriveHealth.app') != bundle_hashes(app): raise ValueError('DMG app differs from verified final app')
        if digest(mount / archive.name) != digest(archive): raise ValueError('DMG source archive differs')
        with zipfile.ZipFile(archive) as container:
            prefix = 'MDriveHealth-' + report['version'] + '-source/'
            for name, source in [('LICENSE','LICENSE'), ('NOTICE.txt','NOTICE.txt'), ('RELEASE.md','RELEASE.md'), ('COPYING.smartmontools','third_party/COPYING.smartmontools')]:
                if (mount / name).read_bytes() != container.read(prefix + source): raise ValueError('DMG documentation differs from source: ' + name)
        if not (mount / 'Applications').is_symlink() or os.readlink(mount / 'Applications') != '/Applications': raise ValueError('Invalid Applications shortcut')
        report['dmgSHA256'] = digest(dmg)
        report['finalDiskImageReadback'] = 'passed'
        output.write_text(json.dumps(report, indent=2) + '\n')
        return report
    finally:
        # rmdir only: a failed unmount preserves the mount for manual inspection.
        if attached or os.path.ismount(mount):
            subprocess.check_output(['hdiutil', 'detach', str(mount)], stderr=subprocess.STDOUT)
        mount.rmdir(); directory.rmdir()

def main():
    parser = argparse.ArgumentParser(description=__doc__); sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('snapshot'); p.add_argument('repo', type=Path); p.add_argument('destination', type=Path)
    p = sub.add_parser('toolchain'); p.add_argument('root', type=Path); p.add_argument('output', type=Path)
    p = sub.add_parser('version'); p.add_argument('root', type=Path)
    p = sub.add_parser('seal'); p.add_argument('root', type=Path); p.add_argument('archive', type=Path)
    p = sub.add_parser('verify-source'); p.add_argument('archive', type=Path); p.add_argument('--root', type=Path)
    p = sub.add_parser('embed'); p.add_argument('app', type=Path); p.add_argument('archive', type=Path)
    p = sub.add_parser('verify-app'); p.add_argument('app', type=Path); p.add_argument('archive', type=Path); p.add_argument('sdk'); p.add_argument('output', type=Path)
    p = sub.add_parser('verify-dmg'); p.add_argument('dmg', type=Path); p.add_argument('app', type=Path); p.add_argument('archive', type=Path); p.add_argument('sdk'); p.add_argument('output', type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'snapshot': snapshot(args.repo.resolve(), args.destination.resolve())
        elif args.command == 'toolchain': toolchain(args.root, args.output)
        elif args.command == 'version': print(version(args.root)['MARKETING_VERSION'])
        elif args.command == 'seal': seal(args.root, args.archive)
        elif args.command == 'verify-source': print(json.dumps(verify_source(args.archive, args.root)))
        elif args.command == 'embed': embed(args.app, args.archive)
        elif args.command == 'verify-app': verify_app(args.app, args.archive, args.sdk, args.output)
        elif args.command == 'verify-dmg': verify_dmg(args.dmg, args.app, args.archive, args.sdk, args.output)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, subprocess.CalledProcessError) as error: parser.exit(1, 'Release validation failed: ' + str(error) + '\n')

if __name__ == '__main__': main()
