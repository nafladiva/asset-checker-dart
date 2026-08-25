import '../models/asset.dart';
import '../models/finding.dart';
import '../models/project_context.dart';
import '../util/paths.dart';
import 'check.dart';

/// Groups byte-identical assets by SHA-256.
///
/// Zero-byte files are reported on their own rather than grouped: they all hash
/// alike, so lumping them together would produce one meaningless mega-group.
class DuplicateCheck implements Check {
  const DuplicateCheck();

  @override
  String get id => CheckId.dupes;

  @override
  String get name => 'Duplicate assets';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async {
    final findings = <Finding>[];
    final byHash = <String, List<AssetFile>>{};

    for (final AssetFile asset in ctx.assets) {
      if (asset.sizeBytes == 0) {
        findings.add(Finding(
          severity: Severity.warning,
          code: FindingCode.emptyFile,
          message: '${asset.path} is empty (0 bytes).',
          path: asset.path,
          data: <String, Object?>{'package': asset.packageName},
        ));
        continue;
      }

      final hash = ctx.content.sha256Of(asset);
      if (hash == null) continue;
      byHash.putIfAbsent(hash, () => <AssetFile>[]).add(asset);
    }

    final groups = byHash.entries
        .where((MapEntry<String, List<AssetFile>> e) => e.value.length > 1)
        .toList()
      ..sort((MapEntry<String, List<AssetFile>> a,
              MapEntry<String, List<AssetFile>> b) =>
          a.value.first.path.compareTo(b.value.first.path));

    for (final MapEntry<String, List<AssetFile>> entry in groups) {
      final members = entry.value
        ..sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));
      final unitSize = members.first.sizeBytes;
      final wasted = unitSize * (members.length - 1);

      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.duplicateAssets,
        message: '${members.length} byte-identical copies of the same file '
            '(${humanBytes(unitSize)} each, ${humanBytes(wasted)} wasted).',
        path: members.first.path,
        relatedPaths: members
            .skip(1)
            .map((AssetFile a) => a.path)
            .toList(growable: false),
        data: <String, Object?>{
          'reclaimableBytes': wasted,
          'sha256': entry.key,
          'sizeBytes': unitSize,
          'count': members.length,
        },
      ));
    }

    return findings;
  }
}
