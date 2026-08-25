import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../models/asset.dart';
import 'exact_hash.dart';
import 'perceptual_hash.dart';
import 'svg_normalizer.dart';

/// Reads each asset at most once per kind of derived value.
///
/// The duplicate, similarity and hygiene checks all want to look at the same
/// bytes; without this they would each re-read and re-decode the tree.
class ContentCache {
  ContentCache({
    required this.maxHashSizeBytes,
    PerceptualHasher hasher = const PerceptualHasher(),
    this.svgNormalizer = const SvgNormalizer(),
  }) : _hasher = hasher;

  /// Files larger than this are not perceptually hashed — decoding them costs
  /// far more than the duplicate detection is worth.
  final int maxHashSizeBytes;

  final PerceptualHasher _hasher;
  final SvgNormalizer svgNormalizer;

  final Map<String, String?> _sha = <String, String?>{};
  final Map<String, ImageFingerprint?> _fingerprints =
      <String, ImageFingerprint?>{};
  final Map<String, String?> _text = <String, String?>{};

  /// Paths skipped by the perceptual hasher because of [maxHashSizeBytes].
  final Set<String> skippedForSize = <String>{};

  Uint8List? bytesOf(AssetFile asset) {
    try {
      return File(asset.absolutePath).readAsBytesSync();
    } on FileSystemException {
      return null;
    }
  }

  /// `null` when the file could not be read.
  String? sha256Of(AssetFile asset) {
    return _sha.putIfAbsent(asset.path, () {
      final bytes = bytesOf(asset);
      return bytes == null ? null : sha256Hex(bytes);
    });
  }

  /// `null` for non-raster, oversized, or undecodable files.
  ImageFingerprint? fingerprintOf(AssetFile asset) {
    return _fingerprints.putIfAbsent(asset.path, () {
      if (!kRasterExtensions.contains(asset.extension)) return null;
      if (asset.sizeBytes > maxHashSizeBytes) {
        skippedForSize.add(asset.path);
        return null;
      }
      final bytes = bytesOf(asset);
      if (bytes == null) return null;
      return _hasher.fingerprint(bytes);
    });
  }

  /// UTF-8 text of the asset, or `null` if it isn't valid UTF-8.
  String? textOf(AssetFile asset) {
    return _text.putIfAbsent(asset.path, () {
      final bytes = bytesOf(asset);
      if (bytes == null) return null;
      try {
        return utf8.decode(bytes);
      } on FormatException {
        return null;
      }
    });
  }
}
