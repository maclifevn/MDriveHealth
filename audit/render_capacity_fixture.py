#!/usr/bin/env python3
"""Render F09 using the actual app views and synthetic inconclusive input.

Builds an isolated package copy. No hardware probes or disk tests are run.
The output must not already exist.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixture", choices=["capacity", "smart"], default="capacity")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error("--output must not already exist")
    output.parent.mkdir(parents=True, exist_ok=True)
    repo = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="mdrivehealth-audit-render-") as temporary:
        package = Path(temporary) / "MDriveHealthCore"
        shutil.copytree(repo / "Packages/MDriveHealthCore", package,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm", ".DS_Store"))
        manifest = package / "Package.swift"
        source = manifest.read_text()
        anchor = "        .testTarget("
        if source.count(anchor) != 1:
            parser.error("Package.swift changed; review the isolated target injection")
        manifest.write_text(source.replace(anchor,
            '        .executableTarget(name: "AuditFixture", dependencies: ["MDriveHealthCore"]),\n'
            + anchor))
        target = package / "Sources/AuditFixture"
        target.mkdir()
        for name in ["ShareCards.swift", "Components.swift"]:
            shutil.copy2(repo / "App/Views" / name, target / name)
        fixture = "RenderSMARTFixture.swift" if args.fixture == "smart" else "RenderCapacityFixture.swift"
        shutil.copy2(repo / "audit/repros" / fixture, target / fixture)
        subprocess.run(["swift", "run", "--package-path", str(package),
                        "AuditFixture", str(output)], check=True)
    print(f"Synthetic {args.fixture} card: {output}")


if __name__ == "__main__":
    main()
