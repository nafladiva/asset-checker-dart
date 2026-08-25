import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'models/asset.dart';
import 'util/paths.dart';

/// Result of walking the workspace for asset files.
class AssetScanResult {
  const AssetScanResult({
    required this.assets,
    required this.declarations,
    required this.missingDeclarations,
    required this.emptyDirectories,
  });

  /// Every candidate asset on disk, ignored paths already removed.
  final List<AssetFile> assets;

  /// Pubspec `assets:` entries plus synthesized entries for each font file, so
  /// coverage and existence checks treat both uniformly.
  final List<AssetDeclaration> declarations;

  /// Declarations whose target is absent from disk.
  final List<AssetDeclaration> missingDeclarations;

  /// Directory declarations that exist but contain no files.
  final List<AssetDeclaration> emptyDirectories;
}

/// Walks the asset roots of every package and builds the [AssetFile] set.
///
/// Only directories that a pubspec points at (plus the conventional `assets/`
/// and `fonts/` folders) are walked, so source trees and platform folders are
/// never mistaken for asset storage.
class AssetScanner {
  const AssetScanner();

  AssetScanResult scan(String projectRoot, List<PackageContext> packages,
      AssetGuardConfig config) {
    final declarations = <AssetDeclaration>[];
    for (final PackageContext pkg in packages) {
      declarations.addAll(pkg.declarations);
      declarations.addAll(_syntheticFontDeclarations(pkg, projectRoot));
    }

    final assetsByPath = <String, AssetFile>{};
    for (final PackageContext pkg in packages) {
      for (final String root in _assetRoots(pkg, declarations, projectRoot)) {
        _walk(
          root,
          package: pkg,
          projectRoot: projectRoot,
          config: config,
          out: assetsByPath,
        );
      }
    }

    final withMetadata = _attachVariantsAndDeclarations(
      assetsByPath,
      declarations,
    );

    final missing = <AssetDeclaration>[];
    final empty = <AssetDeclaration>[];
    for (final AssetDeclaration decl in declarations) {
      final absolute = p.normalize(p.join(projectRoot, decl.directoryPath));
      if (decl.isDirectory) {
        final dir = Directory(absolute);
        if (!dir.existsSync()) {
          missing.add(decl);
        } else if (!_containsAnyFile(dir)) {
          empty.add(decl);
        }
      } else if (!File(absolute).existsSync()) {
        missing.add(decl);
      }
    }

    final assets = withMetadata.values.toList()
      ..sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));

    return AssetScanResult(
      assets: assets,
      declarations: declarations,
      missingDeclarations: missing,
      emptyDirectories: empty,
    );
  }

  Iterable<AssetDeclaration> _syntheticFontDeclarations(
    PackageContext pkg,
    String projectRoot,
  ) sync* {
    for (final FontFamilyDeclaration family in pkg.fonts) {
      for (final String path in family.assetPaths) {
        yield AssetDeclaration(
          rawEntry: path,
          packageName: pkg.name,
          path: path,
          kind: AssetDeclarationKind.file,
          origin: family.origin,
        );
      }
    }
  }

  /// Directories worth walking for [pkg].
  Set<String> _assetRoots(
    PackageContext pkg,
    List<AssetDeclaration> declarations,
    String projectRoot,
  ) {
    final roots = <String>{};

    for (final AssetDeclaration decl in declarations) {
      if (decl.packageName != pkg.name) continue;
      final absolute = p.normalize(p.join(projectRoot, decl.directoryPath));
      roots.add(decl.isDirectory ? absolute : p.dirname(absolute));
    }

    // Conventional locations, so undeclared files still get reported.
    for (final String conventional in const <String>['assets', 'fonts']) {
      final candidate = p.join(pkg.rootDirectory, conventional);
      if (Directory(candidate).existsSync()) roots.add(candidate);
    }

    // Drop roots nested inside another root — walking is recursive already.
    return roots
        .where((String root) => !roots
            .any((String other) => other != root && p.isWithin(other, root)))
        .toSet();
  }

  void _walk(
    String directory, {
    required PackageContext package,
    required String projectRoot,
    required AssetGuardConfig config,
    required Map<String, AssetFile> out,
  }) {
    final dir = Directory(directory);
    if (!dir.existsSync()) return;

    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      return;
    }

    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;

      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;

      final segments = p.split(p.relative(entity.path, from: directory));
      if (segments.any((String s) =>
          s.startsWith('.') || kAlwaysSkippedDirectories.contains(s))) {
        continue;
      }

      final projectPath = relativePosix(entity.path, from: projectRoot);
      if (config.isIgnored(projectPath)) continue;
      if (out.containsKey(projectPath)) continue;

      final int size;
      try {
        size = entity.lengthSync();
      } on FileSystemException {
        continue;
      }

      out[projectPath] = AssetFile(
        absolutePath: entity.path,
        path: projectPath,
        packageName: package.name,
        packagePath: relativePosix(entity.path, from: package.rootDirectory),
        sizeBytes: size,
      );
    }
  }

  /// Links `2.0x/` files to their parent asset and attaches the pubspec entry
  /// that covers each file.
  Map<String, AssetFile> _attachVariantsAndDeclarations(
    Map<String, AssetFile> assets,
    List<AssetDeclaration> declarations,
  ) {
    final fileDeclarations = <String, AssetDeclaration>{};
    final directoryDeclarations = <String, AssetDeclaration>{};
    for (final AssetDeclaration decl in declarations) {
      if (decl.isDirectory) {
        directoryDeclarations.putIfAbsent(decl.directoryPath, () => decl);
      } else {
        fileDeclarations.putIfAbsent(decl.path, () => decl);
      }
    }

    final result = <String, AssetFile>{};
    assets.forEach((String path, AssetFile asset) {
      final directory = p.posix.dirname(path);
      final scale = variantScaleOf(p.posix.basename(directory));

      String? parentPath;
      if (scale != null) {
        final candidate =
            p.posix.join(p.posix.dirname(directory), p.posix.basename(path));
        // Only treat it as a variant when the parent actually exists; an
        // orphaned `2.0x/` file is a real finding, not someone else's variant.
        if (assets.containsKey(candidate)) parentPath = candidate;
      }

      // Coverage is decided by the parent for variants: Flutter picks up
      // `2.0x/logo.png` because `logo.png` is declared.
      final coveragePath = parentPath ?? path;
      final coverageDirectory = p.posix.dirname(coveragePath);
      final declaration = fileDeclarations[coveragePath] ??
          directoryDeclarations[coverageDirectory];

      result[path] = asset.copyWith(
        variantOfPath: parentPath,
        variantScale: parentPath == null ? null : scale,
        declaration: declaration,
      );
    });
    return result;
  }

  bool _containsAnyFile(Directory dir) {
    try {
      return dir.listSync(recursive: true, followLinks: false).any(
          (FileSystemEntity e) =>
              e is File && !p.basename(e.path).startsWith('.'));
    } on FileSystemException {
      return false;
    }
  }
}
