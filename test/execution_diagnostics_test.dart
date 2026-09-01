import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class _ExecutionInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  int attachments = 0;
  int? failAttachment;
  Map<String, Object?>? profileResponse;

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) {
    requests.add(Map<String, Object?>.unmodifiable(request));
    return switch (request['command']) {
      'lazyExplain' => {'ok': true, 'explanation': 'plan'},
      'lazyProfile' =>
        profileResponse ??
            {'ok': true, 'resultHandle': '20', 'timingsHandle': '21'},
      'runtimeDiagnostics' => {
        'ok': true,
        'activeHandles': 2,
        'handlesByKind': {'lazyFrame': 1, 'frame': 1},
        'slotCapacity': 3,
        'reusableSlots': 1,
      },
      _ => {'ok': true, 'handle': '10'},
    };
  }

  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async =>
      invokeSync(request);

  @override
  void releaseHandle(int handle) => released.add(handle);

  @override
  Object? attachHandleFinalizer(Object owner, int handle) {
    attachments++;
    if (attachments == failAttachment) throw StateError('attach failed');
    return null;
  }

  @override
  bool detachHandleFinalizer(Object? token) => false;
}

void main() {
  test(
    'execution and explain options use exact Polars 0.55.2 wire names',
    () async {
      final fake = _ExecutionInvoker();
      final polars = Polars.fromClient(ProtocolClient(fake));
      final lazy = polars.scanCsv('input.csv');
      const optimizer = OptimizerOptions(
        projectionPushdown: false,
        predicatePushdown: false,
        clusterWithColumns: false,
        typeCoercion: false,
        simplifyExpression: false,
        typeCheck: false,
        slicePushdown: false,
        commonSubplanElimination: false,
        commonSubexpressionElimination: true,
        rowEstimate: false,
        fastProjection: false,
        checkOrderObserve: false,
        sortCollapse: false,
        partitionHive: false,
      );
      const options = ExecutionOptions(
        engine: ExecutionEngine.streaming,
        optimizer: optimizer,
      );

      final frame = lazy.collectSync(options: options);
      expect(fake.requests.last, containsPair('engine', 'streaming'));
      expect(fake.requests.last, containsPair('projectionPushdown', false));
      expect(fake.requests.last, containsPair('predicatePushdown', false));
      expect(fake.requests.last, containsPair('clusterWithColumns', false));
      expect(fake.requests.last, containsPair('typeCoercion', false));
      expect(fake.requests.last, containsPair('simplifyExpression', false));
      expect(fake.requests.last, containsPair('typeCheck', false));
      expect(fake.requests.last, containsPair('slicePushdown', false));
      expect(
        fake.requests.last,
        containsPair('commonSubplanElimination', false),
      );
      expect(
        fake.requests.last,
        containsPair('commonSubexpressionElimination', true),
      );
      expect(fake.requests.last, containsPair('partitionHive', false));
      expect(fake.requests.last, containsPair('rowEstimate', false));
      expect(fake.requests.last, containsPair('fastProjection', false));
      expect(fake.requests.last, containsPair('checkOrderObserve', false));
      expect(fake.requests.last, containsPair('sortCollapse', false));

      final beforeRejectedSubmit = fake.requests.length;
      await expectLater(
        lazy.submit(
          options: const ExecutionOptions(engine: ExecutionEngine.inMemory),
        ),
        throwsUnsupportedError,
      );
      expect(fake.requests, hasLength(beforeRejectedSubmit));
      final job = await lazy.submit();
      expect(
        lazy.explainSync(format: ExplainFormat.tree, optimized: false),
        'plan',
      );
      expect(fake.requests.last, containsPair('format', 'tree'));
      expect(fake.requests.last, containsPair('optimized', false));
      await lazy.explain(format: ExplainFormat.logicalDot);
      expect(fake.requests.last, containsPair('format', 'dot'));

      job.close();
      frame.close();
      lazy.close();
    },
  );

  test(
    'profile adopts both frames and rolls back either attachment failure',
    () {
      final fake = _ExecutionInvoker();
      final polars = Polars.fromClient(ProtocolClient(fake));
      final lazy = polars.scanCsv('input.csv');
      final profile = lazy.profileSync(
        optimizer: const OptimizerOptions(slicePushdown: false),
      );
      expect(fake.requests.last, containsPair('slicePushdown', false));
      profile.close();
      expect(fake.released, containsAll([20, 21]));
      lazy.close();

      // Attachment 1 belongs to the lazy input. Exercise rollback when either
      // returned frame fails to attach its finalizer.
      for (final failedAttachment in [2, 3]) {
        final failing = _ExecutionInvoker()..failAttachment = failedAttachment;
        final secondPolars = Polars.fromClient(ProtocolClient(failing));
        final input = secondPolars.scanCsv('input.csv');
        expect(input.profileSync, throwsStateError);
        expect(failing.released, containsAll([20, 21]));
        input.close();
      }
    },
  );

  test('malformed profile responses release every valid returned handle', () {
    for (final malformed in <Map<String, Object?>>[
      {'ok': true, 'resultHandle': '20', 'timingsHandle': 'invalid'},
      {'ok': true, 'resultHandle': 'invalid', 'timingsHandle': '21'},
      {'ok': true, 'resultHandle': '20', 'timingsHandle': '20'},
    ]) {
      final fake = _ExecutionInvoker()..profileResponse = malformed;
      final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('input.csv');

      expect(lazy.profileSync, throwsFormatException);
      final expected = <int>{
        if (malformed['resultHandle'] == '20') 20,
        if (malformed['timingsHandle'] == '21') 21,
      };
      expect(fake.released.toSet(), expected);
      lazy.close();
    }
  });

  test('execution defaults stay absent from the protocol request', () {
    final fake = _ExecutionInvoker();
    final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('input.csv');
    final result = lazy.collectSync();

    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyCollect',
      'input': '10',
    });

    result.close();
    lazy.close();
  });

  test('runtime diagnostics are a frozen read-only snapshot', () {
    final fake = _ExecutionInvoker();
    final polars = Polars.fromClient(ProtocolClient(fake));
    final diagnostics = polars.runtimeDiagnosticsSync();
    expect(diagnostics.activeHandles, 2);
    expect(diagnostics.handlesByKind['lazyFrame'], 1);
    expect(
      () => diagnostics.handlesByKind['frame'] = 0,
      throwsUnsupportedError,
    );
    expect(fake.requests.single['command'], 'runtimeDiagnostics');
  });
}
