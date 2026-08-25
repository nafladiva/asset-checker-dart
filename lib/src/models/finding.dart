/// Severity of a [Finding]. Ordered least-to-most severe so that
/// `Severity.warning.index >= Severity.info.index` can drive `--fail-on`.
enum Severity {
  info,
  warning,
  error;

  /// Parses a `--fail-on` / config value. Returns `null` for unknown input.
  static Severity? tryParse(String value) {
    switch (value.trim().toLowerCase()) {
      case 'info':
        return Severity.info;
      case 'warning':
      case 'warn':
        return Severity.warning;
      case 'error':
      case 'err':
        return Severity.error;
    }
    return null;
  }

  String get label => name;
}

/// Stable machine-readable codes. These are part of the JSON contract:
/// CI annotations key off them, so treat renames as breaking changes.
abstract final class FindingCode {
  // unused
  static const unusedAsset = 'UNUSED_ASSET';
  static const possiblyUsedAsset = 'POSSIBLY_USED_ASSET';
  static const dynamicReference = 'DYNAMIC_REFERENCE';
  static const unresolvableDynamicReference = 'UNRESOLVABLE_DYNAMIC_REFERENCE';

  // missing / undeclared
  static const missingDeclaredAsset = 'MISSING_DECLARED_ASSET';
  static const undeclaredReference = 'UNDECLARED_REFERENCE';
  static const undeclaredOnDisk = 'UNDECLARED_ON_DISK';

  // duplicates
  static const duplicateAssets = 'DUPLICATE_ASSETS';
  static const emptyFile = 'EMPTY_FILE';

  // similarity
  static const similarAssets = 'SIMILAR_ASSETS';
  static const scaledVariant = 'SCALED_VARIANT';
  static const similarSvg = 'SIMILAR_SVG';

  // hygiene
  static const largeAsset = 'LARGE_ASSET';
  static const pngWithoutAlpha = 'PNG_WITHOUT_ALPHA';
  static const problematicFilename = 'PROBLEMATIC_FILENAME';
  static const caseCollision = 'CASE_COLLISION';
  static const unusedFontFamily = 'UNUSED_FONT_FAMILY';
  static const emptyAssetDirectory = 'EMPTY_ASSET_DIRECTORY';
}

/// A source location backing a finding — where a reference was seen, or where
/// a pubspec declared something. Paths are project-relative and POSIX-style.
class Occurrence {
  const Occurrence({
    required this.file,
    this.line,
    this.column,
    this.snippet,
  });

  final String file;
  final int? line;
  final int? column;
  final String? snippet;

  String get display =>
      line == null ? file : '$file:$line${column == null ? '' : ':$column'}';

  Map<String, Object?> toJson() => <String, Object?>{
        'file': file,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
        if (snippet != null) 'snippet': snippet,
      };
}

/// One reported problem.
///
/// [path] is the primary subject (may be null for findings about a group or
/// about the project as a whole). [relatedPaths] carries the rest of a group,
/// e.g. the other members of a duplicate set. [data] is free-form structured
/// detail that renderers may use but consumers should treat as optional.
class Finding {
  Finding({
    required this.severity,
    required this.code,
    required this.message,
    this.path,
    List<Occurrence>? occurrences,
    List<String>? relatedPaths,
    Map<String, Object?>? data,
  })  : occurrences = List<Occurrence>.unmodifiable(occurrences ?? const []),
        relatedPaths = List<String>.unmodifiable(relatedPaths ?? const []),
        data = Map<String, Object?>.unmodifiable(data ?? const {});

  final Severity severity;
  final String code;
  final String message;
  final String? path;
  final List<Occurrence> occurrences;
  final List<String> relatedPaths;
  final Map<String, Object?> data;

  /// Bytes that would be reclaimed by acting on this finding, when meaningful.
  int get reclaimableBytes {
    final value = data['reclaimableBytes'];
    return value is int ? value : 0;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'severity': severity.label,
        'code': code,
        'message': message,
        'path': path,
        'occurrences': occurrences
            .map((Occurrence o) => o.toJson())
            .toList(growable: false),
        'relatedPaths': relatedPaths,
        if (data.isNotEmpty) 'data': data,
      };

  @override
  String toString() =>
      '[$code] ${severity.label}: $message${path == null ? '' : ' ($path)'}';
}

/// Sorts most severe first, then by code, then by path, so report output and
/// test expectations are deterministic across platforms.
int compareFindings(Finding a, Finding b) {
  final bySeverity = b.severity.index.compareTo(a.severity.index);
  if (bySeverity != 0) return bySeverity;
  final byCode = a.code.compareTo(b.code);
  if (byCode != 0) return byCode;
  return (a.path ?? '').compareTo(b.path ?? '');
}
