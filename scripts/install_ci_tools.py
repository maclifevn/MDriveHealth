#!/usr/bin/env python3
"""Install the checksum-pinned upstream XcodeGen bundle in a new private directory."""
import argparse, hashlib, json, os, stat, subprocess, zipfile
from pathlib import Path

URL = 'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip'
SHA256 = '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806'

def install(destination):
    if destination.exists(): raise ValueError('Tool destination already exists; nothing removed')
    destination.mkdir(parents=True, mode=0o700)
    archive = destination / 'xcodegen.zip'
    subprocess.run(['curl','--fail','--location','--proto','=https','--proto-redir','=https','--max-time','60','--max-filesize','8388608','--output',str(archive),URL],check=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA256: raise ValueError('XcodeGen archive checksum mismatch')
    with zipfile.ZipFile(archive) as container:
        entries = container.infolist()
        if len(entries)>500 or sum(e.file_size for e in entries)>64<<20: raise ValueError('Unexpected tool archive size')
        if len({e.filename for e in entries}) != len(entries): raise ValueError('Duplicate tool entry')
        for entry in entries:
            name=Path(entry.filename);mode=entry.external_attr>>16
            if name.is_absolute() or '..' in name.parts or name.parts[0]!='xcodegen' or not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)): raise ValueError('Unsafe tool entry')
            target=destination/name
            if entry.is_dir(): target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(container.read(entry));target.chmod(stat.S_IMODE(mode))
    executable=destination/'xcodegen/bin/xcodegen'
    actual=subprocess.check_output([str(executable),'--version'],text=True).strip()
    if actual!='Version: 2.46.0': raise ValueError('Unexpected XcodeGen executable version')
    (destination/'tool-manifest.json').write_text(json.dumps(dict(url=URL,sha256=SHA256,version=actual,binDirectory=str(executable.parent)),indent=2)+'\n')
    print(str(executable.parent))

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('destination',type=Path);args=parser.parse_args()
    try:install(args.destination.resolve())
    except (OSError,ValueError,subprocess.CalledProcessError,zipfile.BadZipFile) as error:parser.exit(1,str(error)+'\n')
