"""Synthetic packaging contracts; these fixtures do not prove Apple signing."""
import contextlib, io, json, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))
import release_artifacts as r
import generate_cask as c

class CaskGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='mdrivehealth-cask-fixture-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name); self.directory = self.base / 'release'; self.directory.mkdir()
        root = self.base / 'source'; root.mkdir()
        for name in r.ROOT_FILES: (root / name).write_text('synthetic ' + name)
        for name in r.ROOT_DIRS + ['MDriveHealth.xcodeproj']: (root / name).mkdir()
        (root / 'Config/Version.xcconfig').write_text('MARKETING_VERSION = 1.2.3\nCURRENT_PROJECT_VERSION = 4\nMACOSX_DEPLOYMENT_TARGET = 14.0\n')
        for name in ['COPYING.smartmontools', 'drivedb.h']: (root / 'third_party' / name).write_text('synthetic')
        (root / 'scripts/release.sh').write_text('# synthetic')
        self.dmg = self.directory / 'MDriveHealth-1.2.3.dmg'; self.dmg.write_bytes(b'SYNTHETIC NOT A SIGNED DMG')
        self.source = self.directory / 'MDriveHealth-1.2.3-source.zip'
        with contextlib.redirect_stdout(io.StringIO()): r.seal(root, self.source)
        self.manifest = dict(version='1.2.3', build='4', minimumMacOS='14.0', distribution='signed-notarized',
                             finalDiskImageReadback='passed', dmgSHA256=r.digest(self.dmg), sourceSHA256=r.digest(self.source),
                             artifacts={p.name:r.digest(p) for p in [self.dmg, self.source]})
        self.output = self.base / 'mdrivehealth.rb'; self.write_manifest()

    def write_manifest(self): (self.directory / 'release-manifest.json').write_text(json.dumps(self.manifest))

    def test_cask_uses_exact_final_artifact_and_source_metadata(self):
        text = c.generate(self.directory, self.output)
        self.assertIn('version "1.2.3"', text)
        self.assertIn('sha256 "' + r.digest(self.dmg) + '"', text)
        self.assertIn('depends_on macos: :sonoma', text)
        self.assertNotIn('no_check', text); self.assertNotIn('@SHA256@', text)
        subprocess.run(['ruby', '-c', str(self.output)], check=True, capture_output=True)

    def test_unsigned_rehearsal_cannot_generate_cask(self):
        self.manifest['distribution'] = 'unsigned-rehearsal'; self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'unsigned rehearsal refused'): c.generate(self.directory, self.output)
        self.assertFalse(self.output.exists())

    def test_changed_dmg_and_readback_are_rejected(self):
        self.dmg.write_bytes(b'changed after readback')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'): c.generate(self.directory, self.output)
        self.manifest['artifacts'][self.dmg.name] = r.digest(self.dmg); self.write_manifest()
        with self.assertRaisesRegex(ValueError, 'Readback checksum'): c.generate(self.directory, self.output)
        self.assertFalse(self.output.exists())

    def test_manifest_version_build_minimum_and_readback_must_agree(self):
        for key, value in [('build','5'),('minimumMacOS','15.0'),('finalDiskImageReadback','failed'),('version','1.2.3"; system("oops")')]:
            original = self.manifest[key]; self.manifest[key] = value; self.write_manifest()
            with self.subTest(key=key), self.assertRaises(ValueError): c.generate(self.directory, self.output)
            self.assertFalse(self.output.exists()); self.manifest[key] = original

    def test_existing_cask_is_never_overwritten(self):
        self.output.write_text('existing cask')
        with self.assertRaises(FileExistsError): c.generate(self.directory, self.output)
        self.assertEqual(self.output.read_text(), 'existing cask')

    def test_checksums_remain_valid_after_move_and_detect_corruption(self):
        r.write_checksums(self.directory, [self.dmg, self.source])
        downloaded = self.base / 'downloaded'; shutil.copytree(self.directory, downloaded)
        checked = subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=downloaded, capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        self.assertNotIn(str(self.directory), (downloaded / 'SHA256SUMS').read_text())
        (downloaded / self.dmg.name).write_bytes(b'corrupted download')
        self.assertNotEqual(subprocess.run(['shasum', '-a', '256', '-c', 'SHA256SUMS'], cwd=downloaded, capture_output=True).returncode, 0)

    def test_checksum_output_refuses_overwrite_duplicates_and_external_files(self):
        for artifacts in [[], [self.dmg,self.dmg], [self.base / 'outside.dmg']]:
            with self.assertRaises(ValueError): r.write_checksums(self.directory, artifacts)
            self.assertFalse((self.directory / 'SHA256SUMS').exists())
        r.write_checksums(self.directory, [self.dmg]); original = (self.directory / 'SHA256SUMS').read_bytes()
        with self.assertRaises(FileExistsError): r.write_checksums(self.directory, [self.dmg])
        self.assertEqual((self.directory / 'SHA256SUMS').read_bytes(), original)
