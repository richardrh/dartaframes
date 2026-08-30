/// Direct native-handle access to Polars expressions, plans, frames, Series,
/// selectors, SQL, jobs, streaming, and Arrow interchange.
///
/// Create an installed-package runtime with [Polars.native]. During source
/// development, [Polars.open] loads an explicitly built native library.
library dartaframes_polars;

export 'arrow.dart';
export 'src/dtype.dart';
export 'src/arrow_c.dart'
    show ArrowCData, ArrowCStream, CArrowArray, CArrowArrayStream, CArrowSchema;
export 'src/errors.dart';
export 'src/native.dart' show NativeProtocolClient;
export 'src/native_asset_invoker.dart' show NativeAssetProtocolClient;
export 'src/polars.dart';
export 'src/protocol.dart';
export 'src/scalar.dart';
