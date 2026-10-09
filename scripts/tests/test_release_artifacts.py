"""Distribution-contract regressions using private temporary source/app fixtures."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location('release_artifacts', Path(__file__).parents[1] / 'release_artifacts.py')
r = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(r)

class ReleaseArtifactsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mdrivehealth-packaging-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / 'source'
        self.root.mkdir()
        for name in r.ROOT_FILES:
            (self.root / name).write_text('fixture ' + name)
        for name in r.ROOT_DIRS + ['MDriveHealth.xcodeproj']:
            (self.root / name).mkdir()
            (self.root / name / 'fixture.txt').write_text(name)
        (self.root / 'Config/Version.xcconfig').write_text('MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 4\nMACOSX_DEPLOYMENT_TARGET = 14.0\n')
        (self.root / 'third_party/COPYING.smartmontools').write_text('GPL upstream fixture')
        (self.root / 'third_party/drivedb.h').write_text('corresponding database fixture')
        (self.root / 'scripts/release.sh').write_text('#!/bin/bash\n')
        (self.root / 'scripts/release.sh').chmod(0o755)
        self.archive = self.base / 'source.zip'
        with contextlib.redirect_stdout(io.StringIO()):
            r.seal(self.root, self.archive)
        self.app = self.base / 'MDriveHealth.app'
        self.resources = self.app / 'Contents/Resources'
        self.resources.mkdir(parents=True)
        self.info = dict(CFBundleIdentifier='com.maclife.MDriveHealth', CFBundleShortVersionString='1.2.3', CFBundleVersion='4', LSMinimumSystemVersion='14.0')
        self.write_info()
        for name, source in [('LICENSE','LICENSE'), ('NOTICE.txt','NOTICE.txt'), ('COPYING.smartmontools','third_party/COPYING.smartmontools')]:
            (self.resources / name).write_bytes((self.root / source).read_bytes())
        binaries = self.app / 'Contents/MacOS'
        binaries.mkdir()
        for name in ['MDriveHealth', 'MDriveHealthWorker']:
            (binaries / name).write_bytes(b'\xca\xfe\xba\xbefixture')
        r.embed(self.app, self.archive)

    def write_info(self):
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))

    def verify_app(self):
        def output(*args):
            if args[0] == 'lipo': return 'arm64 x86_64'
            if args[:3] == ('xcrun', 'vtool', '-show-build'): return 'minos 14.0\nsdk 27.0\nminos 14.0\nsdk 27.0'
            raise AssertionError(args)
        with patch.object(r, 'run', side_effect=output):
            return r.verify_app(self.app, self.archive, '27.0', self.base / 'report.json')

    def rewrite_zip(self, transform):
        other = self.base / 'changed.zip'
        with zipfile.ZipFile(self.archive) as original, zipfile.ZipFile(other, 'w') as output:
            for entry in original.infolist():
                data = original.read(entry.filename)
                if entry.filename.endswith('/SOURCE_MANIFEST.json'):
                    data = json.dumps(transform(json.loads(data))).encode()
                output.writestr(entry, data)
        return other

    def test_sealed_archive_and_bundle_agree_but_do_not_certify_runtime(self):
        manifest = r.verify_source(self.archive, self.root)
        self.assertEqual(manifest['version'], '1.2.3')
        with zipfile.ZipFile(self.archive) as container:
            mode = container.getinfo('MDriveHealth-1.2.3-source/scripts/release.sh').external_attr >> 16
            self.assertEqual(stat.S_IMODE(mode), 0o755)
        self.assertIn('UNVERIFIED', self.verify_app()['runtimeAcceptance'])

    def test_changed_source_refuses_existing_archive(self):
        (self.root / 'App/fixture.txt').write_text('changed after build')
        with self.assertRaisesRegex(ValueError, 'changed after sealing'):
            r.verify_source(self.archive, self.root)

    def test_zip_duplicate_entry_rejected(self):
        with zipfile.ZipFile(self.archive, 'a') as container:
            container.writestr('MDriveHealth-1.2.3-source/LICENSE', 'replacement')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            r.verify_source(self.archive)

    def test_zip_path_escape_rejected(self):
        with zipfile.ZipFile(self.archive, 'a') as container:
            entry = zipfile.ZipInfo('MDriveHealth-1.2.3-source/../escape')
            entry.external_attr = (stat.S_IFREG | 0o600) << 16
            container.writestr(entry, 'escape')
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            r.verify_source(self.archive)

    def test_malformed_manifest_types_fail_closed(self):
        for transform in [lambda m: [], lambda m: dict(m, files=[]), lambda m: dict(m, build=4), lambda m: dict(m, version='1.2.3-beta')]:
            with self.subTest(transform=transform):
                with self.assertRaises(ValueError):
                    r.verify_source(self.rewrite_zip(transform))

    def test_manifest_cannot_mislabel_archive_root(self):
        with self.assertRaisesRegex(ValueError, 'archive root'):
            r.verify_source(self.rewrite_zip(lambda m: dict(m, version='2.0.0')))

    def test_archive_checksum_detects_source_tampering(self):
        other = self.base / 'bad-content.zip'
        with zipfile.ZipFile(self.archive) as original, zipfile.ZipFile(other, 'w') as output:
            for entry in original.infolist():
                output.writestr(entry, b'changed' if entry.filename.endswith('/LICENSE') else original.read(entry.filename))
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            r.verify_source(other)

    def test_snapshot_excludes_generated_build_outputs(self):
        build = self.root / 'Packages/.build'
        build.mkdir()
        (build / 'unrelated-secret').write_text('not source')
        os.symlink('/missing', build / 'excluded-link')
        destination = self.base / 'snapshot'
        with contextlib.redirect_stdout(io.StringIO()):
            r.snapshot(self.root, destination)
        self.assertFalse((destination / 'Packages/.build').exists())
        self.assertFalse((destination / 'MDriveHealth.xcodeproj').exists())
        self.assertTrue((destination / 'App/fixture.txt').is_file())

    def test_source_symlink_and_hardlink_rejected(self):
        link = self.root / 'App/link'
        os.symlink('/missing', link)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            r.source_files(self.root)
        link.unlink()
        os.link(self.root / 'LICENSE', link)
        with self.assertRaisesRegex(ValueError, 'Unsafe source file'):
            r.source_files(self.root)

    def test_existing_output_is_preserved(self):
        destination = self.base / 'existing'
        destination.mkdir()
        sentinel = destination / 'sentinel'
        sentinel.write_text('keep')
        with self.assertRaises(ValueError):
            r.snapshot(self.root, destination)
        self.assertEqual(sentinel.read_text(), 'keep')
        before = r.digest(self.archive)
        with self.assertRaises(ValueError):
            r.seal(self.root, self.archive)
        self.assertEqual(r.digest(self.archive), before)

    def test_bundle_version_and_minimum_os_must_match_source(self):
        for field in ['CFBundleShortVersionString', 'CFBundleVersion', 'LSMinimumSystemVersion']:
            with self.subTest(field=field):
                value = self.info[field]
                self.info[field] = '999'
                self.write_info()
                with self.assertRaises(ValueError): self.verify_app()
                self.info[field] = value
        self.write_info()

    def test_embedded_source_and_notices_cannot_differ(self):
        for name in ['CorrespondingSource.zip', 'LICENSE', 'NOTICE.txt', 'COPYING.smartmontools', 'ReleaseSource.json']:
            with self.subTest(name=name):
                path = self.resources / name
                before = path.read_bytes()
                path.write_bytes(b'{}' if name.endswith('.json') else b'changed')
                with self.assertRaises(ValueError): self.verify_app()
                path.write_bytes(before)

    def test_unexpected_executable_and_link_rejected(self):
        path = self.resources / 'unexpected'
        path.write_bytes(b'\xcf\xfa\xed\xfeextra executable')
        with self.assertRaisesRegex(ValueError, 'nested executable'): self.verify_app()
        path.unlink()
        os.symlink('/Applications', path)
        with self.assertRaisesRegex(ValueError, 'symlink'): self.verify_app()

    def test_toolchain_pin_rejects_changed_sdk(self):
        (self.root / 'Config/ReleaseToolchain.json').write_text(json.dumps(dict(xcodeVersion='27.0', xcodeBuild='27A266a', macOSSDK='27.0', xcodeGenVersion='2.46.0')))
        with patch.object(r, 'run', side_effect=['Xcode 27.0\nBuild version 27A266a', '26.0', 'Version: 2.46.0']):
            with self.assertRaisesRegex(ValueError, 'toolchain mismatch'):
                r.toolchain(self.root, self.base / 'tools.json')
        self.assertFalse((self.base / 'tools.json').exists())

if __name__ == '__main__': unittest.main()
