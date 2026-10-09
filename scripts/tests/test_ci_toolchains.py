"""CI may not silently turn a different toolchain/OS/architecture into a green gate."""
import importlib.util
import json
from pathlib import Path
import sys
import os
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).parents[1]))
spec=importlib.util.spec_from_file_location('mdrivehealth_ci',Path(__file__).parents[1]/'ci.py')
ci=importlib.util.module_from_spec(spec);spec.loader.exec_module(ci)

class CIToolchainTests(unittest.TestCase):
    def output(self,*args):
        return {('xcodebuild','-version'):'Xcode 27.0\nBuild version 27A266a',('xcrun','--sdk','macosx','--show-sdk-version'):'27.0',('xcodegen','--version'):'Version: 2.46.0',('sw_vers','-productVersion'):'27.0',('xcrun','swift','--version'):'Swift fixture',('xcode-select','-p'):'/Applications/Xcode.app/Contents/Developer'}[args]
    def test_matching_release_profile_is_recorded(self):
        with patch.object(ci,'capture',side_effect=self.output),patch.object(ci.platform,'machine',return_value='arm64'):
            self.assertEqual(ci.validate_toolchain('latest-arm64')['actual']['macOSSDK'],'27.0')
    def test_sdk_os_architecture_and_compiler_drift_rejected(self):
        for call,value in [(('xcrun','--sdk','macosx','--show-sdk-version'),'26.0'),(('sw_vers','-productVersion'),'26.0'),(('xcodebuild','-version'),'Xcode 27.1\nBuild version different')]:
            def response(*args):return value if args==call else self.output(*args)
            with self.subTest(call=call),patch.object(ci,'capture',side_effect=response),patch.object(ci.platform,'machine',return_value='arm64'):
                with self.assertRaisesRegex(ValueError,'mismatch'):ci.validate_toolchain('latest-arm64')
        with patch.object(ci,'capture',side_effect=self.output),patch.object(ci.platform,'machine',return_value='x86_64'):
            with self.assertRaisesRegex(ValueError,'mismatch'):ci.validate_toolchain('latest-arm64')
    def test_unknown_profile_is_not_guessed(self):
        with self.assertRaises(KeyError):ci.validate_toolchain('other')
    def test_empty_python_suite_cannot_pass_the_gate(self):
        with tempfile.TemporaryDirectory() as folder:
            report={'checks':{}}
            with self.assertRaisesRegex(ValueError,'no Python test'):
                ci.execute(Path(folder),'empty',[sys.executable,'-c','print("Ran 0 tests\\n\\nOK")'],report,tests='python')
            self.assertEqual(report['checks']['empty']['tests'],0)
    def test_deadline_stops_and_reaps_its_owned_command(self):
        with tempfile.TemporaryDirectory() as folder:
            report={'checks':{}}
            with self.assertRaisesRegex(ValueError,'deadline'):
                ci.execute(Path(folder),'timeout',[sys.executable,'-c','import time; time.sleep(30)'],report,timeout=0.05)
            entry=report['checks']['timeout']
            self.assertTrue(entry['timedOut'])
            self.assertIsNotNone(entry['exitCode'])
            with self.assertRaises(ProcessLookupError):os.kill(entry['processID'],0)

if __name__=='__main__':unittest.main()
