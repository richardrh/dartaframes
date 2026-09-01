import 'package:dartaframes/src/native_asset_manifest.dart';
import 'package:test/test.dart';

void main() {
  test('maps every supported Dart target to distribution metadata', () {
    expect(nativeReleaseTarget('macos', 'arm64'), 'aarch64-apple-darwin');
    expect(nativeReleaseTarget('macos', 'x64'), 'x86_64-apple-darwin');
    expect(nativeReleaseTarget('linux', 'arm64'), 'aarch64-unknown-linux-gnu');
    expect(nativeReleaseTarget('linux', 'x64'), 'x86_64-unknown-linux-gnu');
    expect(nativeReleaseTarget('windows', 'x64'), 'x86_64-pc-windows-msvc');
    expect(nativeReleaseArtifacts, hasLength(5));
  });

  const inactive = NativeReleaseArtifact(
    archiveName: 'example.tar.gz',
    libraryName: 'libexample.so',
    rawAssetName: 'example.so',
    rawSha256: null,
    rawSize: null,
  );
  const promoted = NativeReleaseArtifact(
    archiveName: 'example.tar.gz',
    libraryName: 'libexample.so',
    rawAssetName: 'example.so',
    rawSha256:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    rawSize: 12,
  );

  test('fixture metadata fails closed when inactive', () {
    expect(
      () => pinnedReleaseArtifact('fixture', artifacts: {'fixture': inactive}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('not active'), contains('no trusted checksum')),
        ),
      ),
    );
  });

  test('fixture metadata returns a promoted artifact', () {
    expect(
      pinnedReleaseArtifact('fixture', artifacts: {'fixture': promoted}),
      same(promoted),
    );
  });
}
