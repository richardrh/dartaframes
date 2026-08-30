#!/usr/bin/env python3
"""Validate the version contract shared by Dart and the native crate."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
STABLE_VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
TARGETS = {
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "x86_64-unknown-linux-gnu",
    "x86_64-pc-windows-msvc",
}


def one(pattern: str, text: str, source: str) -> str:
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one {source} value, found {len(matches)}")
    return matches[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--tag")
    parser.add_argument("--require-promoted", action="store_true")
    args = parser.parse_args()
    if not STABLE_VERSION.fullmatch(args.version):
        raise SystemExit(f"release version must be stable canonical SemVer: {args.version!r}")
    if args.tag is not None and args.tag != f"v{args.version}":
        raise SystemExit(f"release tag must be exactly v{args.version}")

    pubspec = (ROOT / "pubspec.yaml").read_text(encoding="utf-8")
    package = one(r"^name:\s*([^\s#]+)\s*$", pubspec, "pubspec package")
    pub_version = one(r"^version:\s*([^\s#]+)\s*$", pubspec, "pubspec version")
    if package != "dartaframes_polars":
        raise SystemExit(f"unexpected pub package: {package}")
    cargo = (ROOT / "native/polars_ffi/Cargo.toml").read_text(encoding="utf-8")
    cargo_version = one(r'^version\s*=\s*"([^"]+)"\s*$', cargo, "native Cargo version")
    metadata = (ROOT / "lib/src/native_release_metadata.dart").read_text(encoding="utf-8")
    metadata_version = one(
        r"^const nativeReleaseVersion = '([^']+)';\s*$", metadata, "native metadata version"
    )
    versions = {
        "requested": args.version,
        "pubspec": pub_version,
        "native Cargo": cargo_version,
        "native Dart metadata": metadata_version,
    }
    if len(set(versions.values())) != 1:
        raise SystemExit("release versions disagree: " + ", ".join(f"{k}={v}" for k, v in versions.items()))
    records = set(re.findall(r"^  '([^']+)': NativeReleaseArtifact\($", metadata, re.MULTILINE))
    if records != TARGETS:
        raise SystemExit(f"native metadata target set is incomplete: {sorted(TARGETS - records)}")
    for target in TARGETS:
        if f"dartaframes-polars-native-{args.version}-{target}" not in metadata:
            raise SystemExit(f"native metadata asset names do not match version for {target}")
    if args.require_promoted:
        if "rawSha256: null" in metadata or "rawSize: null" in metadata:
            raise SystemExit("native metadata is not fully promoted")
        digests = re.findall(r"rawSha256: '([0-9a-f]{64})'", metadata)
        sizes = [int(value) for value in re.findall(r"rawSize: ([0-9]+)", metadata)]
        if len(digests) != len(TARGETS) or len(sizes) != len(TARGETS) or any(size <= 0 for size in sizes):
            raise SystemExit("native metadata has invalid promoted checksums or sizes")
    print(f"validated release contract for v{args.version}")


if __name__ == "__main__":
    main()
