import 'dart:ffi';

import 'arrow_c.dart';
import 'native_asset_manifest.dart';

final class NativeAssetBuffer extends Struct {
  external Pointer<Uint8> data;

  @Uint64()
  external int length;

  @Int32()
  external int status;
}

typedef NativeAssetTokenRelease = Void Function(Pointer<Void>);
typedef NativeAssetArrowArrayDelete = Void Function(Pointer<CArrowArray>);
typedef NativeAssetArrowSchemaDelete = Void Function(Pointer<CArrowSchema>);
typedef NativeAssetArrowStreamDelete = Void Function(
  Pointer<CArrowArrayStream>,
);

@Native<Uint32 Function()>(symbol: 'df_abi_version', assetId: nativeAssetId)
external int nativeAssetAbiVersion();

@Native<Int32 Function(Pointer<Uint8>, Uint64, Pointer<NativeAssetBuffer>)>(
  symbol: 'df_invoke',
  assetId: nativeAssetId,
)
external int nativeAssetInvoke(
  Pointer<Uint8> request,
  int requestLength,
  Pointer<NativeAssetBuffer> output,
);

@Native<Void Function(Pointer<NativeAssetBuffer>)>(
  symbol: 'df_buffer_free',
  assetId: nativeAssetId,
)
external void nativeAssetBufferFree(Pointer<NativeAssetBuffer> output);

@Native<Int32 Function(Uint64)>(
  symbol: 'df_handle_release',
  assetId: nativeAssetId,
)
external int nativeAssetHandleRelease(int handle);

@Native<Pointer<Void> Function(Uint64)>(
  symbol: 'df_handle_token_new',
  assetId: nativeAssetId,
)
external Pointer<Void> nativeAssetHandleTokenNew(int handle);

@Native<NativeAssetTokenRelease>(
  symbol: 'df_handle_token_release',
  assetId: nativeAssetId,
)
external void nativeAssetHandleTokenRelease(Pointer<Void> token);

@Native<Pointer<CArrowArray> Function()>(
  symbol: 'df_arrow_array_new',
  assetId: nativeAssetId,
)
external Pointer<CArrowArray> nativeAssetArrowArrayNew();

@Native<Pointer<CArrowSchema> Function()>(
  symbol: 'df_arrow_schema_new',
  assetId: nativeAssetId,
)
external Pointer<CArrowSchema> nativeAssetArrowSchemaNew();

@Native<Pointer<CArrowArrayStream> Function()>(
  symbol: 'df_arrow_stream_new',
  assetId: nativeAssetId,
)
external Pointer<CArrowArrayStream> nativeAssetArrowStreamNew();

@Native<NativeAssetArrowArrayDelete>(
  symbol: 'df_arrow_array_delete',
  assetId: nativeAssetId,
)
external void nativeAssetArrowArrayDelete(Pointer<CArrowArray> pointer);

@Native<NativeAssetArrowSchemaDelete>(
  symbol: 'df_arrow_schema_delete',
  assetId: nativeAssetId,
)
external void nativeAssetArrowSchemaDelete(Pointer<CArrowSchema> pointer);

@Native<NativeAssetArrowStreamDelete>(
  symbol: 'df_arrow_stream_delete',
  assetId: nativeAssetId,
)
external void nativeAssetArrowStreamDelete(Pointer<CArrowArrayStream> pointer);

@Native<Int32 Function(Uint64, Pointer<CArrowArray>, Pointer<CArrowSchema>)>(
  symbol: 'df_frame_export_arrow',
  assetId: nativeAssetId,
)
external int nativeAssetFrameExportArrow(
  int handle,
  Pointer<CArrowArray> array,
  Pointer<CArrowSchema> schema,
);

@Native<Int32 Function(Uint64, Pointer<CArrowArray>, Pointer<CArrowSchema>)>(
  symbol: 'df_series_export_arrow',
  assetId: nativeAssetId,
)
external int nativeAssetSeriesExportArrow(
  int handle,
  Pointer<CArrowArray> array,
  Pointer<CArrowSchema> schema,
);

@Native<
  Int32 Function(Pointer<CArrowArray>, Pointer<CArrowSchema>, Pointer<Uint64>)
>(symbol: 'df_frame_import_arrow', assetId: nativeAssetId)
external int nativeAssetFrameImportArrow(
  Pointer<CArrowArray> array,
  Pointer<CArrowSchema> schema,
  Pointer<Uint64> output,
);

@Native<
  Int32 Function(Pointer<CArrowArray>, Pointer<CArrowSchema>, Pointer<Uint64>)
>(symbol: 'df_series_import_arrow', assetId: nativeAssetId)
external int nativeAssetSeriesImportArrow(
  Pointer<CArrowArray> array,
  Pointer<CArrowSchema> schema,
  Pointer<Uint64> output,
);

@Native<Int32 Function(Uint64, Uint64, Pointer<CArrowArrayStream>)>(
  symbol: 'df_frame_export_arrow_stream',
  assetId: nativeAssetId,
)
external int nativeAssetFrameExportArrowStream(
  int handle,
  int maxRows,
  Pointer<CArrowArrayStream> stream,
);

@Native<
  Int32 Function(Pointer<CArrowArrayStream>, Uint64, Uint64, Pointer<Uint64>)
>(symbol: 'df_frame_import_arrow_stream', assetId: nativeAssetId)
external int nativeAssetFrameImportArrowStream(
  Pointer<CArrowArrayStream> stream,
  int maxBatches,
  int maxRows,
  Pointer<Uint64> output,
);
