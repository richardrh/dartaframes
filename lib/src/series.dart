part of 'polars.dart';

/// An immutable, independently owned native Polars Series.
final class Series {
  Series._(this._runtime, int handle)
    : _owner = _HandleOwner(_runtime, handle) {
    _owner.attach();
  }

  final Polars _runtime;
  final _HandleOwner _owner;

  bool get isClosed => _owner.isClosed;
  void close() => _owner.close();

  Map<String, Object?> infoSync() {
    final lease = _owner.lease('Series');
    try {
      return _runtime._client.invokeSync('seriesInfo', {
        'series': lease.handle.toString(),
      });
    } finally {
      lease.end();
    }
  }

  Future<Map<String, Object?>> info() async {
    final lease = _owner.lease('Series');
    try {
      return await _runtime._client.invoke('seriesInfo', {
        'series': lease.handle.toString(),
      });
    } finally {
      lease.end();
    }
  }

  String nameSync() => infoSync()['name'] as String;
  DType dtypeSync() =>
      DType.fromJson((infoSync()['dtype'] as Map).cast<String, Object?>());
  int lengthSync() => infoSync()['length'] as int;
  int nullCountSync() => infoSync()['nullCount'] as int;

  ArrowArray exportSync([RecordBatchCodec codec = const RecordBatchCodec()]) {
    final lease = _owner.lease('Series');
    try {
      final response = _runtime._client.invokeSync('seriesExport', {
        'series': lease.handle.toString(),
      });
      return codec
          .decode({
            'columns': [response['column']],
          })
          .columns
          .single;
    } finally {
      lease.end();
    }
  }

  Future<ArrowArray> export([
    RecordBatchCodec codec = const RecordBatchCodec(),
  ]) async {
    final lease = _owner.lease('Series');
    try {
      final response = await _runtime._client.invoke('seriesExport', {
        'series': lease.handle.toString(),
      });
      return codec
          .decode({
            'columns': [response['column']],
          })
          .columns
          .single;
    } finally {
      lease.end();
    }
  }

  Series _input(String command, [Map<String, Object?> fields = const {}]) {
    final lease = _owner.lease('Series');
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync(command, {
          'series': lease.handle.toString(),
          ...fields,
        }),
      );
    } finally {
      lease.end();
    }
  }

  DataFrame toFrame() {
    final lease = _owner.lease('Series');
    try {
      return _runtime._adoptFrame(
        _runtime._client.invokeSync('seriesToFrame', {
          'series': lease.handle.toString(),
        }),
      );
    } finally {
      lease.end();
    }
  }

  Series rename(String name) {
    _validateName(name, 'name');
    return _input('seriesRename', {'name': name});
  }

  Series cast(DType dtype, {bool strict = true}) {
    if (!dtype.capabilities.cast) {
      throw ArgumentError.value(dtype, 'dtype', 'does not support casts');
    }
    return _input('seriesCast', {'dtype': dtype.toJson(), 'strict': strict});
  }

  Series slice(int offset, int length) {
    if (offset < -0x8000000000000000 || offset > 0x7fffffffffffffff) {
      throw RangeError.value(offset, 'offset', 'must fit signed 64-bit');
    }
    _validateUnsigned(length, 'length');
    return _input('seriesSlice', {'offset': offset, 'length': length});
  }

  Series head([int length = 5]) => slice(0, length);
  Series tail([int length = 5]) => slice(-length, length);
  Series reverse() => _input('seriesReverse');

  Series sort({
    bool descending = false,
    bool nullsLast = false,
    bool maintainOrder = false,
    bool multithreaded = true,
  }) => _input('seriesSort', {
    'descending': descending,
    'nullsLast': nullsLast,
    'maintainOrder': maintainOrder,
    'multithreaded': multithreaded,
  });

  Series filter(Series mask) {
    _runtime._requireSeries(mask);
    final leases = _leaseAll([_owner, mask._owner]);
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync('seriesFilter', {
          'series': leases[0].handle.toString(),
          'mask': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  Series dropNulls() => _input('seriesDropNulls');

  Series append(Series other) {
    _runtime._requireSeries(other);
    final leases = _leaseAll([_owner, other._owner]);
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync('seriesAppend', {
          'series': leases[0].handle.toString(),
          'other': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  Series gather(Series indices) {
    _runtime._requireSeries(indices);
    final leases = _leaseAll([_owner, indices._owner]);
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync('seriesGather', {
          'series': leases[0].handle.toString(),
          'indices': leases[1].handle.toString(),
        }),
      );
    } finally {
      _releaseAll(leases);
    }
  }

  Series unique({bool maintainOrder = false}) =>
      _input('seriesUnique', {'maintainOrder': maintainOrder});

  ArrowCData exportArrowC() {
    final lease = _owner.lease('Series');
    try {
      return _runtime._arrowC.exportSeries(lease.handle);
    } finally {
      lease.end();
    }
  }

  Series _binary(String operation, Object other) {
    _validateName(operation, 'operation');
    if (other is Series) {
      _runtime._requireSeries(other);
      final leases = _leaseAll([_owner, other._owner]);
      try {
        return _runtime._adoptSeries(
          _runtime._client.invokeSync('seriesBinary', {
            'left': leases[0].handle.toString(),
            'right': leases[1].handle.toString(),
            'op': operation,
          }),
        );
      } finally {
        _releaseAll(leases);
      }
    }
    final scalar = _runtime._scalar(other, null);
    final lease = _owner.lease('Series');
    try {
      return _runtime._adoptSeries(
        _runtime._client.invokeSync('seriesBinary', {
          'left': lease.handle.toString(),
          'scalar': scalar.toJson(),
          'op': operation,
        }),
      );
    } finally {
      lease.end();
    }
  }

  Series eq(Object other) => _binary('eq', other);
  Series eqValidity(Object other) => _binary('eqValidity', other);
  Series notEq(Object other) => _binary('notEq', other);
  Series notEqValidity(Object other) => _binary('notEqValidity', other);
  Series lt(Object other) => _binary('lt', other);
  Series ltEq(Object other) => _binary('ltEq', other);
  Series gt(Object other) => _binary('gt', other);
  Series gtEq(Object other) => _binary('gtEq', other);
  Series operator +(Object other) => _binary('add', other);
  Series operator -(Object other) => _binary('subtract', other);
  Series operator *(Object other) => _binary('multiply', other);
  Series operator /(Object other) => _binary('trueDivide', other);

  Scalar _aggregate(String operation) {
    final lease = _owner.lease('Series');
    try {
      final response = _runtime._client.invokeSync('seriesAggregate', {
        'series': lease.handle.toString(),
        'op': operation,
      });
      return Scalar.fromJson(
        (response['scalar'] as Map).cast<String, Object?>(),
      );
    } finally {
      lease.end();
    }
  }

  Scalar sum() => _aggregate('sum');
  Scalar mean() => _aggregate('mean');
  Scalar min() => _aggregate('min');
  Scalar max() => _aggregate('max');
  Scalar first() => _aggregate('first');
  Scalar last() => _aggregate('last');

  int _count(String operation) {
    final lease = _owner.lease('Series');
    try {
      return _runtime._client.invokeSync('seriesAggregate', {
            'series': lease.handle.toString(),
            'op': operation,
          })['value']
          as int;
    } finally {
      lease.end();
    }
  }

  int count() => _count('count');
  int nUnique() => _count('nUnique');
}
