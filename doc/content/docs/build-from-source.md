---
title: Build from source
weight: 2
---

Use this path until verified prebuilt binaries are published. It compiles Rust
Polars locally and can take significant time and disk space on the first run.

## System compiler

Install the native compiler and linker for your platform before using mise:

| Platform | Requirement |
| --- | --- |
| macOS | Xcode Command Line Tools (`xcode-select --install`) |
| Linux | GCC or Clang and the system development tools (for example, `build-essential` on Ubuntu) |
| Windows | Visual Studio 2022 Build Tools with **Desktop development with C++** |

Mise installs the language toolchains below, but not these system components.

## Install the tools

Install [mise](https://mise.jdx.dev/getting-started.html), clone the repository,
then run:

```sh
mise trust
mise install
mise run setup
mise run native:build
```

`mise.toml` pins Dart 3.13.0, Python 3.12, and Rust 1.98.0. The Rust version
matches `rust-toolchain.toml`.

## Run the example

Choose the library produced for your platform:

| Platform | Debug library |
| --- | --- |
| macOS | `target/debug/libdartaframes_polars_ffi.dylib` |
| Linux | `target/debug/libdartaframes_polars_ffi.so` |
| Windows | `target/debug/dartaframes_polars_ffi.dll` |

On macOS, for example:

```sh
dart run example/series_arrow_head.dart \
  --library "$PWD/target/debug/libdartaframes_polars_ffi.dylib"
```

Use the matching path from the table on Linux or Windows.

## Validate the native build

On macOS, set `DARTAFRAMES_NATIVE_LIBRARY` to the absolute library path and run:

```sh
DARTAFRAMES_NATIVE_LIBRARY="$PWD/target/debug/libdartaframes_polars_ffi.dylib" \
  dart test test/native_integration_test.dart test/io_relational_native_test.dart
```

Use the `.so` path on Linux. In Windows PowerShell:

```powershell
$env:DARTAFRAMES_NATIVE_LIBRARY = (Resolve-Path target\debug\dartaframes_polars_ffi.dll).Path
dart test test/native_integration_test.dart test/io_relational_native_test.dart
```

This source-build setup is for contributors and early adopters. Once release
binaries are available, ordinary applications will use `Polars.native()` and
will not need `mise` or Rust.
