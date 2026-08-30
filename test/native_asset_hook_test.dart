@TestOn('vm')
library;

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:test/test.dart';

import '../hook/build.dart' as hook;
import '../tool/native_asset_build.dart';

import 'package:dartaframes/src/native_asset_manifest.dart';

void main() {
  test('bundles a local custom_library without building it', () async {
    final temporary = Directory.systemTemp.createTempSync(
      'dartaframes-native-hook-',
    );
    addTearDown(() => temporary.deleteSync(recursive: true));
    final library = File('${temporary.path}/libdartaframes_polars_ffi.dylib')
      ..writeAsBytesSync([1]);

    await testCodeBuildHook(
      mainMethod: hook.main,
      targetOS: OS.macOS,
      targetArchitecture: Architecture.arm64,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {'custom_library': library.path},
          basePath: temporary.uri,
        ),
      ),
      check: (_, output) {
        expect(output.assets.code, hasLength(1));
        final asset = output.assets.code.single;
        expect(asset.id, endsWith('/src/native_asset_bindings.dart'));
        expect(asset.file, library.uri);
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
      },
    );
  });

  test('default source selection follows injected metadata state', () {
    const inactive = NativeReleaseArtifact(
      archiveName: 'a',
      libraryName: 'l',
      rawAssetName: 'r',
      rawSha256: null,
      rawSize: null,
    );
    const promoted = NativeReleaseArtifact(
      archiveName: 'a',
      libraryName: 'l',
      rawAssetName: 'r',
      rawSha256:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      rawSize: 1,
    );
    expect(
      selectNativeAssetSource(
        source: null,
        customLibrary: null,
        target: 'fixture',
        artifacts: const {'fixture': inactive},
      ),
      'disabled',
    );
    expect(
      selectNativeAssetSource(
        source: null,
        customLibrary: null,
        target: 'fixture',
        artifacts: const {'fixture': promoted},
      ),
      'pinned_release',
    );
  });

  test('explicit disabled wins over a custom library path', () async {
    await testCodeBuildHook(
      mainMethod: hook.main,
      userDefines: PackageUserDefines(
        workspacePubspec: PackageUserDefinesSource(
          defines: {'source': 'disabled', 'custom_library': 'not-used'},
          basePath: Directory.current.uri,
        ),
      ),
      check: (_, output) => expect(output.assets.code, isEmpty),
    );
  });
}
