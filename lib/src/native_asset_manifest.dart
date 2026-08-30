import 'native_release_artifact.dart';
import 'native_release_metadata.dart';

export 'native_release_artifact.dart';
export 'native_release_metadata.dart';

/// The code-asset identifier shared by the build hook and `@Native` bindings.
const nativeAssetName = 'src/native_asset_bindings.dart';
const nativeAssetId = 'package:dartaframes_polars/$nativeAssetName';

/// The only repository identity used by native distribution code.
///
/// Change and review this constant before release if the canonical repository
/// moves.
const nativeReleaseRepository = 'https://github.com/richardrh/dartframes';

String nativeReleaseTarget(String os, String architecture) =>
    switch ((os, architecture)) {
      ('macos', 'arm64') => 'aarch64-apple-darwin',
      ('macos', 'x64') => 'x86_64-apple-darwin',
      ('linux', 'arm64') => 'aarch64-unknown-linux-gnu',
      ('linux', 'x64') => 'x86_64-unknown-linux-gnu',
      ('windows', 'x64') => 'x86_64-pc-windows-msvc',
      _ => '$architecture-$os-unsupported',
    };

/// Returns trusted pinned metadata, or fails before any network access.
NativeReleaseArtifact pinnedReleaseArtifact(
  String target, {
  Map<String, NativeReleaseArtifact> artifacts = nativeReleaseArtifacts,
}) {
  final artifact = artifacts[target];
  if (artifact == null) {
    throw UnsupportedError(
      'No pinned dartaframes_polars native release target for $target',
    );
  }
  if (!artifact.isPromoted) {
    throw StateError(
      'Pinned dartaframes_polars native releases are not active: '
      '${artifact.rawAssetName} has no trusted checksum and byte size',
    );
  }
  return artifact;
}

Uri nativeReleaseDownloadUri(
  NativeReleaseArtifact artifact, {
  Uri? repository,
}) {
  final base = repository ?? Uri.parse(nativeReleaseRepository);
  if (base.scheme != 'https' || base.host.isEmpty || base.hasQuery) {
    throw ArgumentError.value(base, 'repository', 'must be an HTTPS base URL');
  }
  final cleanPath = base.path.endsWith('/')
      ? base.path.substring(0, base.path.length - 1)
      : base.path;
  return base.replace(
    path:
        '$cleanPath/releases/download/v$nativeReleaseVersion/'
        '${artifact.rawAssetName}',
    fragment: '',
  );
}
