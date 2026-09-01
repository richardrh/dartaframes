---
title: Native binaries
weight: 10
---

## Current status

Native binaries are not published yet. The native-assets build hook stays
inactive while release metadata is null, so ordinary Dart builds emit no native
asset. `Polars.native()` will work only after maintainers verify and publish the
binaries, then add their checksums and sizes to the package.

For now, source users build the library and use `Polars.open(path)`.
`Polars.process()` remains an explicit expert API. Nothing downloads or builds
native code automatically.

## User experience after release

Ordinary users will add `dartaframes` from pub.dev and call `Polars.native()`.
The package build hook will choose the matching macOS, Linux, or Windows binary,
verify its pinned size and SHA-256, cache it, and bundle it with the application.
Users will not need Rust, `mise`, or a manual library path.

Until then, [build from source with mise](/docs/build-from-source/).

## Release contract

Maintainers start the `Native release assets` workflow manually. It builds and
tests the locked Rust workspace on native hosted runners for these targets:

| Target | Runner | Library |
| --- | --- | --- |
| `aarch64-apple-darwin` | `macos-14` | `libdartaframes_polars_ffi.dylib` |
| `x86_64-apple-darwin` | `macos-15-intel` | `libdartaframes_polars_ffi.dylib` |
| `aarch64-unknown-linux-gnu` | `ubuntu-24.04-arm` | `libdartaframes_polars_ffi.so` |
| `x86_64-unknown-linux-gnu` | `ubuntu-24.04` | `libdartaframes_polars_ffi.so` |
| `x86_64-pc-windows-msvc` | `windows-2025` | `dartaframes_polars_ffi.dll` |

Each archive, named
`dartaframes-polars-native-<version>-<rust-target>.(tar.gz|zip)`, contains:

- the library and `manifest.json`;
- the Apache-2.0 `LICENSE`; and
- a reviewed `THIRD_PARTY_LICENSES.txt`.

The adjacent `.sha256` covers the archive; the manifest covers every payload.
Packaging also emits a uniquely named raw library and checksum. Consumer builds
download that raw file without extracting an archive. A complete release adds
both license files, `SHA256SUMS`, `native-assets.json`, and generated
`native_release_metadata.dart`.

Archive timestamps, ownership, ordering, and modes are normalized. Compiler
output may still vary with the toolchain, linker, and runner image.
`rust-toolchain.toml` pins the compiler; `Cargo.lock` pins dependencies; Cargo
always uses `--locked`. The release workflow does not cache Cargo state.

## Local packaging and verification

Packaging does not build Rust. Given an already-built library:

```sh
python3 tool/native_distribution.py package \
  --library target/aarch64-apple-darwin/release/libdartaframes_polars_ffi.dylib \
  --target aarch64-apple-darwin --version 0.1.0 --output-dir dist \
  --license LICENSE --third-party-licenses native/THIRD_PARTY_LICENSES.txt
python3 tool/native_distribution.py verify \
  --archive dist/dartaframes-polars-native-0.1.0-aarch64-apple-darwin.tar.gz
```

`verify` checks the sidecar, exact and safe archive members, filename, target,
schema, ABI, required-symbol declaration, licenses, size, and library digest.
`index` requires one valid archive and matching raw library for every supported
target. Generate Dart pins only from the reviewed index:

```sh
python3 tool/native_distribution.py generate-dart \
  --index dist/native-assets.json \
  --output lib/src/native_release_metadata.dart
```

Test this tooling without Rust:

```sh
python3 -m unittest discover -s tool -p 'test_native_*.py'
```

## Download and cache contract

The hook uses target-specific raw assets from the repository named in
`lib/src/native_asset_manifest.dart`. It:

- checks the shared cache first and verifies every hit;
- allows HTTPS and bounded GitHub Release redirects only;
- enforces request, inactivity, and total deadlines;
- streams to a unique temporary file with an exact byte limit;
- verifies the pinned size and SHA-256; and
- installs the verified file atomically.

There is no unverified-download or source-build fallback. Checksums fetched
beside an asset are not sufficient; maintainers must review pins before adding
them to source. Missing network access and a missing verified cache entry cause
the build to fail closed.

### Hook settings

The `hooks.user_defines.dartaframes` map accepts:

| Setting | Result |
| --- | --- |
| `source=custom_library`, `custom_library=<path>` | Use a local test library |
| `source=disabled` | Emit no asset |
| `source=pinned_release` | Use pinned metadata; fail closed if absent |
| No setting | Use promoted metadata, or emit no asset when metadata is null |

Once activated, consumers use the default asset with `Polars.native()`.

## Export control

`native/exports/` defines the intended ABI-2 exports for ELF, Mach-O, and
Windows: six core and twelve Arrow C Data/C Stream symbols. These files remain
inactive until a reviewed Cargo/build change wires the linker arguments.

Until then, libraries may expose extra Rust or dependency symbols. Before
packaging, the native matrix uses the pinned toolchain's `llvm-nm` and
`tool/native_exports.py` to require all 18 advertised symbols. Exact
allowlisting still requires tested platform linker configuration.

## Activation checklist

1. Replace `0.1.0-dev.1` with the same stable version in the pubspec, Cargo, and
   native release metadata. Validation fails until they match.
2. Protect the default branch, release environment, and tag policy in the
   GitHub repository.
3. Review Dependabot updates to immutable action SHAs. Confirm all five runner
   labels remain available, especially Linux arm64 and Intel macOS.
4. Review Rust 1.98.0 and the runner images. Choose and test the oldest
   supported glibc/macOS baseline; runner labels do not guarantee compatibility.
5. Wire and test exact export allowlists; required-symbol checks currently allow
   extra exports. Add malware scanning. Decide on macOS signing/notarization and
   Windows signing; no signing secrets or placeholder identities exist. Generate
   and independently review `native/THIRD_PARTY_LICENSES.txt` from the locked
   dependency graph before enabling a native build-only run.
6. Run a manual, non-publishing workflow. Compare manifests and checksums, test
   each binary on a clean machine, and retain provenance. Every matrix library
   must pass Rust tests and Dart protocol, ownership, CSV, Parquet, and
   relational integration tests.
7. Independently review `native-assets.json` and provenance. Commit the generated
   metadata, then tag that exact commit. Rerun the workflow from
   `refs/tags/v<version>` with upload enabled and the reviewed source run ID. It
   verifies tag provenance, allows only the metadata promotion diff, reuses the
   retained artifacts, and updates a draft without replacing assets or creating
   a tag.
8. Run `Prepare GitHub release` against the draft. It checks format, analysis,
   the publish archive, and draft assets/pins. It does not run ordinary Dart
   tests because a promoted hook cannot fetch unauthenticated draft assets.
   Publish manually, then require clean unauthenticated consumer smoke tests on
   every target before pub publication. No workflow publishes to pub.dev;
   ownership/bootstrap and trusted-publishing approval remain manual.
