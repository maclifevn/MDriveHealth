#!/usr/bin/env python3
"""Generate and verify a signed Sparkle feed; never upload or publish it."""
import argparse
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from urllib.parse import quote, urlparse
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'

def validate_feed(feed, archive, info, url_prefix):
    root = ET.parse(feed).getroot()
    items = root.findall('./channel/item')
    if len(items) != 1: raise ValueError('Expected one complete update in the feed')
    item = items[0]; enclosure = item.find('enclosure')
    if enclosure is None: raise ValueError('Missing update enclosure')
    build = item.findtext(SPARKLE + 'version') or enclosure.get(SPARKLE + 'version')
    version = item.findtext(SPARKLE + 'shortVersionString') or enclosure.get(SPARKLE + 'shortVersionString')
    if build != info['CFBundleVersion'] or version != info['CFBundleShortVersionString']:
        raise ValueError('Feed version differs from packaged application')
    if item.findtext(SPARKLE + 'minimumSystemVersion') != info['LSMinimumSystemVersion']:
        raise ValueError('Feed minimum macOS differs from packaged application')
    expected_url = url_prefix.rstrip('/') + '/' + quote(archive.name)
    if enclosure.get('url') != expected_url or enclosure.get('length') != str(archive.stat().st_size):
        raise ValueError('Feed URL/length differs from update archive')
    signature = enclosure.get(SPARKLE + 'edSignature')
    if not signature: raise ValueError('Missing EdDSA archive signature')
    return signature

def generate(archive, app, output, tools, config):
    if output.exists(): raise ValueError('Output directory exists; refusing to overwrite it')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('SUPublicEDKey') != config['publicKey'] or info.get('SUFeedURL') != config['feedURL']:
        raise ValueError('Update app and release configuration differ')
    account = config['keychainAccount']
    public_key = subprocess.check_output([str(tools / 'generate_keys'), '--account', account, '-p'], text=True).strip()
    if public_key != config['publicKey']: raise ValueError('Keychain signing key does not match application public key')
    prefix = 'https://github.com/' + config['repository'] + '/releases/download/v' + info['CFBundleShortVersionString'] + '/'
    if urlparse(config['feedURL']).scheme != 'https': raise ValueError('Feed must use HTTPS')
    output.mkdir(parents=True, mode=0o700)
    update = output / archive.name
    shutil.copy2(archive, update)
    feed = output / 'appcast.xml'
    subprocess.run([str(tools / 'generate_appcast'), '--account', account,
                    '--download-url-prefix', prefix, '--maximum-deltas', '0', '--maximum-versions', '1',
                    '-o', str(feed), str(output)], check=True)
    signature = validate_feed(feed, update, info, prefix)
    subprocess.run([str(tools / 'sign_update'), '--account', account, '--verify', str(update), signature], check=True)
    subprocess.run([str(tools / 'sign_update'), '--account', account, '--verify', str(feed)], check=True)
    return {'feed': str(feed), 'archive': str(update), 'version': info['CFBundleShortVersionString'],
            'build': info['CFBundleVersion'], 'feedURL': config['feedURL'], 'downloadURL': prefix + quote(archive.name)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path); parser.add_argument('app', type=Path); parser.add_argument('output', type=Path)
    parser.add_argument('--tools-dir', type=Path, required=True)
    parser.add_argument('--config', type=Path, default=Path(__file__).resolve().parents[1] / 'Config/Sparkle.json')
    args = parser.parse_args()
    try:
        report = generate(args.archive.resolve(), args.app.resolve(), args.output.resolve(), args.tools_dir.resolve(), json.loads(args.config.read_text()))
        print(json.dumps(report, indent=2))
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError) as error:
        parser.exit(1, str(error) + '\n')

if __name__ == '__main__': main()
