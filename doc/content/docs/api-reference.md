---
title: API reference
weight: 3
---

The API reference documents exported declarations, signatures, and comments
from the package's two public entrypoints:

- `package:dartaframes/polars.dart` — native Polars queries, frames, Series, and
  the re-exported Arrow value API.
- `package:dartaframes/arrow.dart` — the focused Dart implementation of owned
  Arrow schemas, arrays, values, builders, and record batches.

The Arrow entrypoint is a real Dart columnar value model, not merely Polars
conversion helpers. Its current scope and standard C interface support are
described in [Arrow interoperability](/docs/arrow-interchange/).

[Browse the generated Dart API reference](/api/)

It shows what exists in Dart. The [API coverage audit](/docs/api-coverage/)
compares that API with Polars 0.55.2, including partial and missing families.

## How it is generated

`dart doc` reads `dartdoc_options.yaml`, which includes only
`dartaframes_arrow` and `dartaframes_polars`. The documentation `Makefile`
writes dartdoc to `doc/static/api`; Hugo copies it to `doc/public/api`. CI runs
`dart doc --dry-run` without writing site output.
