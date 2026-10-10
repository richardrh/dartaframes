# DataFrame, Series, and Arrow example

The runnable [series_arrow_head.dart](series_arrow_head.dart) example reads the
included [CSV fixture](series_arrow_people.csv), prints the first three rows,
doubles the `age` column, and round-trips a frame through the Arrow C Data
Interface.

From the package source directory, run:

```sh
dart pub get
dart run example/series_arrow_head.dart
```

The default path uses `Polars.native()` and the package's native asset hook.
Use a supported desktop platform with an available native release artifact.
To use a locally built ABI-2 library instead, pass its path:

```sh
dart run example/series_arrow_head.dart --library /path/to/native-library
```

An optional CSV path can follow the library argument, or be the only argument.
The CSV must contain a numeric `age` column for the Series operation.

The example closes native-backed frames and the Arrow payload explicitly to
demonstrate deterministic resource cleanup.
