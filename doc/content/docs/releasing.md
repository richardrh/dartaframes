---
title: Release process
weight: 11
---

> **Maintainer documentation:** only release maintainers should perform these
> steps.

Native assets and Dart publication stay separate so the package cannot select
an unreviewed binary.

## Required order

1. Confirm the stable version and changelog. Resolve every blocker in
   [native binaries](/docs/native-distribution/).
2. From the candidate commit, dispatch `Native release assets` with
   `upload_to_draft=false`. This builds and tests all five targets and creates
   only retained workflow artifacts; it does not create a tag or release.
   Record the successful workflow run ID. The candidate must already contain a
   reviewed `native/THIRD_PARTY_LICENSES.txt` inventory.
3. Review the run provenance, binaries, manifests, checksums, export evidence,
   and `native-assets.json`. Download the generated
   `native_release_metadata.dart`, regenerate/compare it from the reviewed
   index, and commit it as `lib/src/native_release_metadata.dart`.
4. Run the non-native Dart suite and release validation on that promoted
   commit. Create the final `v<version>` tag on this exact commit and push the
   tag. Never let a release command create the tag.
5. Dispatch `Native release assets` from the exact tag ref with
   `upload_to_draft=true`, `release_tag=v<version>`, and the reviewed
   `source_run_id`. The workflow verifies the peeled tag, checkout, and
   dispatch SHA agree, requires that only promoted metadata differs from the
   source run, downloads that run's retained binaries, and requires regenerated
   metadata to match the promoted Dart file byte-for-byte. It then creates
   (with `--verify-tag`) or updates a draft without overwriting assets. It does
   not rebuild reviewed binaries.
6. Run `Prepare GitHub release` to validate Dart format/analyze, the publish
   archive, and downloaded draft assets and pins. Review and publish the GitHub
   draft manually.
7. Only after assets are public, dispatch `Native consumer smoke` with the exact
   version and tag. Its five native runners invoke `Polars.native()` without a
   library path, forcing the promoted hook through its normal unauthenticated
   download, checksum verification, cache, bundle, FFI, CSV, and Arrow C paths.
   Publish `dartaframes_polars` to pub.dev only after every matrix job passes.
   The `Publish to pub.dev` workflow must be dispatched from the exact
   `v<version>` tag, not merely check out that tag from a `master` dispatch.
   Configure [pub.dev automated publishing](https://dart.dev/tools/pub/automated-publishing)
   for repository `richardrh/dartaframes`, tag pattern `v{{version}}`, and the
   `pub.dev` environment before using OIDC. Alternatively, publish manually
   from the exact tagged checkout with `dart pub publish`.

GitHub Pages deploys the documentation automatically from `master`. The first
deployment also requires enabling Pages in repository settings with GitHub
Actions as the source.

Neither the native workflows nor the documentation workflow publishes the
GitHub draft or package automatically. Draft assets are not a valid simulation
of the public consumer download path.

## Preparing a new version

Update `pubspec.yaml`, `native/polars_ffi/Cargo.toml`, the lockfile, and changelog
before the build-only run. Never carry the previous release's hashes forward:

```sh
python3 tool/native_distribution.py init-dart \
  --version 0.1.1 --output lib/src/native_release_metadata.dart
dart format lib/src/native_release_metadata.dart
cargo metadata --offline --format-version 1 > /dev/null
python3 .github/scripts/validate_release.py 0.1.1
```

`init-dart` generates all five asset names with null pins. The promoted release
gate deliberately rejects this state. No Git tag should be created yet.

## Releasing 0.1.1

After merging the bindings-only release preparation PR:

### Build the candidate

```sh
gh workflow run native-release.yml --ref master \
  -f version=0.1.1 -F upload_to_draft=false
gh run list --workflow native-release.yml
```

Leave `release_tag` and `source_run_id` empty. Wait for all five builds and
release-set verification to succeed, then record that run's ID as `RUN_ID`.
Do not reuse a 0.1.0 run.

### Review and promote the metadata

```sh
gh run download "$RUN_ID" --name native-release-0.1.1 \
  --dir .dart_tool/release-0.1.1
git fetch origin master
git switch -c release/promote-0.1.1 origin/master
python3 tool/native_distribution.py generate-dart \
  --index .dart_tool/release-0.1.1/native-assets.json \
  --output lib/src/native_release_metadata.dart
dart format lib/src/native_release_metadata.dart
cmp lib/src/native_release_metadata.dart \
  .dart_tool/release-0.1.1/native_release_metadata.dart
python3 .github/scripts/validate_release.py 0.1.1 --require-promoted
git add lib/src/native_release_metadata.dart
git commit -m "Promote reviewed 0.1.1 native metadata"
git push -u origin release/promote-0.1.1
gh pr create --base master --fill
```

Review the binaries, legal inventory, provenance, and checksums before merging.
Only this generated metadata may differ between the build source and release
commit. If other source changes land, start a fresh build-only run.

### Tag and stage the draft

After the promotion PR is merged:

```sh
git switch master
git pull --ff-only origin master
python3 .github/scripts/validate_release.py 0.1.1 --require-promoted
git tag -a v0.1.1 -m "Release v0.1.1"
git push origin v0.1.1
gh workflow run native-release.yml --ref v0.1.1 \
  -f version=0.1.1 -F upload_to_draft=true \
  -f release_tag=v0.1.1 -f source_run_id="$RUN_ID"
```

Do not move or replace `v0.1.0`. Wait for the draft upload to succeed, then:

```sh
gh workflow run release.yml --ref v0.1.1 \
  -f version=0.1.1 -f release_tag=v0.1.1
```

After that verifier succeeds, manually publish the draft. Then run:

```sh
gh workflow run native-consumer-smoke.yml --ref v0.1.1 \
  -f version=0.1.1 -f release_tag=v0.1.1
```

Only after all five consumer jobs pass, dispatch `publish.yml` from `v0.1.1`
with `tag=v0.1.1`, or publish with your pub.dev account from that exact tag.
