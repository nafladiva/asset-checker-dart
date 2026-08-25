# asset_guard

Audits a Flutter project's assets for files nothing references, files the
pubspec promises but disk doesn't have, byte-identical copies, and
near-duplicate images. Pure Dart — no Flutter dependency — so it runs from a
`dev_dependency` locally and in CI.

It is built around one asymmetry: **reporting a used asset as unused is much
worse than missing an unused one.** A missed cleanup costs a few kilobytes; a
wrong deletion is a runtime crash on a screen nobody tested. Every ambiguous
case therefore resolves toward "used".

---

## Install

```yaml
dev_dependencies:
  asset_guard: ^0.1.0
```

Not on pub.dev yet — until then, depend on it by git or path:

```yaml
dev_dependencies:
  asset_guard:
    git:
      url: https://github.com/nafladiva/asset_guard.git
```

Then:

```bash
dart run asset_guard
```

Requires Dart 3.4 or newer. Works on macOS, Linux and Windows; every path in
the output is POSIX-style and project-relative, so reports are identical
across platforms.

---

## Quick start

```bash
# audit the current directory
dart run asset_guard

# only the checks you care about
dart run asset_guard --check unused --check dupes

# machine-readable, for CI annotations
dart run asset_guard --format json -o asset-report.json

# see what cleanup would reclaim (nothing is deleted)
dart run asset_guard --delete-unused
```

Sample output:

```
Flutter Asset Guard
demo  ·  1 package  ·  10 assets

Declared but missing from disk (2)
  error    assets/fonts/orbitron.ttf
           demo_app declares `assets/fonts/orbitron.ttf` but nothing exists at that path.
           at pubspec.yaml:14

Unused assets (4 · 972 B reclaimable)
  warning  assets/images/retired.png
           Nothing references assets/images/retired.png (257 B).

Dynamic references (1)
  info     assets/flags
           Dynamic asset path `Image.asset('assets/flags/$code.png')` pins to
           assets/flags/; all 2 file(s) under it are treated as possibly used.
           at lib/main.dart:8:29

Summary
  4 unused (972 B reclaimable), 2 duplicate groups, 2 similar groups
  2 errors, 11 warnings, 13 info, 2 possibly used (never deleted)
```

---

## What it checks

| Code | Severity | Check | Meaning |
| --- | --- | --- | --- |
| `MISSING_DECLARED_ASSET` | error | `missing` | pubspec declares it, disk doesn't have it |
| `UNDECLARED_REFERENCE` | error | `missing` | code loads a path no pubspec entry covers — crashes at runtime |
| `CASE_COLLISION` | error | `hygiene` | two paths differ only by case; builds on macOS, fails on Linux CI |
| `UNUSED_ASSET` | warning | `unused` | nothing references it |
| `UNDECLARED_ON_DISK` | warning | `missing` | sits in an asset folder but won't ship |
| `UNRESOLVABLE_DYNAMIC_REFERENCE` | warning | `unused` | a bundle load whose path can't be traced — needs a human |
| `DUPLICATE_ASSETS` | warning | `dupes` | byte-identical files (SHA-256) |
| `EMPTY_FILE` | warning | `dupes` | zero bytes |
| `SIMILAR_ASSETS` | warning | `similar` | visually near-identical images |
| `SCALED_VARIANT` | warning | `similar` | same image at different pixel sizes — probably wants a `2.0x/` folder |
| `SIMILAR_SVG` | warning | `similar` | SVGs identical after normalization, or near-identical geometry |
| `LARGE_ASSET` | warning | `hygiene` | over `max_file_size_kb` |
| `PROBLEMATIC_FILENAME` | warning | `hygiene` | spaces, uppercase or non-ASCII |
| `UNUSED_FONT_FAMILY` | warning | `hygiene` | declared family name appears in no string |
| `EMPTY_ASSET_DIRECTORY` | warning | `hygiene` | declared directory holds no files |
| `POSSIBLY_USED_ASSET` | info | `unused` | only a dynamic path could reach it — never deleted |
| `DYNAMIC_REFERENCE` | info | `unused` | an interpolation pinned to a directory |
| `PNG_WITHOUT_ALPHA` | info | `hygiene` | PNG with no alpha, or an alpha channel that's fully opaque |

---

## How references are found

Detection walks the Dart AST with `package:analyzer` rather than grepping, and
resolves:

- **String literals and adjacent strings** — `Image.asset('assets/logo.png')`.
- **Constants**, across files — `AppAssets.logo`, `_base + 'logo.png'`. A
  constant only marks its target used when the *symbol* is referenced
  somewhere, so an `AppAssets` entry nobody uses is still reported.
- **flutter_gen accessors** — `Assets.images.logo`,
  `Assets.icons.arrowBack.svg()`. If `assets.gen.dart` is committed it is
  parsed and each generated getter mapped to its real path; if it isn't, the
  accessor names are derived from disk using flutter_gen's naming rules.
  Generated files are parsed **only** for that map — their own string literals
  are ignored, or every generated asset would look used.
- **Platform folders** — `android/`, `ios/`, `web/`, `macos/`, `windows/`,
  `linux/` are scanned for asset paths so launch images, splash screens and
  `index.html` references count.
- **Monorepos** — every `pubspec.yaml` in the tree becomes a package.
  `packages/design/assets/star.png` resolves against the package that owns it.

### Dynamic paths

This is where naive tools delete things they shouldn't.

```dart
Widget flag(String code) => Image.asset('assets/flags/$code.png');
```

The literal segment pins this to `assets/flags/`, so **every file under that
prefix** becomes `possiblyUsed` — never reported unused, never deleted. The
interpolation itself is reported separately as a `DYNAMIC_REFERENCE` with its
source location, so a human can confirm the directory is right.

For a bundle load taking a parameter:

```dart
Future<String> load(String path) => rootBundle.loadString(path);
```

call sites are searched first — `load('assets/data/config.json')` elsewhere in
the project resolves it. Only if no call site yields a traceable value is it
reported as `UNRESOLVABLE_DYNAMIC_REFERENCE`, which also blocks
`--delete-unused` from running unattended.

### Known limits

Parsing is syntactic, not type-resolved. That keeps the audit fast and means it
works before `pub get`, but paths built through runtime logic (map lookups,
values from network or shared preferences) can't be traced. Those surface as
unresolvable references rather than being silently ignored. Review them; if one
is legitimately unanalysable, add its directory to `ignore`.

---

## Resolution variants

`2.0x/`, `3.0x/` and `4.0x/` files belong to the asset above them. If the
parent is used, its variants are used, and a variant is **never** reported
unused on its own — it shows up as a related path under its parent. Variants
are also excluded from similarity comparison, since looking identical to their
parent is the entire point.

---

## Configuration

`asset_guard.yaml` at the project root. CLI flags win over it.

```yaml
ignore:
  - assets/legacy/**
  - assets/**/*.json
similarity_threshold: 5      # max Hamming distance, 0-64
max_file_size_kb: 500
max_hash_size_mb: 10         # skip perceptual hashing above this
fail_on: error               # none | warning | error
treat_dynamic_as_used: true  # dynamic paths mark assets possibly-used
treat_unresolvable_as_wildcard: false
```

`treat_unresolvable_as_wildcard` makes a single untraceable bundle load mark
*every* asset possibly-used. It is off by default because it silences the
unused check entirely; such loads block deletion either way.

### CLI

```
-p, --path <dir>                 project root (default: cwd)
    --check <name>               all|unused|dupes|similar|missing|hygiene, repeatable
-f, --format <fmt>               pretty|json|markdown (default pretty)
-o, --output <file>              write the report to a file
    --similarity-threshold <int> default 5
    --max-file-size-kb <int>     default 500
    --max-hash-size-mb <int>     default 10
    --fail-on <level>            none|warning|error (default error)
    --ignore <glob>              repeatable
    --delete-unused              remove unreferenced files
    --[no-]dry-run               default on; --no-dry-run actually deletes
-y, --yes                        skip the confirmation prompt
    --[no-]color                 default on when attached to a terminal
-v, --verbose                    log progress to stderr
```

Exit codes: `0` clean, `1` findings at or above `--fail-on`, `2` bad usage.

---

## CI

The default `--fail-on error` blocks only on the three things that break a
build: a declared asset missing from disk, code loading an undeclared path, and
a case collision. Unused assets are warnings, so adopting the tool won't fail
your pipeline on day one.

Once the backlog is clean, tighten it:

```bash
dart run asset_guard --fail-on warning
```

### GitHub Actions

```yaml
name: assets

on:
  pull_request:
  push:
    branches: [main]

jobs:
  asset-guard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - run: flutter pub get

      # Fails the job on errors. Drop to --fail-on warning once clean.
      - name: Audit assets
        run: dart run asset_guard --fail-on error --no-color

      # Always publish the full report to the job summary, pass or fail.
      - name: Report
        if: always()
        run: dart run asset_guard --format markdown --fail-on none >> "$GITHUB_STEP_SUMMARY"

      - name: Upload JSON report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: asset-report
          path: asset-report.json
```

Run it on Linux. Case collisions are only *detectable* on a case-sensitive
filesystem — two files differing by case cannot both exist in a macOS or
Windows checkout in the first place, which is exactly why they reach CI
undetected.

### JSON schema

Stable contract, suitable for annotations:

```json
{
  "schemaVersion": 1,
  "root": "/path/to/project",
  "packages": ["my_app"],
  "summary": { "unused": 4, "reclaimableBytes": 972, "errors": 2, "...": 0 },
  "findings": [
    {
      "severity": "warning",
      "code": "UNUSED_ASSET",
      "message": "Nothing references assets/images/retired.png (257 B).",
      "path": "assets/images/retired.png",
      "occurrences": [{ "file": "lib/main.dart", "line": 8, "column": 29 }],
      "relatedPaths": [],
      "data": { "reclaimableBytes": 257 }
    }
  ]
}
```

`severity`, `code`, `message`, `path`, `occurrences[]` and `relatedPaths[]` are
guaranteed. Keys may be added; existing ones won't change meaning without a
`schemaVersion` bump. Everything under `data` is best-effort.

---

## Deleting unused assets

`--delete-unused` is dry-run by default and prints exactly what it would
remove. To actually delete, all of these must hold:

1. `--no-dry-run` is passed.
2. The project is inside a **git working tree** — without version control a
   mistake is unrecoverable, so it refuses outright.
3. The tree is **clean**. Uncommitted changes mean the deletion wouldn't be
   reviewable on its own.
4. You type `yes`, or pass `--yes`.

It will never touch anything marked `possiblyUsed`. When a directory is emptied
by the deletion, the directory and its `assets:` entry are removed too — a
pubspec pointing at a missing directory is itself a build error. The pubspec
edit is line-based and only fires when the line still looks like the entry that
was parsed, so comments and formatting survive.

```bash
dart run asset_guard --check unused --delete-unused --no-dry-run
```

---

## Extending

Each check implements one interface and receives a fully-built context:

```dart
class MyCheck implements Check {
  @override
  String get id => 'mine';

  @override
  String get name => 'My check';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async => <Finding>[
        for (final asset in ctx.assets)
          if (asset.extension == '.bmp')
            Finding(
              severity: Severity.warning,
              code: 'BMP_ASSET',
              message: '${asset.path} is a BMP.',
              path: asset.path,
            ),
      ];
}
```

Add it to `kAllChecks` and it appears in `--check`, all three reporters, and
the exit-code gate. The runner needs no changes.

---

## Development

```bash
dart pub get
dart analyze
dart test
```

Test fixtures are synthetic Flutter projects generated into temp directories at
runtime — no binary blobs in the repo, and image dimensions are set per-test so
scaled-variant detection is exercised deliberately rather than by accident.

## License

MIT
