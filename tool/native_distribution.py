#!/usr/bin/env python3
"""Create, verify, and index dartaframes native release assets."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import re
import sys
import tarfile
import zipfile
from pathlib import Path, PurePosixPath

PACKAGE = "dartaframes_polars_ffi"
SCHEMA_VERSION = 1
ABI_VERSION = 2
SYMBOLS = [
    "df_abi_version",
    "df_invoke",
    "df_buffer_free",
    "df_handle_release",
    "df_handle_token_new",
    "df_handle_token_release",
    "df_arrow_array_new",
    "df_arrow_array_delete",
    "df_arrow_schema_new",
    "df_arrow_schema_delete",
    "df_arrow_stream_new",
    "df_arrow_stream_delete",
    "df_series_export_arrow",
    "df_series_import_arrow",
    "df_frame_export_arrow",
    "df_frame_import_arrow",
    "df_frame_export_arrow_stream",
    "df_frame_import_arrow_stream",
]
TARGETS = {
    "aarch64-apple-darwin": "libdartaframes_polars_ffi.dylib",
    "x86_64-apple-darwin": "libdartaframes_polars_ffi.dylib",
    "aarch64-unknown-linux-gnu": "libdartaframes_polars_ffi.so",
    "x86_64-unknown-linux-gnu": "libdartaframes_polars_ffi.so",
    "x86_64-pc-windows-msvc": "dartaframes_polars_ffi.dll",
}
VERSION_RE = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+-]{0,127}\Z")


class DistributionError(Exception):
    pass


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical_json(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def validate_version(version: str) -> None:
    if not VERSION_RE.fullmatch(version) or ".." in version:
        raise DistributionError(f"unsafe or invalid version: {version!r}")


def archive_name(version: str, target: str) -> str:
    suffix = ".zip" if target.endswith("windows-msvc") else ".tar.gz"
    return f"dartaframes-polars-native-{version}-{target}{suffix}"


def raw_asset_name(version: str, target: str) -> str:
    suffix = Path(TARGETS[target]).suffix
    return f"dartaframes-polars-native-{version}-{target}{suffix}"


def manifest(
    version: str,
    target: str,
    library_name: str,
    library: bytes,
    license_text: bytes,
    third_party_licenses: bytes,
) -> dict:
    return {
        "abi_version": ABI_VERSION,
        "required_symbols": SYMBOLS,
        "library": {
            "name": library_name,
            "sha256": sha256(library),
            "size": len(library),
        },
        "licenses": {
            "LICENSE": sha256(license_text),
            "THIRD_PARTY_LICENSES.txt": sha256(third_party_licenses),
        },
        "package": PACKAGE,
        "schema_version": SCHEMA_VERSION,
        "target": target,
        "version": version,
    }


def make_tar(entries: dict[str, bytes]) -> bytes:
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w", format=tarfile.USTAR_FORMAT) as tar:
            for name in sorted(entries):
                info = tarfile.TarInfo(name)
                info.size = len(entries[name])
                info.mode = 0o755 if name.endswith((".so", ".dylib")) else 0o644
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                tar.addfile(info, io.BytesIO(entries[name]))
    return raw.getvalue()


def make_zip(entries: dict[str, bytes]) -> bytes:
    raw = io.BytesIO()
    with zipfile.ZipFile(raw, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name in sorted(entries):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3
            info.external_attr = 0o644 << 16
            archive.writestr(info, entries[name])
    return raw.getvalue()


def package(args: argparse.Namespace) -> None:
    validate_version(args.version)
    expected = TARGETS[args.target]
    source = args.library.resolve()
    if not source.is_file():
        raise DistributionError(f"library does not exist: {source}")
    if source.name != expected:
        raise DistributionError(f"expected library name {expected!r}, got {source.name!r}")
    library = source.read_bytes()
    if not library:
        raise DistributionError("refusing to package an empty library")
    license_text = args.license.read_bytes()
    third_party_licenses = args.third_party_licenses.read_bytes()
    if not license_text or not third_party_licenses:
        raise DistributionError("license files must not be empty")
    metadata = manifest(
        args.version,
        args.target,
        expected,
        library,
        license_text,
        third_party_licenses,
    )
    entries = {
        expected: library,
        "LICENSE": license_text,
        "THIRD_PARTY_LICENSES.txt": third_party_licenses,
        "manifest.json": canonical_json(metadata),
    }
    payload = make_zip(entries) if args.target.endswith("windows-msvc") else make_tar(entries)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    output = args.output_dir / archive_name(args.version, args.target)
    output.write_bytes(payload)
    output.with_name(output.name + ".sha256").write_text(
        f"{sha256(payload)}  {output.name}\n", encoding="ascii"
    )
    raw_output = args.output_dir / raw_asset_name(args.version, args.target)
    raw_output.write_bytes(library)
    raw_output.with_name(raw_output.name + ".sha256").write_text(
        f"{sha256(library)}  {raw_output.name}\n", encoding="ascii"
    )
    print(output)


def safe_members(names: list[str]) -> None:
    for name in names:
        path = PurePosixPath(name)
        if path.is_absolute() or ".." in path.parts or len(path.parts) != 1:
            raise DistributionError(f"unsafe archive member: {name!r}")


def read_archive(path: Path) -> dict[str, bytes]:
    try:
        if path.name.endswith(".zip"):
            with zipfile.ZipFile(path) as archive:
                names = archive.namelist()
                safe_members(names)
                if len(names) != len(set(names)):
                    raise DistributionError("archive contains duplicate members")
                return {name: archive.read(name) for name in names}
        with tarfile.open(path, mode="r:gz") as archive:
            members = archive.getmembers()
            names = [member.name for member in members]
            safe_members(names)
            if len(names) != len(set(names)) or any(not member.isfile() for member in members):
                raise DistributionError("archive contains duplicate or non-file members")
            return {member.name: archive.extractfile(member).read() for member in members}  # type: ignore[union-attr]
    except (OSError, tarfile.TarError, zipfile.BadZipFile, KeyError) as error:
        raise DistributionError(f"cannot read {path}: {error}") from error


def verify_sidecar(path: Path, checksum: Path) -> None:
    try:
        line = checksum.read_text(encoding="ascii")
    except OSError as error:
        raise DistributionError(f"cannot read checksum {checksum}: {error}") from error
    match = re.fullmatch(r"([0-9a-f]{64})  ([^\r\n]+)\n?", line)
    if not match or match.group(2) != path.name:
        raise DistributionError(f"invalid checksum sidecar: {checksum}")
    if match.group(1) != sha256(path.read_bytes()):
        raise DistributionError(f"asset checksum mismatch: {path}")


def verify_one(path: Path, checksum: Path | None = None) -> dict:
    if not path.is_file():
        raise DistributionError(f"archive does not exist: {path}")
    if checksum is not None:
        verify_sidecar(path, checksum)
    entries = read_archive(path)
    if "manifest.json" not in entries:
        raise DistributionError(f"manifest.json missing from {path}")
    try:
        metadata = json.loads(entries["manifest.json"])
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DistributionError(f"invalid manifest in {path}: {error}") from error
    target = metadata.get("target")
    version = metadata.get("version")
    if target not in TARGETS or not isinstance(version, str):
        raise DistributionError(f"unsupported target or version in {path}")
    validate_version(version)
    library_name = TARGETS[target]
    expected_entries = {
        "LICENSE",
        "THIRD_PARTY_LICENSES.txt",
        "manifest.json",
        library_name,
    }
    if set(entries) != expected_entries:
        raise DistributionError(f"unexpected archive members in {path}: {sorted(entries)}")
    expected = manifest(
        version,
        target,
        library_name,
        entries[library_name],
        entries["LICENSE"],
        entries["THIRD_PARTY_LICENSES.txt"],
    )
    if metadata != expected:
        raise DistributionError(f"manifest metadata or library digest mismatch in {path}")
    if path.name != archive_name(version, target):
        raise DistributionError(f"archive name does not match manifest: {path.name}")
    return metadata


def verify(args: argparse.Namespace) -> None:
    checksum = args.checksum
    if checksum is None:
        checksum = args.archive.with_name(args.archive.name + ".sha256")
    verify_one(args.archive, checksum)
    print(f"verified {args.archive}")


def build_index(args: argparse.Namespace) -> None:
    validate_version(args.version)
    legal_files = {
        name: (args.directory / name).read_bytes()
        for name in ("LICENSE", "THIRD_PARTY_LICENSES.txt")
    }
    if any(not content for content in legal_files.values()):
        raise DistributionError("release license files must not be empty")
    archives = sorted(
        path for path in args.directory.iterdir() if path.name.endswith((".tar.gz", ".zip"))
    )
    records = []
    seen = set()
    for archive in archives:
        metadata = verify_one(archive, archive.with_name(archive.name + ".sha256"))
        if metadata["version"] != args.version:
            raise DistributionError(f"wrong version in {archive}")
        if metadata["target"] in seen:
            raise DistributionError(f"duplicate target: {metadata['target']}")
        archive_entries = read_archive(archive)
        for name, content in legal_files.items():
            if archive_entries[name] != content:
                raise DistributionError(f"{name} differs in {archive}")
        seen.add(metadata["target"])
        raw = args.directory / raw_asset_name(args.version, metadata["target"])
        raw_checksum = raw.with_name(raw.name + ".sha256")
        if not raw.is_file():
            raise DistributionError(f"raw release asset does not exist: {raw}")
        verify_sidecar(raw, raw_checksum)
        library_metadata = metadata["library"]
        raw_bytes = raw.read_bytes()
        if (
            len(raw_bytes) != library_metadata["size"]
            or sha256(raw_bytes) != library_metadata["sha256"]
        ):
            raise DistributionError(f"raw release asset does not match archive: {raw}")
        records.append(
            {
                "archive": archive.name,
                "archive_sha256": sha256(archive.read_bytes()),
                "raw_asset": raw.name,
                "raw_sha256": sha256(raw_bytes),
                "raw_size": len(raw_bytes),
                "target": metadata["target"],
            }
        )
    missing = set(TARGETS) - seen
    if missing or len(seen) != len(TARGETS):
        raise DistributionError(f"release target set is incomplete; missing: {sorted(missing)}")
    records.sort(key=lambda record: record["target"])
    release_manifest = {
        "abi_version": ABI_VERSION,
        "artifacts": records,
        "package": PACKAGE,
        "licenses": {name: sha256(content) for name, content in legal_files.items()},
        "schema_version": SCHEMA_VERSION,
        "version": args.version,
    }
    args.output_dir.mkdir(parents=True, exist_ok=True)
    (args.output_dir / "native-assets.json").write_bytes(canonical_json(release_manifest))
    checksum_lines = []
    for name, content in legal_files.items():
        checksum_lines.append(f"{sha256(content)}  {name}\n")
    for record in records:
        checksum_lines.extend([
            f"{record['archive_sha256']}  {record['archive']}\n",
            f"{record['raw_sha256']}  {record['raw_asset']}\n",
        ])
    checksum_lines.sort()
    (args.output_dir / "SHA256SUMS").write_text("".join(checksum_lines), encoding="ascii")
    print(f"verified {len(records)} release artifacts")


def dart_string(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def generate_dart(args: argparse.Namespace) -> None:
    try:
        release = json.loads(args.index.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DistributionError(f"cannot read reviewed index {args.index}: {error}") from error
    if (
        release.get("schema_version") != SCHEMA_VERSION
        or release.get("abi_version") != ABI_VERSION
        or release.get("package") != PACKAGE
    ):
        raise DistributionError("reviewed index has the wrong schema or package")
    version = release.get("version")
    if not isinstance(version, str):
        raise DistributionError("reviewed index has no version")
    validate_version(version)
    artifacts = release.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != len(TARGETS):
        raise DistributionError("reviewed index does not contain exactly five targets")
    records = {}
    for record in artifacts:
        if not isinstance(record, dict) or record.get("target") not in TARGETS:
            raise DistributionError("reviewed index contains an invalid target record")
        target = record["target"]
        digest, size = record.get("raw_sha256"), record.get("raw_size")
        expected_raw = raw_asset_name(version, target)
        if (
            record.get("archive") != archive_name(version, target)
            or not isinstance(record.get("archive_sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", record["archive_sha256"])
            or record.get("raw_asset") != expected_raw
            or not isinstance(digest, str)
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or not isinstance(size, int)
            or isinstance(size, bool)
            or size <= 0
        ):
            raise DistributionError(f"reviewed index contains invalid raw metadata for {target}")
        if target in records:
            raise DistributionError(f"reviewed index contains duplicate target {target}")
        records[target] = record
    if set(records) != set(TARGETS):
        raise DistributionError("reviewed index target set is incomplete")
    lines = [
        "// GENERATED FILE. Run `python3 tool/native_distribution.py generate-dart`.",
        "// Values in this file must come from a separately reviewed native-assets.json.",
        "", "import 'native_release_artifact.dart';", "",
        f"const nativeReleaseVersion = {dart_string(version)};", "",
        "const nativeReleaseArtifacts = <String, NativeReleaseArtifact>{",
    ]
    for target in TARGETS:
        record = records[target]
        lines.extend([
            f"  {dart_string(target)}: NativeReleaseArtifact(",
            f"    archiveName: {dart_string(archive_name(version, target))},",
            f"    libraryName: {dart_string(TARGETS[target])},",
            f"    rawAssetName: {dart_string(record['raw_asset'])},",
            f"    rawSha256: {dart_string(record['raw_sha256'])},",
            f"    rawSize: {record['raw_size']},",
            "  ),",
        ])
    lines.extend(["};", ""])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines), encoding="utf-8")
    print(args.output)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    commands = result.add_subparsers(dest="command", required=True)
    create = commands.add_parser("package", help="package one native library")
    create.add_argument("--library", type=Path, required=True)
    create.add_argument("--target", choices=sorted(TARGETS), required=True)
    create.add_argument("--version", required=True)
    create.add_argument("--output-dir", type=Path, required=True)
    create.add_argument("--license", type=Path, required=True)
    create.add_argument("--third-party-licenses", type=Path, required=True)
    create.set_defaults(run=package)
    check = commands.add_parser("verify", help="verify an archive and its checksum")
    check.add_argument("--archive", type=Path, required=True)
    check.add_argument("--checksum", type=Path)
    check.set_defaults(run=verify)
    index = commands.add_parser("index", help="verify all targets and write release indexes")
    index.add_argument("--directory", type=Path, required=True)
    index.add_argument("--version", required=True)
    index.add_argument("--output-dir", type=Path, required=True)
    index.set_defaults(run=build_index)
    generate = commands.add_parser("generate-dart", help="generate pinned Dart metadata from a reviewed index")
    generate.add_argument("--index", type=Path, required=True)
    generate.add_argument("--output", type=Path, required=True)
    generate.set_defaults(run=generate_dart)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        args.run(args)
        return 0
    except (DistributionError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
