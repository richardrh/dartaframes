---
title: Documentation
linkTitle: Documentation
weight: 1
---

`dartaframes` is a pre-release Dart binding to Rust Polars with partial API
coverage. The package and native binaries are not published yet. Start with a
source build and `Polars.open(path)`; `Polars.native()` remains unavailable
until verified release assets exist.

## For users

- [Getting started](/docs/getting-started/) — runtime setup, lazy queries, and
  handle ownership.
- [Build from source](/docs/build-from-source/) — install pinned tools with
  `mise` and build the current native library.
- [API reference](/api/) — generated documentation for the public Dart API.
- [API coverage](/docs/api-coverage/) — what the partial API covers in Polars.

## For maintainers and contributors

- [Native binaries](/docs/native-distribution/) — targets, asset review,
  caching, and activation.
- [Release process](/docs/releasing/) — native asset and pub release ordering.
- [CRAP quality gate](/docs/crap-quality-gate/) — complexity and coverage ratchet.
- [Protocol reference](https://github.com/richardrh/dartaframes/blob/master/protocol/README.md)
  — ABI, commands, capabilities, ownership, and errors.
- [Contributing](https://github.com/richardrh/dartaframes/blob/master/CONTRIBUTING.md)
  — setup, tests, and change requirements.
- [Security](https://github.com/richardrh/dartaframes/blob/master/SECURITY.md) —
  private vulnerability reporting.
- [Changelog](https://github.com/richardrh/dartaframes/blob/master/CHANGELOG.md) —
  release history.
