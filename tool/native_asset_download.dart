import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:dartaframes/src/native_asset_manifest.dart';

typedef NativeAssetDownloader = Future<void> Function(
  Uri uri,
  File destination,
  int maximumBytes,
);

const _allowedDownloadHosts = <String>{
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};
const _requestTimeout = Duration(seconds: 30);
const _inactivityTimeout = Duration(seconds: 30);
const _totalTimeout = Duration(minutes: 3);
const _maximumRedirects = 3;
final _cacheQueues = <String, Future<void>>{};

/// Returns a verified cache entry, downloading it atomically when necessary.
Future<Uri> acquirePinnedNativeLibrary({
  required Uri outputDirectoryShared,
  required NativeReleaseArtifact artifact,
  Uri? downloadUri,
  NativeAssetDownloader downloader = downloadNativeAsset,
}) async {
  if (!artifact.isPromoted) {
    throw StateError(
      'Pinned native release ${artifact.rawAssetName} has not been promoted',
    );
  }
  final expectedSize = artifact.rawSize!;
  final expectedDigest = artifact.rawSha256!;
  if (Uri(path: artifact.rawAssetName).pathSegments.length != 1 ||
      artifact.rawAssetName == '.' ||
      artifact.rawAssetName == '..') {
    throw StateError('Pinned native asset name is not a safe file name');
  }
  final uri = downloadUri ?? nativeReleaseDownloadUri(artifact);
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty || uri.hasFragment) {
    throw ArgumentError.value(uri, 'downloadUri', 'must be an HTTPS URL');
  }

  final cache = File.fromUri(
    outputDirectoryShared.resolve(artifact.rawAssetName),
  );
  final previous = _cacheQueues[cache.path] ?? Future<void>.value();
  final release = Completer<void>();
  final current = release.future;
  _cacheQueues[cache.path] = current;
  await previous;
  try {
    await cache.parent.create(recursive: true);
    final lock = await File('${cache.path}.lock').open(mode: FileMode.append);
    var locked = false;
    try {
      await lock.lock(FileLock.exclusive);
      locked = true;
      return await _acquirePinnedNativeLibraryLocked(
        cache: cache,
        artifact: artifact,
        uri: uri,
        expectedSize: expectedSize,
        expectedDigest: expectedDigest,
        downloader: downloader,
      );
    } finally {
      if (locked) await lock.unlock();
      await lock.close();
    }
  } finally {
    release.complete();
    if (identical(_cacheQueues[cache.path], current)) {
      _cacheQueues.remove(cache.path);
    }
  }
}

Future<Uri> _acquirePinnedNativeLibraryLocked({
  required File cache,
  required NativeReleaseArtifact artifact,
  required Uri uri,
  required int expectedSize,
  required String expectedDigest,
  required NativeAssetDownloader downloader,
}) async {
  if (await _validFile(cache, expectedSize, expectedDigest)) return cache.uri;
  if (await cache.exists()) await cache.delete();

  final temporary = File(
    '${cache.path}.tmp-${pid}-${Random.secure().nextInt(1 << 32)}',
  );
  try {
    await downloader(uri, temporary, expectedSize);
    final actualSize = await temporary.length();
    if (actualSize != expectedSize) {
      throw StateError(
        'Native asset ${artifact.rawAssetName} has $actualSize bytes; '
        'expected $expectedSize',
      );
    }
    final digest = (await sha256.bind(temporary.openRead()).first).toString();
    if (digest != expectedDigest) {
      throw StateError(
        'Native asset ${artifact.rawAssetName} failed SHA-256 verification',
      );
    }
    await temporary.rename(cache.path);
    return cache.uri;
  } on SocketException catch (error) {
    throw StateError(
      'Unable to download verified native asset ${artifact.rawAssetName}; '
      'network is unavailable and no verified cache entry exists: $error',
    );
  } on TimeoutException catch (error) {
    throw StateError(
      'Timed out downloading verified native asset ${artifact.rawAssetName}; '
      'no verified cache entry exists: $error',
    );
  } on HttpException catch (error) {
    throw StateError(
      'Unable to download verified native asset ${artifact.rawAssetName}; '
      'the release server request failed and no verified cache entry exists: '
      '$error',
    );
  } on HandshakeException catch (error) {
    throw StateError(
      'Unable to download verified native asset ${artifact.rawAssetName}; '
      'the HTTPS connection failed and no verified cache entry exists: $error',
    );
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}

Future<bool> _validFile(
  File file,
  int expectedSize,
  String expectedHash,
) async {
  try {
    if (!await file.exists() || await file.length() != expectedSize)
      return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString() == expectedHash;
  } on FileSystemException {
    return false;
  }
}

/// HTTPS downloader used by the hook. Redirects remain inside GitHub's known
/// release-serving hosts and the body can never exceed [maximumBytes].
Future<void> downloadNativeAsset(
  Uri uri,
  File destination,
  int maximumBytes,
) async {
  if (maximumBytes <= 0)
    throw ArgumentError.value(maximumBytes, 'maximumBytes');
  final deadline = DateTime.now().add(_totalTimeout);
  var current = uri;
  for (var redirects = 0; redirects <= _maximumRedirects; redirects++) {
    _validateGitHubUri(current);
    final client = HttpClient()
      ..connectionTimeout = _requestTimeout
      ..autoUncompress = false;
    try {
      final request = await _beforeDeadline(
        client.getUrl(current),
        deadline,
        _requestTimeout,
      );
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      final response = await _beforeDeadline(
        request.close(),
        deadline,
        _requestTimeout,
      );
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == _maximumRedirects) {
          throw HttpException('Invalid or excessive native asset redirects');
        }
        current = current.resolve(location);
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Native asset server returned HTTP ${response.statusCode}',
          uri: current,
        );
      }
      if (response.headers.value(HttpHeaders.contentEncodingHeader) != null) {
        throw HttpException('Compressed HTTP responses are not accepted');
      }
      if (response.contentLength > maximumBytes) {
        throw StateError('Native asset response exceeds $maximumBytes bytes');
      }
      var received = 0;
      final sink = destination.openWrite(mode: FileMode.writeOnly);
      final iterator = StreamIterator<List<int>>(response);
      try {
        while (await _beforeDeadline(
          iterator.moveNext(),
          deadline,
          _inactivityTimeout,
        )) {
          final chunk = iterator.current;
          received += chunk.length;
          if (received > maximumBytes) {
            throw StateError(
              'Native asset response exceeds $maximumBytes bytes',
            );
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await iterator.cancel();
        await sink.close();
      }
      if (received != maximumBytes) {
        throw StateError(
          'Native asset response has $received bytes; expected $maximumBytes',
        );
      }
      return;
    } finally {
      client.close(force: true);
    }
  }
  throw StateError('Unreachable redirect state');
}

Future<T> _beforeDeadline<T>(
  Future<T> operation,
  DateTime deadline,
  Duration limit,
) {
  final remaining = deadline.difference(DateTime.now());
  if (remaining <= Duration.zero) {
    return Future<T>.error(
      TimeoutException('Native asset total download deadline exceeded'),
    );
  }
  return operation.timeout(remaining < limit ? remaining : limit);
}

void _validateGitHubUri(Uri uri) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.port != 443 ||
      !_allowedDownloadHosts.contains(uri.host.toLowerCase())) {
    throw ArgumentError.value(
      uri,
      'uri',
      'native release downloads must use an allowlisted GitHub HTTPS host',
    );
  }
}
