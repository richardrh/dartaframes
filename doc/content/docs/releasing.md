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
7. Only after assets are public, run clean consumer smoke tests on every
   supported target so the promoted hook performs its normal unauthenticated
   download and cache verification. Publish `dartaframes` to pub.dev
   only after those post-public smokes pass.

Neither workflow publishes the GitHub draft or pub package. Draft assets are
not a valid simulation of the public consumer download path.
