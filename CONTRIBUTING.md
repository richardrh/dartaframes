# Contributing

Thank you for improving DartAframes. Before starting a large API or protocol
change, open an issue so its scope and ownership semantics can be agreed.

By participating, you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

## Scope

The standalone Arrow core may implement standard schemas, arrays, validation
and IPC interoperability in pure Dart. Keep its imports independent of Polars,
FFI, native hooks and platform-only libraries. Verify wire-format changes
against an independent Arrow implementation, not only local round-trips.
Standard Arrow support does not automatically imply native Polars support.

For the Polars binding, expose upstream Polars behavior and the Arrow conversion
needed for FFI. Do not implement query kernels, rewrite SQL, emulate unsupported operations,
or add workbook/database adapters with independent inference or coercion rules.
Keep ownership, error translation, and FFI boundary validation in the binding.
Missing upstream functionality remains unsupported rather than being emulated.

## Set up

The easiest setup uses [mise](https://mise.jdx.dev/):

```sh
mise trust
mise install
mise run setup
mise run native:build
```

`mise.toml` installs the pinned Dart, Python, and Rust versions. Without mise,
use Dart 3.13 or later and the toolchain in `rust-toolchain.toml`, then run
`dart pub get --enforce-lockfile` and
`cargo build --locked --package dartaframes_polars_ffi`.

This is one root Dart package. Keep examples in `example/`, benchmarks in
`benchmark/`, and documentation in `doc/`.

## Validate changes

Run the checks relevant to the change; before submitting, run the complete
local set when practical:

```sh
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart doc --dry-run
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
  `doc/content/docs/api-coverage.md` synchronized.
- Add Dart tests under `test/` and Rust tests in the native crate as appropriate.
- Do not commit generated or local outputs such as `.dart_tool/`, `coverage/`,
  `target/`, `build/`, `dist/`, binaries, archives, or benchmark fixtures.
- Do not hand-edit generated native release metadata. Checksum promotion is a
  maintainer release task described in `doc/content/docs/releasing.md`.
- Do not broaden public claims beyond behavior verified by tests or native
  capabilities.

## Pull requests and review comments

Use the repository PR template. Explain the problem, the change, related issues,
validation evidence, and compatibility risks. Link an issue when one exists;
small fixes do not require a separate issue. Prefer descriptive titles such as
`Fix Arrow batch validation for empty columns` over vague progress updates.

- Keep one coherent purpose per PR. Split unrelated fixes into separate PRs.
- Record exact validation commands, outcomes, SDK/platform, and skipped checks.
  Native tests skipped without a library are not proof of native compatibility.
- Check checklist items only after completing them. Leave non-applicable items
  unchecked with an explanation, rather than claiming work that did not occur.
- Update the PR description when scope or results change. Maintain one concise
  validation summary instead of posting repeated status comments. Preserve
  reviewers' comments and distinguish older results from current evidence.
- In review replies, identify the change or commit addressing the concern and
  its verification. If disagreeing, explain the technical reason respectfully.
- Describe breaking changes and migration steps. For native changes, explain
  ownership, consumption, lifetime and cleanup behavior explicitly.
- Update `///` API comments and relevant examples/site docs. Include screenshots
  or a preview for rendered documentation changes. Update the changelog for
  user-visible changes; explain exemptions for process-only changes.
- Contributors remain responsible for correctness, tests and licensing of all
  submitted code, including AI-assisted changes.

These conventions draw on the focused-change checklist in
[Serverpod PR #5852](https://github.com/serverpod/serverpod/pull/5852),
[Flutter's PR template](https://github.com/flutter/flutter/blob/master/.github/PULL_REQUEST_TEMPLATE.md)
and the [Dart SDK contribution guide](https://github.com/dart-lang/sdk/blob/main/CONTRIBUTING.md).
Project-specific CLA or review-system requirements are not imported here.

## CI and lint policy

`analysis_options.yaml` includes `package:lints/core.yaml`; `lints` is pinned in
`dev_dependencies`. Dart's analyzer runs these lint rules, so a separate linter
command is not required. `.github/workflows/ci.yml` runs formatting and
`dart analyze --fatal-infos` on every pull request and push to `master`.
Informational lint findings fail that step. Do not suppress a lint merely to
make CI pass; explain any narrowly scoped exception in the PR.

The workflow also checks API documentation, Dart tests/coverage, the CRAP
baseline, Python tooling, Rust formatting and package publishability. Its
regular quality job does not build Rust or exercise native integration tests
without a library. Native changes need the additional native checks documented
above and the relevant native workflows. Checklists guide review; they are not
automatically enforced by CI, nor do they configure branch protection.
