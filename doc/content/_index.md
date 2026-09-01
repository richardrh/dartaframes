---
title: DartAframes
toc: false
---

# Native Polars and Arrow for Dart

Scan CSV and Parquet with native Rust Polars, build lazy queries in Dart, and
work with an owned Apache Arrow columnar data model. `dartaframes` includes eager
frames and Series, Arrow C Data/C Stream interchange, and bounded batch
streaming.

The project is a pre-release with partial Polars coverage. The package and
native binaries are not published yet. Source users build the native library
and open it with `Polars.open(path)`; `Polars.native()` is not available until
verified release assets exist.

{{< cards >}}
  {{< card link="docs/getting-started" title="Getting started" icon="book-open" subtitle="Scan CSV and Parquet with concise lazy queries" >}}
  {{< card link="docs/arrow-interchange" title="Arrow for Dart" icon="code" subtitle="Owned arrays, schemas, record batches, and C interchange" >}}
  {{< card link="api" title="API reference" icon="code" subtitle="Generated from public Dart source and exports" >}}
  {{< card link="https://github.com/richardrh/dartaframes" title="GitHub" icon="github" subtitle="Source, issues, and contribution guidance" >}}
{{< /cards >}}
