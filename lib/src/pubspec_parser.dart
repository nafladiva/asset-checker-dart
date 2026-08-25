import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'models/asset.dart';
import 'models/finding.dart';
import 'util/paths.dart';

/// Reads pubspecs across the workspace and extracts asset and font
/// declarations.
///
/// Discovery is recursive so a melos-style monorepo works without
/// configuration: every `pubspec.yaml` that isn't inside a build or tool
/// directory becomes a package.
class PubspecParser {
  const PubspecParser();

  /// Finds every package in the workspace, root first, then in stable path
  /// order so reports don't reshuffle between runs.
  List<PackageContext> discoverPackages(String projectRoot) {
    final pubspecs = <String>[];
    _collectPubspecs(Directory(projectRoot), projectRoot, pubspecs, depth: 0);
    pubspecs.sort((String a, String b) {
      final aIsRoot = p.equals(p.dirname(a), projectRoot);
      final bIsRoot = p.equals(p.dirname(b), projectRoot);
      if (aIsRoot != bIsRoot) return aIsRoot ? -1 : 1;
      return a.compareTo(b);
    });

    final packages = <PackageContext>[];
    for (final String pubspec in pubspecs) {
      final parsed = parsePackage(pubspec, projectRoot);
      if (parsed != null) packages.add(parsed);
    }
    return packages;
  }

  void _collectPubspecs(
    Directory dir,
    String projectRoot,
    List<String> out, {
    required int depth,
  }) {
    // Deep nesting past this point is almost certainly vendored code rather
    // than a workspace package.
    if (depth > 6) return;

    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }

    for (final FileSystemEntity entity in entries) {
      final name = p.basename(entity.path);
      if (entity is File) {
        if (name == 'pubspec.yaml') out.add(entity.path);
      } else if (entity is Directory) {
        if (name.startsWith('.') || kAlwaysSkippedDirectories.contains(name)) {
          continue;
        }
        _collectPubspecs(entity, projectRoot, out, depth: depth + 1);
      }
    }
  }

  /// Returns `null` when the file isn't a usable pubspec (unparseable, or no
  /// `name:`), rather than throwing — one broken package shouldn't sink a
  /// monorepo-wide audit.
  PackageContext? parsePackage(String pubspecAbsolutePath, String projectRoot) {
    final file = File(pubspecAbsolutePath);
    final Object? doc;
    try {
      doc = loadYaml(file.readAsStringSync());
    } on Object {
      return null;
    }
    if (doc is! YamlMap) return null;

    final name = doc['name']?.toString();
    if (name == null || name.isEmpty) return null;

    final packageRoot = p.dirname(pubspecAbsolutePath);
    final pubspecRelative =
        relativePosix(pubspecAbsolutePath, from: projectRoot);

    final flutterSection = doc['flutter'];
    final dependencies = doc['dependencies'];
    final isFlutterPackage = flutterSection is YamlMap ||
        (dependencies is YamlMap && dependencies.containsKey('flutter'));

    final declarations = <AssetDeclaration>[];
    final fonts = <FontFamilyDeclaration>[];

    if (flutterSection is YamlMap) {
      _parseAssets(
        flutterSection['assets'],
        packageName: name,
        packageRoot: packageRoot,
        projectRoot: projectRoot,
        pubspecRelative: pubspecRelative,
        out: declarations,
      );
      _parseFonts(
        flutterSection['fonts'],
        packageName: name,
        packageRoot: packageRoot,
        projectRoot: projectRoot,
        pubspecRelative: pubspecRelative,
        out: fonts,
      );
    }

    return PackageContext(
      name: name,
      rootDirectory: packageRoot,
      pubspecPath: pubspecRelative,
      declarations: declarations,
      fonts: fonts,
      isFlutterPackage: isFlutterPackage,
    );
  }

  void _parseAssets(
    Object? node, {
    required String packageName,
    required String packageRoot,
    required String projectRoot,
    required String pubspecRelative,
    required List<AssetDeclaration> out,
  }) {
    if (node is! YamlList) return;

    for (final Object? entry in node.nodes.cast<Object?>()) {
      String? raw;
      var flavors = const <String>[];
      YamlNode? spanNode;

      if (entry is YamlScalar) {
        raw = entry.value?.toString();
        spanNode = entry;
      } else if (entry is YamlMap) {
        // Flutter 3.16+ allows `- path: assets/x/` with `flavors:`.
        raw = entry['path']?.toString();
        final Object? rawFlavors = entry['flavors'];
        if (rawFlavors is YamlList) {
          flavors = rawFlavors
              .map((Object? f) => f.toString())
              .toList(growable: false);
        }
        spanNode = entry;
      }

      if (raw == null || raw.trim().isEmpty) continue;

      final normalized = normalizeAssetPath(raw);
      final absolute = p.normalize(p.join(packageRoot, normalized));
      final endsWithSlash = normalized.endsWith('/');
      // Be lenient: treat an existing directory as a directory entry even when
      // the author forgot the trailing slash Flutter requires.
      final isDirectory = endsWithSlash || Directory(absolute).existsSync();

      var projectPath = relativePosix(absolute, from: projectRoot);
      if (isDirectory && !projectPath.endsWith('/')) {
        projectPath = '$projectPath/';
      }

      out.add(AssetDeclaration(
        rawEntry: raw,
        packageName: packageName,
        path: projectPath,
        kind: isDirectory
            ? AssetDeclarationKind.directory
            : AssetDeclarationKind.file,
        origin: Occurrence(
          file: pubspecRelative,
          line: spanNode == null ? null : spanNode.span.start.line + 1,
          snippet: raw,
        ),
        flavors: flavors,
      ));
    }
  }

  void _parseFonts(
    Object? node, {
    required String packageName,
    required String packageRoot,
    required String projectRoot,
    required String pubspecRelative,
    required List<FontFamilyDeclaration> out,
  }) {
    if (node is! YamlList) return;

    for (final Object? family in node.nodes.cast<Object?>()) {
      if (family is! YamlMap) continue;
      final familyName = family['family']?.toString();
      if (familyName == null || familyName.isEmpty) continue;

      final paths = <String>[];
      final Object? fontList = family['fonts'];
      if (fontList is YamlList) {
        for (final Object? font in fontList) {
          if (font is! YamlMap) continue;
          final asset = font['asset']?.toString();
          if (asset == null || asset.trim().isEmpty) continue;
          final absolute =
              p.normalize(p.join(packageRoot, normalizeAssetPath(asset)));
          paths.add(relativePosix(absolute, from: projectRoot));
        }
      }

      out.add(FontFamilyDeclaration(
        family: familyName,
        assetPaths: paths,
        packageName: packageName,
        origin: Occurrence(
          file: pubspecRelative,
          line: family.span.start.line + 1,
          snippet: 'family: $familyName',
        ),
      ));
    }
  }
}
