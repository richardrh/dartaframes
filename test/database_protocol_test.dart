import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class DatabaseInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  final targets = <Object>[];
  int nextHandle = 1;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(request);
    return switch (request['command']) {
      'databaseConnectionExecute' => {'ok': true, 'rowsAffected': 3},
      'databaseConnectionWriteFrame' => {'ok': true, 'rowsWritten': 2},
      _ => {'ok': true, 'handle': '${nextHandle++}'},
    };
  }

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) {
    targets.add(owner);
    return null;
  }

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test(
    'SQLite API emits closed schemas, scalar parameters, and owned handles',
    () {
      final invoker = DatabaseInvoker();
      final polars = Polars.fromClient(ProtocolClient(invoker));
      final database = polars.openSqlite('data/local.db');
      expect(invoker.requests.single, {
        'protocol': 2,
        'command': 'databaseConnectionOpenSqlite',
        'path': 'data/local.db',
      });

      final frame = database.querySync(
        'SELECT ?1 AS id, ?2 AS name, ?3 AS payload',
        parameters: [
          7,
          'seven',
          [1, 2, 3],
        ],
      );
      expect(invoker.requests.last, {
        'protocol': 2,
        'command': 'databaseConnectionQuery',
        'connection': '1',
        'sql': 'SELECT ?1 AS id, ?2 AS name, ?3 AS payload',
        'parameters': [
          {
            'dtype': {'kind': 'int64'},
            'value': '7',
          },
          {
            'dtype': {'kind': 'string'},
            'value': 'seven',
          },
          {
            'dtype': {'kind': 'binary'},
            'base64': 'AQID',
          },
        ],
      });
      expect(
        database.executeSync(
          'DELETE FROM items WHERE id = ?1',
          parameters: [7],
        ),
        3,
      );
      expect(
        database.writeFrameSync(
          frame,
          'items',
          ifExists: DatabaseIfExists.append,
        ),
        2,
      );
      expect(invoker.requests.last, {
        'protocol': 2,
        'command': 'databaseConnectionWriteFrame',
        'connection': '1',
        'frame': '2',
        'table': 'items',
        'ifExists': 'append',
      });

      database.close();
      expect(invoker.released, [1]);
      expect(frame.isClosed, isFalse);
      frame.close();
      expect(invoker.released, [1, 2]);
    },
  );

  test(
    'SQLite validation rejects remote and unsafe inputs before transport',
    () {
      final invoker = DatabaseInvoker();
      final polars = Polars.fromClient(ProtocolClient(invoker));
      for (final path in [':memory:', 'file:test.db', 'https://example/db']) {
        expect(() => polars.openSqlite(path), throwsArgumentError);
      }
      expect(invoker.requests, isEmpty);

      final database = polars.openSqlite('local.db');
      final baseline = invoker.requests.length;
      expect(() => database.querySync(''), throwsArgumentError);
      expect(
        () =>
            database.executeSync('SELECT 1', parameters: List.filled(10001, 1)),
        throwsArgumentError,
      );
      expect(invoker.requests, hasLength(baseline));
      database.close();
    },
  );
}
