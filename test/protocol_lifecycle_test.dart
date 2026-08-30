import 'dart:async';
import 'dart:ffi';

import 'package:dartaframes/polars.dart';
import 'package:test/test.dart';

final class DelayedInvoker implements ProtocolInvoker {
  final requests = <Map<String, Object?>>[];
  final released = <int>[];
  final responses = <Map<String, Object?>>[];
  final finalizerTargets = <Object>[];
  final detachedTokens = <Object?>[];
  Completer<void>? gate;
  int next = 1;
  bool detachReleases = false;
  Object? token;

  Map<String, Object?> _response(Map<String, Object?> request) {
    requests.add(request);
    return responses.isEmpty
        ? {'ok': true, 'handle': '${next++}'}
        : responses.removeAt(0);
  }

  @override
  Map<String, Object?> invokeSync(Map<String, Object?> request) =>
      _response(request);
  @override
  Future<Map<String, Object?>> invoke(Map<String, Object?> request) async {
    final pending = gate;
    if (pending != null) await pending.future;
    return _response(request);
  }

  @override
  void releaseHandle(int handle) => released.add(handle);
  @override
  Object? attachHandleFinalizer(Object owner, int handle) {
    finalizerTargets.add(owner);
    return token;
  }

  @override
  bool detachHandleFinalizer(Object? token) {
    detachedTokens.add(token);
    return detachReleases;
  }
}

void main() {
  test('client emits protocol 2 and parses cancelling state', () {
    final fake = DelayedInvoker()
      ..responses.add({'ok': true, 'state': 'cancelling'});
    final status = JobStatus.fromResponse(fake.invokeSync(const {}));
    expect(status.state, JobState.cancelling);
    expect(status.terminal, isFalse);

    fake.responses.add({'ok': true, 'abi': 1, 'protocol': 2});
    ProtocolClient(fake).helloSync();
    expect(fake.requests.last, {'protocol': 2, 'command': 'hello'});
  });

  test('source frame and fluent inputs are independent native owners', () {
    final fake = DelayedInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    // frameImport=1, frameLazy=2.
    final batchCodecOnly = p.scanCsv('source.csv');
    final branch = batchCodecOnly.head(1);
    batchCodecOnly.close();
    expect(fake.released, [1]);
    final output = branch.collectSync();
    expect(fake.requests.last, {
      'protocol': 2,
      'command': 'lazyCollect',
      'input': '2',
    });
    output.close();
    branch.close();
  });

  test('async lease defers close until delayed invocation finishes', () async {
    final fake = DelayedInvoker();
    final p = Polars.fromClient(ProtocolClient(fake));
    final frame = p.scanParquet('x');
    final owner = fake.finalizerTargets.single;
    expect(owner, isA<Finalizable>());
    expect(frame, isNot(isA<Finalizable>()));
    fake.gate = Completer<void>();
    final submit = frame.submit();
    frame.close();
    expect(fake.released, isEmpty);
    expect(fake.finalizerTargets, contains(same(owner)));
    fake.gate!.complete();
    final job = await submit;
    expect(fake.released, [1]);
    job.close();
    expect(fake.released, [1, 2]);
  });

  test('native hello parser freezes the complete capability surface', () {
    final fake = DelayedInvoker()
      ..responses.add({
        'ok': true,
        'abi': 1,
        'protocol': 2,
        'datatypes': ['null'],
        'datatypeCapabilities': [
          {'kind': 'null', 'descriptor': true},
        ],
        'resources': ['expr'],
        'interchange': {
          'types': 'flat',
          'nested': false,
          'dataTypes': ['int64'],
        },
        'commands': {
          'expression': ['exprLen'],
        },
      });
    final capabilities = ProtocolClient(fake).nativeCapabilitiesSync();
    expect(capabilities.datatypes, ['null']);
    expect(capabilities.datatypeCapabilities.single, {
      'kind': 'null',
      'descriptor': true,
    });
    expect(capabilities.resources, ['expr']);
    expect(capabilities.interchange['types'], 'flat');
    expect(
      () => (capabilities.interchange['dataTypes'] as List).add('struct'),
      throwsUnsupportedError,
    );
    expect(capabilities.commands['expression'], ['exprLen']);
    expect(
      () => (capabilities.commands['expression'] as List).add('bad'),
      throwsUnsupportedError,
    );
  });

  test('capability payload is deeply frozen and rejects malformed maps', () {
    final nested = <String, Object?>{
      'ok': true,
      'abi': 1,
      'protocol': 2,
      'commands': {
        'frame': ['frameInfo'],
      },
      'operations': {
        'options': {
          'sort': ['descending'],
        },
      },
    };
    final capabilities = NativeHelloCapabilities.fromHello(nested);
    nested['abi'] = 99;
    expect(capabilities.abi, 1);
    expect(
      () => ((capabilities.operations['options'] as Map)['sort'] as List).add(
        'bad',
      ),
      throwsUnsupportedError,
    );
    expect(() => capabilities.raw['extra'] = true, throwsUnsupportedError);
    expect(
      () => NativeHelloCapabilities.fromHello({'commands': []}),
      throwsFormatException,
    );
    expect(
      () => NativeHelloCapabilities.fromHello({'operations': 'bad'}),
      throwsFormatException,
    );
    expect(
      () => NativeHelloCapabilities.fromHello({'resources': 'bad'}),
      throwsA(isA<TypeError>()),
    );
    expect(
      () => NativeHelloCapabilities.fromHello({
        'commands': {1: const []},
      }),
      throwsA(isA<TypeError>()),
    );
  });

  test('protocol errors and malformed responses are classified', () async {
    final fake = DelayedInvoker()
      ..responses.addAll([
        {
          'ok': false,
          'error': {'category': 'invalidRequest', 'message': 'bad request'},
        },
        {
          'ok': false,
          'error': {'category': 'ioError', 'message': 'missing'},
        },
        {'ok': false, 'error': 'not an object'},
      ]);
    final client = ProtocolClient(fake);
    expect(client.helloSync, throwsA(isA<InvalidRequestException>()));
    await expectLater(client.hello(), throwsA(isA<PolarsIoException>()));
    expect(client.helloSync, throwsA(isA<InternalPolarsException>()));

    final categories = <String, Type>{
      'unsupported': UnsupportedPolarsException,
      'compute': ComputeException,
      'executionError': ComputeException,
      'io': PolarsIoException,
      'cancelled': QueryCancelledException,
      'staleHandle': StaleHandleException,
      'invalidHandle': StaleHandleException,
      'protocolMismatch': ProtocolMismatchException,
      'protocolError': ProtocolMismatchException,
      'futureCategory': InternalPolarsException,
    };
    for (final entry in categories.entries) {
      final error = PolarsException.fromJson({'category': entry.key});
      expect(error.message, 'Native protocol error');
      expect(error.runtimeType, entry.value);
    }
    expect(
      PolarsException.fromJson({'category': 'futureCategory'}),
      isA<InternalPolarsException>(),
    );
  });

  test('success marker must be exactly true', () async {
    final fake = DelayedInvoker()
      ..responses.addAll([
        {'ok': 'true', 'handle': '1'},
        {'handle': '2'},
      ]);
    final client = ProtocolClient(fake);

    expect(client.helloSync, throwsA(isA<InternalPolarsException>()));
    await expectLater(client.hello(), throwsA(isA<InternalPolarsException>()));
  });

  test('malformed handles fail adoption without attaching finalizers', () {
    for (final handle in <Object?>[null, 0, -1, '0', 'not-a-handle']) {
      final fake = DelayedInvoker()
        ..responses.add({'ok': true, 'handle': handle});
      final polars = Polars.fromClient(ProtocolClient(fake));
      expect(() => polars.scanCsv('x.csv'), throwsFormatException);
      expect(fake.finalizerTargets, isEmpty);
    }
  });

  test('finalizer-owned release is detached once without double release', () {
    final token = Object();
    final fake = DelayedInvoker()
      ..token = token
      ..detachReleases = true;
    final frame = Polars.fromClient(ProtocolClient(fake)).scanCsv('x.csv');
    frame.close();
    frame.close();
    expect(fake.detachedTokens, [same(token)]);
    expect(fake.released, isEmpty);
    expect(() => frame.head(), throwsA(isA<StaleHandleException>()));
  });

  test('job poll, wait, cancel and take use job fields', () async {
    final fake = DelayedInvoker()
      ..responses.addAll([
        {'ok': true, 'handle': '1'},
        {'ok': true, 'handle': '9'},
        {'ok': true, 'state': 'cancelling'},
        {'ok': true, 'state': 'complete'},
        {'ok': true, 'ready': true, 'handle': '11'},
      ]);
    final p = Polars.fromClient(ProtocolClient(fake));
    final lazy = p.scanParquet('x');
    final job = await lazy.submit();
    expect((await job.poll()).state, JobState.cancelling);
    await job.wait(pollInterval: Duration.zero);
    final frame = await job.take();
    expect(fake.requests.skip(2).map((x) => x['command']), [
      'jobPoll',
      'jobPoll',
      'jobTake',
    ]);
    expect(fake.requests.skip(2).every((x) => x['job'] == '9'), isTrue);
    expect(job.isClosed, isTrue);
    frame.close();
    lazy.close();
  });

  test('cancel closes deterministically', () async {
    final fake = DelayedInvoker()
      ..responses.addAll([
        {'ok': true, 'handle': '1'},
        {'ok': true, 'handle': '9'},
        {'ok': true, 'cancelRequested': true},
      ]);
    final p = Polars.fromClient(ProtocolClient(fake));
    final lazy = p.scanCsv('x');
    final job = await lazy.submit();
    await job.cancel();
    expect(job.isClosed, isTrue);
    expect(fake.requests.last['job'], '9');
    expect(fake.released, contains(9));
    lazy.close();
  });

  test(
    'job rejects overlap, retains not-ready result, and closes on bad poll',
    () async {
      final fake = DelayedInvoker()
        ..responses.addAll([
          {'ok': true, 'handle': '1'},
          {'ok': true, 'handle': '9'},
        ]);
      final lazy = Polars.fromClient(ProtocolClient(fake)).scanCsv('x.csv');
      final job = await lazy.submit();

      fake
        ..gate = Completer<void>()
        ..responses.add({'ok': true, 'state': 'running'});
      final poll = job.poll();
      expect(job.poll, throwsStateError);
      fake.gate!.complete();
      await poll;

      fake
        ..gate = null
        ..responses.add({'ok': true, 'ready': false});
      await expectLater(job.take(), throwsStateError);
      expect(job.isClosed, isFalse);

      fake.responses.add({'ok': true, 'state': 'unknown'});
      await expectLater(job.poll(), throwsFormatException);
      expect(job.isClosed, isTrue);
      expect(fake.released, contains(9));
      lazy.close();
    },
  );
}
