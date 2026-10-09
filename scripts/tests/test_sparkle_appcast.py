"""Signed-update publication metadata contract; private fixtures only."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

SCRIPTS = Path(__file__).parents[1]
def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / (name + '.py'))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result
s = module('sparkle_appcast')
r = module('release_artifacts')

class SparkleAppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'MDriveHealth-1.2.3.dmg'; self.archive.write_bytes(b'archive fixture')
        self.info = dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='7', LSMinimumSystemVersion='14.0')
        self.prefix = 'https://github.com/maclifevn/MDriveHealth/releases/download/v1.2.3/'
        self.feed = self.root / 'appcast.xml'
        self.item = ET.SubElement(ET.SubElement(ET.Element('rss'), 'channel'), 'item')
        ET.SubElement(self.item, s.SPARKLE + 'version').text = '7'
        ET.SubElement(self.item, s.SPARKLE + 'shortVersionString').text = '1.2.3'
        ET.SubElement(self.item, s.SPARKLE + 'minimumSystemVersion').text = '14.0'
        self.enclosure = ET.SubElement(self.item, 'enclosure', {'url': self.prefix + self.archive.name,
            'length': str(self.archive.stat().st_size), s.SPARKLE + 'edSignature': 'signature fixture'})
    def write(self):
        root = ET.Element('rss'); channel = ET.SubElement(root, 'channel'); channel.append(self.item)
        ET.ElementTree(root).write(self.feed)
    def validate(self):
        self.write(); return s.validate_feed(self.feed, self.archive, self.info, self.prefix)
    def test_matching_archive_metadata(self):
        self.assertEqual(self.validate(), 'signature fixture')
    def test_unsigned_and_wrong_archive_metadata_rejected(self):
        for key, value in [('url', 'http://attacker.invalid/update.dmg'), ('length', '1'), (s.SPARKLE + 'edSignature', '')]:
            with self.subTest(key=key):
                original = self.enclosure.get(key); self.enclosure.set(key, value)
                with self.assertRaises(ValueError): self.validate()
                self.enclosure.set(key, original)
    def test_mismatched_build_version_or_minimum_rejected(self):
        for key in ['version', 'shortVersionString', 'minimumSystemVersion']:
            field = self.item.find(s.SPARKLE + key); original = field.text; field.text = '999'
            with self.assertRaises(ValueError): self.validate()
            field.text = original
    def test_framework_version_and_safe_symlinks_only(self):
        framework = self.root / 'App.app/Contents/Frameworks/Sparkle.framework'
        resources = framework / 'Versions/B/Resources'; resources.mkdir(parents=True)
        (resources / 'Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.sparkle-project.Sparkle', CFBundleShortVersionString='2.10.0')))
        for name in r.SPARKLE_BINARIES:
            path = framework / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_bytes(b'executable fixture')
        (framework / 'Versions/Current').symlink_to('B')
        (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
        with patch.object(r, 'run', return_value='arm64 x86_64'):
            self.assertEqual(r.verify_sparkle(self.root / 'App.app', {'version':'2.10.0'}), framework)
            with self.assertRaises(ValueError): r.verify_sparkle(self.root / 'App.app', {'version':'999'})
            (framework / 'Resources').symlink_to('/Applications')
            with self.assertRaisesRegex(ValueError, 'symlink'): r.verify_sparkle(self.root / 'App.app', {'version':'2.10.0'})

if __name__ == '__main__': unittest.main()
