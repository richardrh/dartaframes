# Contributing

Thank you for improving DartAframes. Before starting a large API or protocol
change, open an issue so its scope and ownership semantics can be agreed.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Set up

Use Dart 3.13 or later and the Rust toolchain pinned by `rust-toolchain.toml`.
From the repository root:

```sh
dart pub get --enforce-lockfile
cargo build --locked --package dartaframes_polars_ffi
```

This is one root Dart package. Keep examples in `example/`, benchmarks in
`benchmark/`, and documentation in `doc/`.

## Validate changes

Run the checks relevant to the change; before submitting, run the complete
local set when practical:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --coverage=coverage
dart test tool/crap_gate_test.dart
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info \
  --packages=.dart_tool/package_config.json --report-on=lib
dart run tool/crap_gate.dart --threshold=30 --baseline=tool/crap_baseline.json
python3 -m unittest discover -s tool -p 'test_native_*.py'
cargo fmt --all -- --check
dart pub publish --dry-run
cargo test --locked --workspace
```

Native Dart integration tests require a built library. On macOS:

```sh
cargo build --locked --package dartaframes_polars_ffi
DARTAFRAMES_NATIVE_LIBRARY="$PWD/target/debug/libdartaframes_polars_ffi.dylib" \
  dart test test/native_integration_test.dart test/io_relational_native_test.dart
```

Use the corresponding debug `.so` on Linux or `.dll` on Windows.

## Change guidelines

- Preserve direct native-handle and deterministic `close()` semantics. Add
  lifecycle tests for new handle-producing operations.
- Keep Dart, native dispatch, capabilities, protocol documentation, and
  `API_COVERAGE.md` synchronized.
- Add Dart tests under `test/` and Rust tests in the native crate as appropriate.
- Do not commit generated or local outputs such as `.dart_tool/`, `coverage/`,
  `target/`, `build/`, `dist/`, binaries, archives, or benchmark fixtures.
- Do not hand-edit generated native release metadata. Checksum promotion is a
  maintainer release task described in `doc/releasing.md`.
- Do not broaden public claims beyond behavior verified by tests or native
  capabilities.

Submit a focused pull request that explains behavior and ownership changes,
tests performed, and any unsupported cases left intentionally out of scope.
