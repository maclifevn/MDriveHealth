#!/usr/bin/env python3
"""
convert_drivedb.py — converts smartmontools drivedb.h (GPL-2.0-or-later) into
the drivedb.json resource bundled with MDriveHealthCore.

Usage: python3 tools/convert_drivedb.py third_party/drivedb.h \
           Packages/MDriveHealthCore/Sources/MDriveHealthCore/Resources/drivedb.json

This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
"""

import json
import re
import sys
from datetime import date


def tokenize(source: str):
    """Yields '{', '}', ',' and decoded C string literals, skipping comments."""
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c == "/" and i + 1 < n and source[i + 1] == "/":
            i = source.find("\n", i)
            i = n if i < 0 else i
        elif c == "/" and i + 1 < n and source[i + 1] == "*":
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
        elif c == '"':
            chars = []
            i += 1
            while i < n and source[i] != '"':
                if source[i] == "\\" and i + 1 < n:
                    esc = source[i + 1]
                    chars.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(esc, "\\" + esc))
                    i += 2
                else:
                    chars.append(source[i])
                    i += 1
            i += 1  # closing quote
            yield ("str", "".join(chars))
        elif c in "{},":
            yield (c, c)
            i += 1
        else:
            i += 1


def parse_entries(source: str):
    """Parses the flat initializer list into 5-string entries.

    Adjacent string literals are concatenated (C string pasting)."""
    entries = []
    fields = None
    current = None
    for kind, value in tokenize(source):
        if kind == "{":
            fields, current = [], None
        elif kind == "str" and fields is not None:
            current = value if current is None else current + value
        elif kind == "," and fields is not None:
            if current is not None:
                fields.append(current)
                current = None
        elif kind == "}" and fields is not None:
            if current is not None:
                fields.append(current)
            if len(fields) == 5:
                entries.append(fields)
            fields, current = None, None
    return entries


PRESET_RE = re.compile(r"-([vF])\s+(\S+)")
# -v ID,FORMAT[:BYTEORDER][,NAME[,HDD|SSD]]
VOPT_RE = re.compile(
    r"^(?P<id>\d+|N),(?P<format>[^,:]+)(?::(?P<byteorder>[^,]+))?"
    r"(?:,(?P<name>[^,]+))?(?:,(?P<only>HDD|SSD))?$"
)


def parse_presets(presets: str):
    attrs = {}
    firmware_fixes = []
    for opt, arg in PRESET_RE.findall(presets):
        if opt == "F":
            firmware_fixes.append(arg)
            continue
        m = VOPT_RE.match(arg)
        if not m or m.group("id") == "N":
            continue
        spec = {"format": m.group("format")}
        if m.group("byteorder"):
            spec["byteorder"] = m.group("byteorder")
        if m.group("name"):
            spec["name"] = m.group("name")
        if m.group("only"):
            spec["onlyFor"] = m.group("only")
        attrs[m.group("id")] = spec
    return attrs, firmware_fixes


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else "third_party/drivedb.h"
    dst_path = (
        sys.argv[2]
        if len(sys.argv) > 2
        else "Packages/MDriveHealthCore/Sources/MDriveHealthCore/Resources/drivedb.json"
    )
    with open(src_path, encoding="utf-8") as f:
        source = f.read()

    version = "unknown"
    version_match = re.search(r"VERSION: ([0-9.]+)", source)
    if version_match:
        version = version_match.group(1)

    defaults = {}
    entries = []
    skipped_usb = 0
    for family, model, firmware, warning, presets in parse_entries(source):
        if family.startswith("$"):
            continue  # version dummy entry
        if family.startswith("USB:") or model.startswith("USB:"):
            skipped_usb += 1  # USB bridge entries: no SMART path on macOS
            continue
        attrs, fixes = parse_presets(presets)
        if family == "DEFAULT":
            defaults = attrs
            continue
        entry = {"family": family, "model": model}
        if firmware:
            entry["firmware"] = firmware
        if warning:
            entry["warning"] = warning
        if attrs:
            entry["attrs"] = attrs
        if fixes:
            entry["firmwareFixes"] = fixes
        entries.append(entry)

    out = {
        "source": "smartmontools drivedb.h (GPL-2.0-or-later), https://www.smartmontools.org",
        "drivedbVersion": version,
        "generated": date.today().isoformat(),
        "defaults": defaults,
        "entries": entries,
    }
    with open(dst_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    print(
        f"drivedb {version}: {len(entries)} entries "
        f"({skipped_usb} USB bridge entries skipped), "
        f"{len(defaults)} default attributes -> {dst_path}"
    )


if __name__ == "__main__":
    main()
