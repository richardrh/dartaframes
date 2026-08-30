/// Metadata required to consume one immutable native release artifact.
final class NativeReleaseArtifact {
  const NativeReleaseArtifact({
    required this.archiveName,
    required this.libraryName,
    required this.rawAssetName,
    required this.rawSha256,
    required this.rawSize,
  });

  final String archiveName;
  final String libraryName;

  /// The uniquely named, uncompressed library attached to the GitHub release.
  final String rawAssetName;

  /// Trusted raw-library values. They stay null until a release is promoted.
  final String? rawSha256;
  final int? rawSize;

  bool get isPromoted {
    final digest = rawSha256;
    final size = rawSize;
    return rawAssetName.isNotEmpty &&
        digest != null &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) &&
        size != null &&
        size > 0;
  }
}
