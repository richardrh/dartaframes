@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dartaframes/src/native_asset_manifest.dart';
import 'package:test/test.dart';

import '../tool/native_asset_download.dart';

void main() {
  const bytes = <int>[1, 2, 3, 4];
  final artifact = NativeReleaseArtifact(
    archiveName: 'unused.tar.gz',
    libraryName: 'libexample.so',
    rawAssetName: 'example-x86_64.so',
    rawSha256: sha256.convert(bytes).toString(),
    rawSize: bytes.length,
  );
  late Directory temporary;

  setUp(() => temporary = Directory.systemTemp.createTempSync('native-cache-'));
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<Uri> acquire(NativeAssetDownloader downloader) =>
      acquirePinnedNativeLibrary(
        outputDirectoryShared: temporary.uri,
        artifact: artifact,
        downloadUri: Uri.parse('https://example.invalid/example.so'),
        downloader: downloader,
      );

  Future<void> writeBytes(File destination, List<int> value) async {
    final sink = destination.openWrite();
    for (final byte in value) {
      sink.add([byte]);
    }
    await sink.close();
  }

  test('downloads and atomically caches a valid raw library', () async {
    final result = await acquire(
      (_, destination, _) => writeBytes(destination, bytes),
    );
    expect(File.fromUri(result).readAsBytesSync(), bytes);
    expect(
      temporary.listSync().whereType<File>().map((file) => file.path),
      everyElement(isNot(contains('.tmp-'))),
    );
  });

  test('validates and uses a cache hit without network access', () async {
    await acquire((_, destination, _) => writeBytes(destination, bytes));
    final result = await acquire((_, _, _) => throw SocketException('offline'));
    expect(File.fromUri(result).readAsBytesSync(), bytes);
  });

  test('discards a corrupt cache entry and replaces it', () async {
    File('${temporary.path}/${artifact.rawAssetName}').writeAsBytesSync([9, 9]);
    var calls = 0;
    final result = await acquire((_, destination, _) async {
      calls++;
      await writeBytes(destination, bytes);
    });
    expect(calls, 1);
    expect(File.fromUri(result).readAsBytesSync(), bytes);
  });

  test('serializes concurrent acquisition of one shared cache entry', () async {
    final firstDownloadStarted = Completer<void>();
    final releaseFirstDownload = Completer<void>();
    var calls = 0;

    Future<void> downloader(Uri _, File destination, int _) async {
      calls++;
      if (calls == 1) {
        firstDownloadStarted.complete();
        await releaseFirstDownload.future;
      }
      await writeBytes(destination, bytes);
    }

    final first = acquire(downloader);
    await firstDownloadStarted.future;
    final second = acquire(downloader);
    releaseFirstDownload.complete();

    final results = await Future.wait([first, second]);
    expect(calls, 1);
    expect(results[0], results[1]);
    expect(File.fromUri(results.first).readAsBytesSync(), bytes);
  });

  test('offline without a valid cache fails clearly', () async {
    await expectLater(
      acquire((_, _, _) => throw const SocketException('offline')),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('network is unavailable'),
            contains('no verified cache'),
          ),
        ),
      ),
    );
  });

  test('rejects oversized content and leaves no cache', () async {
    await expectLater(
      acquire((_, destination, _) => writeBytes(destination, [...bytes, 5])),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('bytes'),
        ),
      ),
    );
    expect(
      File('${temporary.path}/${artifact.rawAssetName}').existsSync(),
      isFalse,
    );
  });

  test('rejects a wrong hash and leaves no cache', () async {
    await expectLater(
      acquire((_, destination, _) => writeBytes(destination, [4, 3, 2, 1])),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('SHA-256'),
        ),
      ),
    );
    expect(
      File('${temporary.path}/${artifact.rawAssetName}').existsSync(),
      isFalse,
    );
  });

  test(
    'default downloader rejects non-allowlisted and non-HTTPS URLs',
    () async {
      await expectLater(
        downloadNativeAsset(
          Uri.parse('https://example.com/file'),
          File('${temporary.path}/download'),
          4,
        ),
        throwsArgumentError,
      );
      await expectLater(
        downloadNativeAsset(
          Uri.parse('http://github.com/file'),
          File('${temporary.path}/download'),
          4,
        ),
        throwsArgumentError,
      );
    },
  );
}
