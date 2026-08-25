import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Canonicalises SVG source so that cosmetically-different but visually
/// identical files hash to the same value.
///
/// Strips XML declarations, DOCTYPEs, comments and `id` attributes (which
/// design tools regenerate on every export), collapses whitespace, and rounds
/// numeric literals so sub-pixel export jitter doesn't defeat the comparison.
class SvgNormalizer {
  const SvgNormalizer({this.precision = 2});

  /// Decimal places kept when rounding numbers in the markup.
  final int precision;

  static final RegExp _xmlDeclaration = RegExp(r'<\?xml[^>]*\?>');
  static final RegExp _docType =
      RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false);
  static final RegExp _comment = RegExp(r'<!--.*?-->', dotAll: true);
  static final RegExp _idAttribute = RegExp(
      r'''\s(?:id|xml:id|data-name|inkscape:label|sodipodi:\w+)\s*=\s*(["']).*?\1''');
  static final RegExp _betweenTags = RegExp(r'>\s+<');
  static final RegExp _whitespaceRun = RegExp(r'\s+');
  static final RegExp _number = RegExp(r'-?\d+\.\d+');
  static final RegExp _pathData =
      RegExp(r'''\sd\s*=\s*(["'])(.*?)\1''', dotAll: true);

  /// Returns canonical SVG text, or `null` if [source] isn't parseable as SVG.
  String? normalize(String source) {
    if (!source.contains('<svg')) return null;
    var out = source
        .replaceAll(_xmlDeclaration, '')
        .replaceAll(_docType, '')
        .replaceAll(_comment, '')
        .replaceAll(_idAttribute, '');
    out = out.replaceAll(_betweenTags, '><');
    out = out.replaceAll(_whitespaceRun, ' ');
    out = _roundNumbers(out);
    return out.trim();
  }

  String _roundNumbers(String input) {
    return input.replaceAllMapped(_number, (Match m) {
      final value = double.tryParse(m[0]!);
      if (value == null) return m[0]!;
      final rounded = value.toStringAsFixed(precision);
      // Drop trailing zeros so 3.10 and 3.1 agree.
      return rounded.contains('.')
          ? rounded
              .replaceFirst(RegExp(r'0+$'), '')
              .replaceFirst(RegExp(r'\.$'), '')
          : rounded;
    });
  }

  /// Hash of the normalized form — equal hashes mean "same drawing".
  String? normalizedHash(String source) {
    final normalized = normalize(source);
    if (normalized == null) return null;
    return sha256.convert(utf8.encode(normalized)).toString();
  }

  /// Concatenated, normalized `d="..."` geometry. This is the part that
  /// actually describes the shape, so near-matches are compared on it rather
  /// than on full markup (which is dominated by styling noise).
  String pathData(String source) {
    final buffer = StringBuffer();
    for (final Match m in _pathData.allMatches(source)) {
      buffer.write(_roundNumbers(m[2]!.replaceAll(_whitespaceRun, ' ').trim()));
      buffer.write(' ');
    }
    return buffer.toString().trim();
  }
}

/// Dice coefficient over character bigrams: 1.0 identical, 0.0 disjoint.
///
/// Chosen over edit distance because it's O(n) and insensitive to reordering of
/// independent subpaths, which is exactly how SVG exporters differ.
double bigramSimilarity(String a, String b) {
  if (a == b) return 1;
  if (a.length < 2 || b.length < 2) return 0;

  final counts = <String, int>{};
  for (var i = 0; i < a.length - 1; i++) {
    final gram = a.substring(i, i + 2);
    counts[gram] = (counts[gram] ?? 0) + 1;
  }

  var overlap = 0;
  for (var i = 0; i < b.length - 1; i++) {
    final gram = b.substring(i, i + 2);
    final remaining = counts[gram] ?? 0;
    if (remaining > 0) {
      counts[gram] = remaining - 1;
      overlap++;
    }
  }

  return (2 * overlap) / ((a.length - 1) + (b.length - 1));
}
