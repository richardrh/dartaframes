---
title: CRAP quality gate
weight: 12
---

> **Maintainer documentation:** this gate is part of repository CI, not the
> package API.

`tool/crap_gate.dart` computes this score for each named Dart function, method,
and constructor:

`CRAP = complexity^2 * (1 - coverage)^3 + complexity`

Complexity comes from the Dart analyzer AST: the base path, branches, loops,
catches, conditional expressions, switch cases, and short-circuit Boolean
decisions. Coverage is the share of instrumented LCOV lines in the function
body with hits. Missing functions or files count as 0% covered. Anonymous
closures are not assigned to their enclosing named function.

## Gate rules

The gate is a baseline ratchet. An unbaselined function fails when its score is
**greater than 30**. A function in `tool/crap_baseline.json` may exceed 30, but
fails if it exceeds its explicit ceiling. Equality at either boundary passes,
and improvements pass without lowering the checked-in ceiling automatically.
The baseline contains only the ten known functions above 30.

Function keys are `<repository-relative source path>::<qualified function
name>/<formal parameter count>`; they deliberately exclude line numbers while
distinguishing Dart operators such as unary and binary `-`. `--baseline`
defaults to the checked-in baseline
(or `CRAP_BASELINE`) and is required, making the ratchet the default CI and
local behavior. Override the threshold with `--threshold` or `CRAP_THRESHOLD`.
Baseline ceilings must be finite and greater than the selected threshold.

- Reports separate new and regressed violations.
- Allowed debt appears as `baseline_debt` in JSON and Markdown.
- Removed functions and functions improved to the threshold produce stale
  entries, which must be deleted.
- A stale entry cannot match another function or hide new debt.

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

Outputs are `coverage/crap.json` and `coverage/crap.md`.

| Exit | Meaning |
| --- | --- |
| 0 | Pass; known baseline debt may remain |
| 1 | New or regressed violation |
| 2 | Missing or invalid input, including the baseline |
| 64 | Invalid options |

## Language scope

This gate scores Dart only. The analyzer provides stable source function
boundaries and complexity nodes, which can be joined deterministically with
the VM's line coverage. Rust is intentionally not assigned approximate scores:
the workspace's FFI crate is macro-heavy and stable Rust/LCOV does not provide
portable per-function coverage identities that can be reliably joined to
source complexity. LLVM coverage would also compile the large Polars dependency
a second time. Rust still receives locked tests in the native matrix. A future
Rust gate should use pinned `cargo-llvm-cov` function regions and a verified,
macro-aware complexity source, with explicit mapping tests, before it blocks CI.
