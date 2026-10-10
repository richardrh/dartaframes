part of 'ipc.dart';

// Body layouts for the extended standard types (views, fixed-size binary,
// decimal32/64/256, map, union, interval, run-end encoded). Placeholder until
// the dedicated implementation lands: these types are rejected explicitly.

void _writeExtendedValues(
  _BodyWriter w,
  ArrowDataType type,
  List<ArrowValue?> values,
) => throw UnsupportedError(
  'Arrow IPC body encoding for $type is not implemented',
);

List<ArrowValue?> _readExtendedValues(_BodyReader r, ArrowDataType type) =>
    throw UnsupportedError(
      'Arrow IPC body decoding for $type is not implemented',
    );
