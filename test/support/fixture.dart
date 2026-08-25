import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asset_guard/asset_guard.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// A throwaway Flutter project on disk.
///
/// Fixtures are generated rather than committed so the byte content of test
/// images is visible in the test that depends on it, and so dimensions can be
/// tweaked per-case to exercise scaled-variant detection.
class FixtureProject {
  FixtureProject._(this.root);

  /// Canonical (symlink-resolved) project root. macOS hands out `/var/...`
  /// temp paths that resolve to `/private/var/...`; without resolving, every
  /// relative path in the audit would be computed against a different prefix.
  final String root;

  static FixtureProject create() {
    final directory = Directory.systemTemp.createTempSync('asset_guard_');
    return FixtureProject._(directory.resolveSymbolicLinksSync());
  }

  String absolute(String relative) =>
      p.join(root, p.joinAll(relative.split('/')));

  void file(String relative, String content) {
    final target = File(absolute(relative));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(content);
  }

  void bytes(String relative, List<int> data) {
    final target = File(absolute(relative));
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(data);
  }

  void directory(String relative) {
    Directory(absolute(relative)).createSync(recursive: true);
  }

  void removeDirectory(String relative) {
    final target = Directory(absolute(relative));
    if (target.existsSync()) target.deleteSync(recursive: true);
  }

  /// Writes a deterministic PNG.
  ///
  /// [pattern] drives the difference hash: `gradient` brightens left-to-right
  /// (every dHash comparison false), `reverse` darkens left-to-right (every
  /// comparison true). The two are therefore 64 bits apart — reliably beyond
  /// any sane similarity threshold.
  void png(
    String relative, {
    int width = 64,
    int height = 64,
    String pattern = 'gradient',
    bool alpha = true,
    int tweakPixel = 0,
  }) {
    bytes(
        relative,
        pngBytes(
            width: width,
            height: height,
            pattern: pattern,
            alpha: alpha,
            tweakPixel: tweakPixel));
  }

  void dispose() {
    final directory = Directory(root);
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  }
}

/// Encodes a deterministic PNG. Shared by fixtures and by hashing unit tests.
List<int> pngBytes({
  int width = 64,
  int height = 64,
  String pattern = 'gradient',
  bool alpha = true,
  int tweakPixel = 0,
}) {
  final image = img.Image(
    width: width,
    height: height,
    numChannels: alpha ? 4 : 3,
  );

  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final int value;
      switch (pattern) {
        case 'reverse':
          value = 255 - (x * 255 ~/ (width - 1));
        case 'flat':
          value = 128;
        case 'gradient':
        default:
          value = x * 255 ~/ (width - 1);
      }
      if (alpha) {
        image.setPixelRgba(x, y, value, value, value, 255);
      } else {
        image.setPixelRgb(x, y, value, value, value);
      }
    }
  }

  // A single altered pixel changes the bytes (so SHA-256 differs) without
  // moving the 8x8 difference hash — exactly the "re-exported asset" case.
  if (tweakPixel > 0) {
    final v = (tweakPixel % 255).clamp(1, 254);
    if (alpha) {
      image.setPixelRgba(0, 0, v, v, v, 255);
    } else {
      image.setPixelRgb(0, 0, v, v, v);
    }
  }

  return img.encodePng(image);
}

/// A minimal Flutter pubspec.
String flutterPubspec({
  required String name,
  List<String> assets = const <String>[],
  String fonts = '',
}) {
  final buffer = StringBuffer()
    ..writeln('name: $name')
    ..writeln('environment:')
    ..writeln('  sdk: ">=3.4.0 <4.0.0"')
    ..writeln('dependencies:')
    ..writeln('  flutter:')
    ..writeln('    sdk: flutter')
    ..writeln('flutter:');

  if (assets.isNotEmpty) {
    buffer.writeln('  assets:');
    for (final String asset in assets) {
      buffer.writeln('    - $asset');
    }
  }
  if (fonts.isNotEmpty) buffer.write(fonts);

  return buffer.toString();
}

/// Runs the full audit against a fixture.
Future<AuditResult> audit(
  FixtureProject project, {
  AssetGuardConfig Function(AssetGuardConfig)? configure,
  List<Check>? checks,
}) {
  var config = AssetGuardConfig(projectRoot: project.root, color: false);
  if (configure != null) config = configure(config);
  return AssetGuardRunner(checks: checks ?? kAllChecks).run(config);
}

/// Collects everything written to an [IOSink], so CLI output can be asserted
/// without spawning a subprocess.
class CapturedOutput {
  CapturedOutput() {
    _controller = StreamController<List<int>>();
    _collected = _controller.stream.fold<List<int>>(
        <int>[], (List<int> acc, List<int> chunk) => acc..addAll(chunk));
    sink = IOSink(_controller.sink);
  }

  late final StreamController<List<int>> _controller;
  late final Future<List<int>> _collected;
  late final IOSink sink;

  Future<String> text() async {
    await sink.close();
    return utf8.decode(await _collected);
  }
}

/// Builds a [ProjectContext] directly, bypassing the filesystem.
///
/// Needed for cases the host filesystem cannot represent — notably two paths
/// differing only by case, which a case-insensitive macOS volume silently
/// collapses into one file.
ProjectContext syntheticContext({
  required List<AssetFile> assets,
  AssetGuardConfig? config,
  List<PackageContext> packages = const <PackageContext>[],
  List<FontFamilyDeclaration> fonts = const <FontFamilyDeclaration>[],
  Set<String> fontFamilyMentions = const <String>{},
}) {
  final resolved = config ?? AssetGuardConfig(projectRoot: '/synthetic');
  return ProjectContext(
    config: resolved,
    packages: packages.isNotEmpty
        ? packages
        : <PackageContext>[
            PackageContext(
              name: 'my_app',
              rootDirectory: resolved.projectRoot,
              pubspecPath: 'pubspec.yaml',
              declarations: const <AssetDeclaration>[],
              fonts: fonts,
              isFlutterPackage: true,
            ),
          ],
    assets: assets,
    references: const <AssetReference>[],
    dynamicReferences: const <DynamicReference>[],
    unresolvableReferences: const <UnresolvableReference>[],
    fontFamilyMentions: fontFamilyMentions,
    usage: <String, UsageStatus>{
      for (final AssetFile asset in assets) asset.path: UsageStatus.used,
    },
    occurrencesByAsset: const <String, List<Occurrence>>{},
    missingDeclarations: const <AssetDeclaration>[],
    emptyDirectories: const <AssetDeclaration>[],
    declarations: const <AssetDeclaration>[],
    unmatchedReferences: const <AssetReference>[],
    content: ContentCache(maxHashSizeBytes: resolved.maxHashSizeBytes),
  );
}

/// A bare [AssetFile] for synthetic contexts.
AssetFile syntheticAsset(String path, {int sizeBytes = 100}) => AssetFile(
      absolutePath: '/synthetic/$path',
      path: path,
      packageName: 'my_app',
      packagePath: path,
      sizeBytes: sizeBytes,
    );

/// All findings with [code], in report order.
List<Finding> findingsWithCode(AuditResult result, String code) =>
    result.findings
        .where((Finding f) => f.code == code)
        .toList(growable: false);

/// The paths reported under [code].
List<String?> pathsWithCode(AuditResult result, String code) =>
    findingsWithCode(result, code)
        .map((Finding f) => f.path)
        .toList(growable: false);
