#!/usr/bin/env python3
"""Run production-safety regression guards on an isolated package copy.

Failures identify remaining audit requirements. The original snapshot failed
all guards; corrected implementations should pass. This never writes to a
real external volume and never changes the production test target.
Pass --output-dir to retain the isolated package and full test log.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    temporary = None
    if args.output_dir:
        destination = args.output_dir.resolve()
        destination.mkdir(parents=True, exist_ok=True)
        if any(destination.iterdir()):
            parser.error("--output-dir must be empty")
    else:
        temporary = tempfile.TemporaryDirectory(prefix="mdrivehealth-audit-repros-")
        destination = Path(temporary.name)
    package = destination / "MDriveHealthCore"
    shutil.copytree(repo / "Packages/MDriveHealthCore", package,
                    ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))
    command = ["swift", "test", "--package-path", str(package),
               "--filter", "ProductionAuditRepros"]
    with (destination / "repros.log").open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
    lines = (destination / "repros.log").read_text().splitlines()
    for line in lines:
        if "error:" in line or "Executed " in line or "Build complete" in line:
            print(line)
    print(f"Safety guards exit code: {result.returncode} (failures identify remaining requirements)")
    if args.output_dir:
        print(f"Full log: {destination / 'repros.log'}")
    if temporary:
        temporary.cleanup()
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
