import 'package:path/path.dart' as p;

import 'finding.dart';

/// Whether a `flutter: assets:` entry named a single file or a directory.
///
/// A directory entry (trailing `/`) includes every file directly inside it,
/// non-recursively — matching Flutter's own behaviour.
enum AssetDeclarationKind { file, directory }

/// One entry under `flutter: assets:` in some package's pubspec.
class AssetDeclaration {
  const AssetDeclaration({
    required this.rawEntry,
    required this.packageName,
    required this.path,
    required this.kind,
    required this.origin,
    this.flavors = const <String>[],
  });

  /// The entry exactly as written in the pubspec, e.g. `assets/icons/`.
  final String rawEntry;

  /// Name of the package whose pubspec declared this.
  final String packageName;

  /// Project-relative POSIX path. Directory entries keep their trailing `/`.
  final String path;

  final AssetDeclarationKind kind;

  /// Location of the entry in the pubspec, for error reporting.
  final Occurrence origin;

  /// Flutter 3.16+ flavor-conditional assets. Empty means unconditional.
  final List<String> flavors;

  bool get isDirectory => kind == AssetDeclarationKind.directory;

  /// The directory path without a trailing slash, for prefix comparisons.
  String get directoryPath => isDirectory && path.endsWith('/')
      ? path.substring(0, path.length - 1)
      : path;
}

/// A `flutter: fonts:` family and the font files it binds.
class FontFamilyDeclaration {
  const FontFamilyDeclaration({
    required this.family,
    required this.assetPaths,
    required this.packageName,
    required this.origin,
  });

  final String family;

  /// Project-relative POSIX paths of every `asset:` under this family.
  final List<String> assetPaths;
  final String packageName;
  final Occurrence origin;
}

/// A file on disk that is (or could be) a Flutter asset.
class AssetFile {
  const AssetFile({
    required this.absolutePath,
    required this.path,
    required this.packageName,
    required this.packagePath,
    required this.sizeBytes,
    this.variantOfPath,
    this.variantScale,
    this.declaration,
  });

  final String absolutePath;

  /// Project-relative POSIX path — the identity used everywhere in reports.
  final String path;

  final String packageName;

  /// Path relative to the owning package root, which is what a pubspec entry
  /// and a `rootBundle` lookup both use.
  final String packagePath;

  final int sizeBytes;

  /// If this file lives in a `2.0x/`-style folder, the project-relative path of
  /// the asset it is a variant of. Variants are never independently unused.
  final String? variantOfPath;

  /// The scale parsed from the variant folder name, e.g. 2.0 for `2.0x/`.
  final double? variantScale;

  /// The pubspec entry that covers this file, if any.
  final AssetDeclaration? declaration;

  bool get isVariant => variantOfPath != null;
  bool get isDeclared => declaration != null;

  /// Lowercase extension including the dot, e.g. `.png`.
  String get extension => p.posix.extension(path).toLowerCase();

  String get basename => p.posix.basename(path);

  AssetFile copyWith({
    String? variantOfPath,
    double? variantScale,
    AssetDeclaration? declaration,
  }) {
    return AssetFile(
      absolutePath: absolutePath,
      path: path,
      packageName: packageName,
      packagePath: packagePath,
      sizeBytes: sizeBytes,
      variantOfPath: variantOfPath ?? this.variantOfPath,
      variantScale: variantScale ?? this.variantScale,
      declaration: declaration ?? this.declaration,
    );
  }

  @override
  String toString() => 'AssetFile($path)';
}

/// One package in the target project. A single-package app produces exactly
/// one of these; a melos monorepo produces one per package with a pubspec.
class PackageContext {
  const PackageContext({
    required this.name,
    required this.rootDirectory,
    required this.pubspecPath,
    required this.declarations,
    required this.fonts,
    required this.isFlutterPackage,
  });

  final String name;

  /// Absolute path to the package root.
  final String rootDirectory;

  /// Project-relative POSIX path of the pubspec.
  final String pubspecPath;

  final List<AssetDeclaration> declarations;
  final List<FontFamilyDeclaration> fonts;

  /// False for pure-Dart packages in the workspace — they can still reference
  /// assets, but they never declare them.
  final bool isFlutterPackage;
}
