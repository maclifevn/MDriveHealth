#!/usr/bin/env python3
"""Seed only an owned FullWindowNativeFixture SQLite store with history edge cases."""
import argparse, json, os, sqlite3, tempfile, time
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixture-dir', type=Path, required=True)
    args = parser.parse_args()
    root = args.fixture_dir.resolve()
    temporary_roots = {Path(tempfile.gettempdir()).resolve(), Path('/tmp').resolve()}
    assert any(root.is_relative_to(parent) for parent in temporary_roots), 'Private temporary fixture only'
    assert root.name.startswith('MDriveHealth-') and root.stat().st_uid == os.getuid()
    proof = json.loads((root / 'proof.json').read_text())
    assert proof['productionAppLaunched'] is False and proof['realHardwareMutations'] == 0
    path = root / 'history.sqlite'
    assert path.is_file() and not path.is_symlink()
    backup = root / 'before-history-seed.sqlite'
    assert not backup.exists(), 'Refusing to replace an earlier fixture seed'
    connection = sqlite3.connect(path)
    try:
        with sqlite3.connect(backup) as target:
            connection.backup(target)
        backup.chmod(0o600)
        rows = connection.execute("SELECT DISTINCT drive_key FROM drive_snapshots WHERE bsd_name='disk102' AND metrics_version=2").fetchall()
        assert len(rows) == 1, 'Expected exactly one fake external-drive identity'
        key = rows[0][0]
        counters = [0, 2**53 + 1, 2**63, 2**64 - 1]
        now = time.time()
        with connection:
            connection.execute('DELETE FROM drive_snapshots WHERE drive_key=?', (key,))
            for index, counter in enumerate(counters):
                connection.execute('INSERT INTO drive_snapshots (drive_key,bsd_name,captured_at,temperature_c,health_score,rating,lifetime_left,power_on_hours,bytes_written,defect_count,pending_sectors,metrics_version) VALUES (?,?,?,?,?,?,?,?,?,?,?,2)', (key, 'disk102', now-(4-index)*3600, None, None, 'unknown', None, None, str(2**64-1), str(counter), None))
        result = dict(fixtureDatabase=str(path), fakeBSDName='disk102', driveKey=key, defectCounters=[str(n) for n in counters], unknownMetrics=['temperature', 'score', 'lifetime'], rawRows=connection.execute('SELECT captured_at,temperature_c,health_score,lifetime_left,bytes_written,defect_count FROM drive_snapshots WHERE drive_key=? ORDER BY captured_at', (key,)).fetchall(), realHardwareMutations=0)
        (root / 'history-seed.json').write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(dict(status='seeded', rows=len(counters), output=str(root / 'history-seed.json'))))
    finally:
        connection.close()

if __name__ == '__main__':
    main()
