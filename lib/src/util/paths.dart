import 'package:path/path.dart' as p;

/// Converts a native path (possibly using `\` on Windows) to POSIX form.
///
/// Every path stored in a model, compared against a glob, or printed in a
/// report is POSIX-style, so results are byte-identical across platforms.
String toPosix(String nativePath) => p.split(nativePath).join('/');

/// Project-relative POSIX path for [absolutePath].
String relativePosix(String absolutePath, {required String from}) =>
    toPosix(p.relative(absolutePath, from: from));

/// Canonicalises an asset path as written in source or a pubspec, so that
/// `./assets/logo.png`, `assets//logo.png` and `assets\logo.png` all compare
/// equal.
String normalizeAssetPath(String raw) {
  var value = raw.replaceAll('\\', '/').trim();
  if (value.startsWith('./')) value = value.substring(2);
  while (value.contains('//')) {
    value = value.replaceAll('//', '/');
  }
  return value;
}

/// Splits a `packages/<name>/<rest>` reference into its parts.
///
/// Flutter resolves this form against another package's asset bundle, so it
/// must be matched against that package rather than the referencing one.
({String package, String path})? parsePackageReference(String normalizedPath) {
  if (!normalizedPath.startsWith('packages/')) return null;
  final rest = normalizedPath.substring('packages/'.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  return (package: rest.substring(0, slash), path: rest.substring(slash + 1));
}

/// Matches a Flutter resolution-variant directory such as `2.0x` or `3.0x`.
final RegExp _variantDirectory = RegExp(r'^(\d+(?:\.\d+)?)x$');

/// If [directoryName] is a resolution-variant folder, returns its scale.
double? variantScaleOf(String directoryName) {
  final match = _variantDirectory.firstMatch(directoryName);
  if (match == null) return null;
  return double.tryParse(match[1]!);
}

/// Renders a byte count for humans: `1.4 MB`, `812 B`.
String humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text =
      value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
