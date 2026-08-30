# CRAP quality gate

The repository-owned Dart tool `tool/crap_gate.dart` computes, per named Dart
function, method, and constructor:

`CRAP = complexity^2 * (1 - coverage)^3 + complexity`

Cyclomatic complexity is derived from the Dart analyzer AST (base path plus
branches, loops, catches, conditional expressions, switch cases, and boolean
short-circuit decisions). Coverage is the fraction of instrumented LCOV lines
inside the function body that have a positive hit count. A function or source
file absent from LCOV is deliberately treated as 0% covered, rather than being
silently omitted. Anonymous closures are not attributed to their enclosing
named function.

The gate is a baseline ratchet. An unbaselined function fails when its score is
**greater than 30**. A function in `tool/crap_baseline.json` may exceed 30, but
fails if it exceeds its explicit ceiling. Equality at either boundary passes,
and improvements pass without lowering the checked-in ceiling automatically.
The baseline contains only the ten known functions currently above 30.

Function keys are `<repository-relative source path>::<qualified function
name>/<formal parameter count>`; they deliberately exclude line numbers while
distinguishing Dart operators such as unary and binary `-`. `--baseline`
defaults to the checked-in baseline
(or `CRAP_BASELINE`) and is required, making the ratchet the default CI and
local behavior. Override the threshold with `--threshold` or `CRAP_THRESHOLD`.
Baseline ceilings must be finite and greater than the selected threshold.

New and regressed violations are separate in JSON and Markdown. Allowed debt
is disclosed as `baseline_debt`; entries for removed or improved-to-threshold
functions are reported as stale and should be deleted. A stale entry never
matches a different function and therefore cannot hide new debt.

## Reproduce

```sh
dart pub get --enforce-lockfile
rm -rf coverage
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info \
  --packages=.dart_tool/package_config.json \
  --report-on=lib
dart run tool/crap_gate.dart --threshold=30 --baseline=tool/crap_baseline.json
dart test tool/crap_gate_test.dart
```

Outputs are `coverage/crap.json` and `coverage/crap.md`. Exit codes are 0 for a
passing ratchet (known debt may remain), 1 for new or regressed violations, 2
for missing/invalid inputs (including the baseline), and 64 for invalid
options.

## Language scope

This gate scores Dart only. Dart's analyzer provides stable source function
boundaries and complexity nodes, which can be joined deterministically with
the VM's line coverage. Rust is intentionally not assigned approximate scores:
the workspace's FFI crate is macro-heavy and stable Rust/LCOV does not provide
portable per-function coverage identities that can be reliably joined to
source complexity. Obtaining LLVM coverage would also require compiling the
large Polars dependency a second time. Rust still receives locked tests in the
native matrix; a future Rust gate should use pinned `cargo-llvm-cov` function
regions plus a verified macro-aware complexity source, with explicit mapping
tests, before becoming blocking.
