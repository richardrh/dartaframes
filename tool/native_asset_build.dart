import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'package:dartaframes_polars/src/native_asset_manifest.dart';

import 'native_asset_download.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    final source = input.userDefines['source'];
    final customLibraryValue = input.userDefines['custom_library'];
    final target = nativeReleaseTarget(
      input.config.code.targetOS.name,
      input.config.code.targetArchitecture.name,
    );
    final selectedSource = selectNativeAssetSource(
      source: source,
      customLibrary: customLibraryValue,
      target: target,
      artifacts: nativeReleaseArtifacts,
    );
    switch (selectedSource) {
      case 'disabled':
        // Polars.open and Polars.process remain usable without a native asset.
        return;
      case 'custom_library':
        final libraryUri = input.userDefines.path('custom_library');
        if (libraryUri == null) {
          throw const FormatException(
            'source custom_library requires '
            'hooks.user_defines.dartaframes_polars.custom_library',
          );
        }
        final library = File.fromUri(libraryUri);
        output.dependencies.add(libraryUri);
        if (!library.existsSync()) {
          throw ArgumentError('custom_library does not exist: ${library.path}');
        }

        final expectedName = nativeReleaseArtifacts[target]?.libraryName;
        if (expectedName == null) {
          throw UnsupportedError(
            'dartaframes_polars has no native distribution target for '
            '${input.config.code.targetOS.name}/'
            '${input.config.code.targetArchitecture.name}',
          );
        }
        if (library.uri.pathSegments.last != expectedName) {
          throw ArgumentError(
            'custom_library for $target must be named $expectedName; got '
            '${library.uri.pathSegments.last}',
          );
        }

        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: nativeAssetName,
            linkMode: DynamicLoadingBundled(),
            file: libraryUri,
          ),
        );
      case 'pinned_release':
        final artifact = pinnedReleaseArtifact(target);
        final libraryUri = await acquirePinnedNativeLibrary(
          outputDirectoryShared: input.outputDirectoryShared,
          artifact: artifact,
        );
        output.assets.code.add(
          CodeAsset(
            package: input.packageName,
            name: nativeAssetName,
            linkMode: DynamicLoadingBundled(),
            file: libraryUri,
          ),
        );
      default:
        throw FormatException(
          'Unsupported dartaframes_polars native source "$selectedSource"; '
          'expected disabled, custom_library, or pinned_release',
        );
    }
  });
}

/// Pure source selection used by the hook and by metadata-state fixtures.
String selectNativeAssetSource({
  required Object? source,
  required Object? customLibrary,
  required String target,
  required Map<String, NativeReleaseArtifact> artifacts,
}) {
  if (source != null && source is! String) {
    throw const FormatException(
      'hooks.user_defines.dartaframes_polars.source must be a string',
    );
  }
  if (customLibrary != null && customLibrary is! String) {
    throw const FormatException(
      'hooks.user_defines.dartaframes_polars.custom_library must be a path',
    );
  }
  return source as String? ??
      (customLibrary != null
          ? 'custom_library'
          : artifacts[target]?.isPromoted == true
          ? 'pinned_release'
          : 'disabled');
}
