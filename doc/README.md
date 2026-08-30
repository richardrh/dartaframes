# Documentation site

This [Hugo](https://gohugo.io/) site uses the
[Hextra](https://imfing.github.io/hextra/) theme. Guides live in `content/`;
`dart doc` generates the API reference. The combined, uncommitted output goes
to `public/`.

## Prerequisites

- Dart 3.13 or later
- Hugo Extended 0.158.0 or later
- Go 1.26 or later

On macOS with Homebrew:

```sh
brew install hugo go
```

## Preview locally

From the repository root:

```sh
make -C doc serve
```

Open <http://localhost:1313/dartaframes/>. The first run resolves locked Dart
dependencies and downloads the pinned Hextra module.

## Build

```sh
make -C doc build
```

Output goes to `doc/public/`, including dartdoc at `doc/public/api/`. Clean it
with:

```sh
make -C doc clean
```

After intentionally changing the Hextra version, refresh its pinned metadata:

```sh
hugo mod tidy --source doc
```

Commit both `doc/go.mod` and `doc/go.sum` after a theme update.
