#!/usr/bin/env python3
"""Read-only smoke of the actual helper bundled in a built app; metadata only."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("--output-dir must be empty")
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="mdrivehealth-hardware-smoke-") as temporary:
        package = Path(temporary) / "MDriveHealthCore"
        shutil.copytree(repo / "Packages/MDriveHealthCore", package,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))
        manifest = package / "Package.swift"
        text = manifest.read_text()
        anchor = "        .testTarget("
        if text.count(anchor) != 1:
            parser.error("Package.swift changed; review target injection")
        manifest.write_text(text.replace(anchor, '        .executableTarget(name: "HardwareSmoke", dependencies: ["MDriveHealthCore"]),\n' + anchor))
        target = package / "Sources/HardwareSmoke"
        target.mkdir()
        shutil.copy2(repo / "audit/repros/HardwareSmoke.swift", target / "main.swift")
        with (output / "smoke.log").open("w") as log:
            subprocess.run(["swift", "run", "--package-path", str(package), "HardwareSmoke",
                            str(args.worker.resolve()), str(output / "summary.json")],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    print((output / "summary.json").read_text())


if __name__ == "__main__":
    main()
