# Native distribution groundwork

No native binaries are currently published or trusted by this workspace. The
root package contains a dormant native-assets build hook: ordinary Dart work
emits no asset while pinned metadata is null, and `Polars.native()` becomes
usable only after reviewed checksums and sizes are promoted. `Polars.open(path)`
and `Polars.process()` remain explicit development/expert APIs.

## Release contract

The `Native release assets` workflow can only be started manually. It builds
and tests the locked Rust workspace on native hosted runners, then packages
these targets:

| Target | Runner | Library |
| --- | --- | --- |
| `aarch64-apple-darwin` | `macos-14` | `libdartaframes_polars_ffi.dylib` |
| `x86_64-apple-darwin` | `macos-15-intel` | `libdartaframes_polars_ffi.dylib` |
| `aarch64-unknown-linux-gnu` | `ubuntu-24.04-arm` | `libdartaframes_polars_ffi.so` |
| `x86_64-unknown-linux-gnu` | `ubuntu-24.04` | `libdartaframes_polars_ffi.so` |
| `x86_64-pc-windows-msvc` | `windows-2025` | `dartaframes_polars_ffi.dll` |

Each archive is named
`dartaframes-polars-native-<version>-<rust-target>.(tar.gz|zip)` and contains
the library, `manifest.json`, the Apache-2.0 `LICENSE`, and a reviewed
`THIRD_PARTY_LICENSES.txt`. The adjacent `.sha256` covers the archive; the
embedded manifest covers every payload. Packaging also emits a uniquely named
raw `.dylib`, `.so`, or `.dll` with its own checksum. The hook downloads this
raw asset, avoiding extraction in consumer builds. A complete release also
publishes both license files, `SHA256SUMS`, `native-assets.json`, and generated
`native_release_metadata.dart`.
Archives have normalized timestamps,
ownership, ordering, and modes, but bit-for-bit compiler output reproducibility
still depends on toolchain and linker behavior on GitHub's runner images.

The compiler is pinned by `rust-toolchain.toml`, dependencies by `Cargo.lock`,
and Cargo is always invoked with `--locked`. The workflow does not cache Cargo
state, so it cannot accidentally restore an unreviewed cache into a release.

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

`verify` checks the sidecar, safe/exact archive members, filename, target,
schema, ABI, required-symbol declaration, licenses, size, and library digest. `index`
requires exactly one valid archive and matching raw library for every supported
target before producing release indexes. Generate Dart pins only from the
reviewed index:

```sh
python3 tool/native_distribution.py generate-dart \
  --index dist/native-assets.json \
  --output lib/src/native_release_metadata.dart
```

Run the tooling tests without Rust using:

```sh
python3 -m unittest discover -s tool -p 'test_native_*.py'
```

The hook uses cache-first, target-specific raw downloads from the single
repository identity in `lib/src/native_asset_manifest.dart`. It validates every
cache hit, permits HTTPS and bounded GitHub release redirects only, applies
request, inactivity, and absolute total deadlines, streams into a unique
temporary file with an exact byte bound, verifies its size and SHA-256, and
atomically installs it.
It has no unverified or source-build fallback. A checksum downloaded from the
same location is not trusted; pins enter source only through review.

Consumers select the default with `Polars.native()`. An explicit hook define
`source=custom_library` plus `custom_library=<path>` preserves local testing;
`source=disabled` emits nothing; `source=pinned_release` fails closed if pins
are absent. With no define, promoted metadata selects the pin and null metadata
selects the development no-asset state.

## Export control

`native/exports/` defines the intended ABI-2 set of six core and twelve Arrow
C Data/C Stream symbols for ELF, Mach-O, and
Windows. These files are intentionally dormant because wiring linker arguments
requires a reviewed Cargo/build configuration change. Until that happens,
release libraries may expose additional Rust/dependency symbols. The native
release matrix uses the pinned Rust toolchain's `llvm-nm` and
`tool/native_exports.py` to require all 18 advertised ABI symbols before
packaging. Exact allowlisting remains blocked until platform export-control
linker activation is safely wired and tested.

## Activation blockers and release checklist

1. Replace the current `0.1.0-dev.1` pubspec version with the same stable
   version used by Cargo and native release metadata. The release version
   contract intentionally fails until these versions agree.
2. Create and protect the GitHub repository, default branch, release
   environment, and tag policy after the initial repository is published.
3. Review Dependabot's proposed updates to the immutable action SHAs. Also
   confirm the five runner labels remain available to the repository,
   especially Linux arm64 and Intel macOS.
4. Review the exact Rust 1.98.0 supply chain and runner images. Decide and test
   the oldest supported glibc/macOS baseline; hosted-image labels do not by
   themselves constitute a compatibility guarantee.
5. Wire and test export-control files for an exact allowlist. The required-symbol
   inspection is active, but extra exports are currently permitted. Add malware
   scanning. Decide whether macOS code signing/notarization and Windows signing
   are required; no signing secrets or placeholder identities are present.
   Generate and independently review `native/THIRD_PARTY_LICENSES.txt` from the
   exact locked dependency graph before enabling a native build-only run.
6. Run a manual, non-publishing workflow first. Compare manifests/checksums,
   exercise each binary through Dart integration tests on clean machines, and
   retain the run provenance. The workflow runs Rust tests plus Dart native
   protocol, ownership, CSV, Parquet, and relational integration tests against
   every matrix-built library.
7. Review `native-assets.json` and provenance independently, promote generated
   metadata as a reviewed source commit, and only then create the final tag on
   that commit. Rerun the native workflow from exact `refs/tags/v<version>` with
   upload enabled and identify the reviewed source workflow run. It verifies
   tag provenance, permits only the metadata promotion diff, reuses the reviewed
   retained artifacts, and creates or updates a draft without overwriting
   assets or creating a tag.
8. Run `Prepare GitHub release` against the draft. It deliberately does not run
   ordinary Dart tests: a promoted hook cannot consume unauthenticated draft
   assets. It validates format, analysis, the publish archive, and direct draft
   assets/pins. Publish the draft manually, then require clean unauthenticated
   consumer smoke tests on all targets before pub publication. No workflow
   publishes to pub.dev; ownership/bootstrap and trusted-publishing approval
   remain deliberate manual activation steps.
