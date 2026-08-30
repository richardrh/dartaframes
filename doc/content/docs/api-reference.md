---
title: API reference
weight: 3
---

The API reference documents exported declarations, signatures, and comments
from the package's two public entrypoints:

- `package:dartaframes/polars.dart` — the primary Polars and
  Arrow API.
- `package:dartaframes/arrow.dart` — the focused owned Arrow
  value API, also re-exported by the primary library.

[Browse the generated Dart API reference](/api/)

It shows what exists in Dart. The [API coverage audit](/docs/api-coverage/)
compares that API with Polars 0.55.2, including partial and missing families.

## How it is generated

`dart doc` reads `dartdoc_options.yaml`, which includes only
`dartaframes_arrow` and `dartaframes_polars`. The documentation `Makefile`
writes dartdoc to `doc/static/api`; Hugo copies it to `doc/public/api`. CI runs
`dart doc --dry-run` without writing site output.
