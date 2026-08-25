import '../hashing/perceptual_hash.dart';
import '../hashing/svg_normalizer.dart';
import '../models/asset.dart';
import '../models/finding.dart';
import '../models/project_context.dart';
import '../util/paths.dart';
import 'check.dart';

/// Finds near-duplicate images that exact hashing misses: re-exports,
/// recompressions, and hand-resized copies.
///
/// Resolution variants are excluded outright — a `2.0x/` file is *supposed* to
/// be the same drawing at a different size, and flagging it would train users
/// to ignore this check.
class SimilarCheck implements Check {
  const SimilarCheck();

  @override
  String get id => CheckId.similar;

  @override
  String get name => 'Similar assets';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async {
    return <Finding>[
      ..._rasterFindings(ctx),
      ..._svgFindings(ctx),
    ];
  }

  List<Finding> _rasterFindings(ProjectContext ctx) {
    // One representative per exact-duplicate set: those are already reported by
    // the duplicate check and would otherwise appear twice.
    final representatives = <String, AssetFile>{};
    final fingerprints = <String, ImageFingerprint>{};

    for (final AssetFile asset in ctx.assets) {
      if (asset.isVariant) continue;
      if (!kRasterExtensions.contains(asset.extension)) continue;

      final fingerprint = ctx.content.fingerprintOf(asset);
      if (fingerprint == null) continue;

      final hash = ctx.content.sha256Of(asset) ?? asset.path;
      if (representatives.containsKey(hash)) continue;
      representatives[hash] = asset;
      fingerprints[asset.path] = fingerprint;
    }

    final items = representatives.values.toList(growable: false);
    final groups = _group(
      items,
      (AssetFile a, AssetFile b) =>
          hammingDistance(
            fingerprints[a.path]!.dHash,
            fingerprints[b.path]!.dHash,
          ) <=
          ctx.config.similarityThreshold,
    );

    final findings = <Finding>[];
    for (final List<AssetFile> group in groups) {
      group.sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));

      final scaled = _scaledPair(group, fingerprints);
      final total = group.fold<int>(0, (int s, AssetFile a) => s + a.sizeBytes);
      final largest = group.fold<int>(
          0, (int m, AssetFile a) => a.sizeBytes > m ? a.sizeBytes : m);

      final dimensions = <String, String>{
        for (final AssetFile a in group)
          a.path:
              '${fingerprints[a.path]!.width}x${fingerprints[a.path]!.height}',
      };

      findings.add(Finding(
        severity: Severity.warning,
        code: scaled ? FindingCode.scaledVariant : FindingCode.similarAssets,
        message: scaled
            ? '${group.length} files are the same image at different pixel '
                'sizes. If this is intentional, move the larger one into a '
                '`2.0x/` folder so Flutter picks the right one per device.'
            : '${group.length} visually near-identical images '
                '(${humanBytes(total - largest)} reclaimable if deduplicated).',
        path: group.first.path,
        relatedPaths:
            group.skip(1).map((AssetFile a) => a.path).toList(growable: false),
        data: <String, Object?>{
          'reclaimableBytes': total - largest,
          'dimensions': dimensions,
          'threshold': ctx.config.similarityThreshold,
          'count': group.length,
        },
      ));
    }
    return findings;
  }

  /// True when two members share a dHash but differ in size — the signature of
  /// a manual resize rather than two genuinely different images.
  bool _scaledPair(
      List<AssetFile> group, Map<String, ImageFingerprint> prints) {
    for (var i = 0; i < group.length; i++) {
      for (var j = i + 1; j < group.length; j++) {
        final a = prints[group[i].path]!;
        final b = prints[group[j].path]!;
        if (a.dHash == b.dHash && !a.hasSameDimensionsAs(b)) return true;
      }
    }
    return false;
  }

  List<Finding> _svgFindings(ProjectContext ctx) {
    final normalizer = ctx.content.svgNormalizer;
    final representatives = <String, AssetFile>{};
    final normalizedHashes = <String, String>{};
    final pathData = <String, String>{};

    for (final AssetFile asset in ctx.assets) {
      if (asset.isVariant || asset.extension != '.svg') continue;

      final text = ctx.content.textOf(asset);
      if (text == null) continue;
      final hash = normalizer.normalizedHash(text);
      if (hash == null) continue;

      final sha = ctx.content.sha256Of(asset) ?? asset.path;
      if (representatives.containsKey(sha)) continue;
      representatives[sha] = asset;
      normalizedHashes[asset.path] = hash;
      pathData[asset.path] = normalizer.pathData(text);
    }

    // Map the Hamming budget onto a bigram-similarity ratio: threshold 5 of 64
    // bits becomes ~0.92 similarity.
    final ratio = (1 - (ctx.config.similarityThreshold / 64))
        .clamp(0.5, 0.999)
        .toDouble();

    final items = representatives.values.toList(growable: false);
    final groups = _group(items, (AssetFile a, AssetFile b) {
      if (normalizedHashes[a.path] == normalizedHashes[b.path]) return true;
      final left = pathData[a.path] ?? '';
      final right = pathData[b.path] ?? '';
      if (left.isEmpty || right.isEmpty) return false;
      return bigramSimilarity(left, right) >= ratio;
    });

    final findings = <Finding>[];
    for (final List<AssetFile> group in groups) {
      group.sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));
      final identical = group.every((AssetFile a) =>
          normalizedHashes[a.path] == normalizedHashes[group.first.path]);
      final total = group.fold<int>(0, (int s, AssetFile a) => s + a.sizeBytes);
      final largest = group.fold<int>(
          0, (int m, AssetFile a) => a.sizeBytes > m ? a.sizeBytes : m);

      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.similarSvg,
        message: identical
            ? '${group.length} SVGs are identical once ids, comments and '
                'whitespace are normalized.'
            : '${group.length} SVGs share near-identical path geometry.',
        path: group.first.path,
        relatedPaths:
            group.skip(1).map((AssetFile a) => a.path).toList(growable: false),
        data: <String, Object?>{
          'reclaimableBytes': total - largest,
          'normalizedIdentical': identical,
          'count': group.length,
        },
      ));
    }
    return findings;
  }

  /// Single-link clustering via union-find, so A~B and B~C put all three in one
  /// group even when A and C are just outside the threshold.
  List<List<AssetFile>> _group(
    List<AssetFile> items,
    bool Function(AssetFile a, AssetFile b) related,
  ) {
    if (items.length < 2) return const <List<AssetFile>>[];

    final parent = List<int>.generate(items.length, (int i) => i);

    int find(int x) {
      var root = x;
      while (parent[root] != root) {
        root = parent[root];
      }
      while (parent[x] != root) {
        final next = parent[x];
        parent[x] = root;
        x = next;
      }
      return root;
    }

    for (var i = 0; i < items.length; i++) {
      for (var j = i + 1; j < items.length; j++) {
        if (find(i) == find(j)) continue;
        if (related(items[i], items[j])) parent[find(j)] = find(i);
      }
    }

    final clusters = <int, List<AssetFile>>{};
    for (var i = 0; i < items.length; i++) {
      clusters.putIfAbsent(find(i), () => <AssetFile>[]).add(items[i]);
    }

    return clusters.values
        .where((List<AssetFile> group) => group.length > 1)
        .toList(growable: false);
  }
}
