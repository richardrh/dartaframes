# Security policy

## Reporting a vulnerability

Do not report suspected vulnerabilities in a public issue, discussion, or pull
request. Use the canonical repository's private
[GitHub Security Advisory form](https://github.com/richardrh/dartframes/security/advisories/new).
Include affected versions or commits, platform and architecture, reproduction
steps, impact, and any proposed mitigation. Avoid including unrelated secrets
or personal data.

Maintainers will coordinate investigation and disclosure in the private
advisory. If the form is unavailable, use GitHub to contact the repository
owner without vulnerability details and request a private reporting channel.

## Supported versions

The project is pre-release and does not yet promise a supported release line.
Security fixes are developed against the current repository state and will be
identified in release notes when releases begin.

Native binaries must come from the canonical GitHub Releases page and match
checksums pinned in package source. Automatic native download is currently
inactive; see [native distribution](doc/native-distribution.md).
