#!/usr/bin/env python3
"""Verify that a defined-export listing advertises the complete native ABI."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from native_distribution import SYMBOLS


class ExportError(Exception):
    pass


_SYMBOL = re.compile(r"^_?[A-Za-z][A-Za-z0-9_@$?.-]*$")
_UNDEFINED_TYPES = {"U", "u", "w", "v"}


def defined_exports(listing: str) -> set[str]:
    """Parse conventional llvm-nm/nm output, tolerating Mach-O underscores."""
    exports: set[str] = set()
    for raw_line in listing.splitlines():
        line = raw_line.strip()
        if not line or line.endswith(":"):
            continue
        fields = line.split()
        candidate = fields[-1]
        symbol_type = fields[-2] if len(fields) >= 2 else None
        if symbol_type in _UNDEFINED_TYPES or not _SYMBOL.fullmatch(candidate):
            continue
        if candidate.startswith("_") and candidate[1:] in SYMBOLS:
            candidate = candidate[1:]
        exports.add(candidate)
    return exports


def require_abi_exports(listing: str) -> set[str]:
    exports = defined_exports(listing)
    missing = set(SYMBOLS) - exports
    if missing:
        raise ExportError(f"native library is missing ABI exports: {sorted(missing)}")
    return exports


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listing", type=Path, required=True)
    args = parser.parse_args()
    try:
        exports = require_abi_exports(args.listing.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ExportError) as error:
        parser.error(str(error))
    print(f"verified all {len(SYMBOLS)} required ABI exports ({len(exports)} defined exports)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
