---
title: DartAframes
toc: false
---

# Native Polars for Dart

`dartaframes` is a Dart binding to Rust Polars. It supports lazy queries, eager
frames and Series, Arrow interchange, and bounded batch streaming through
native handles.

The project is a pre-release with partial Polars coverage. The package and
native binaries are not published yet. Source users build the native library
and open it with `Polars.open(path)`; `Polars.native()` is not available until
verified release assets exist.

{{< cards >}}
  {{< card link="docs/getting-started" title="Getting started" icon="book-open" subtitle="Build from source and run a CSV query" >}}
  {{< card link="api" title="API reference" icon="code" subtitle="Generated from public Dart source and exports" >}}
  {{< card link="https://github.com/richardrh/dartaframes" title="GitHub" icon="github" subtitle="Source, issues, and contribution guidance" >}}
{{< /cards >}}
