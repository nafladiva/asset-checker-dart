import '../models/finding.dart';
import '../runner.dart';
import 'health.dart';

/// Renders an [AuditResult] as text. Implementations must be pure so output can
/// be asserted in tests and diffed in CI.
abstract class Reporter {
  String render(AuditResult result);
}

/// Headline counts shared by every renderer, so the three formats can never
/// disagree about the numbers.
class AuditSummary {
  AuditSummary._({
    required this.assetCount,
    required this.packageCount,
    required this.unusedCount,
    required this.possiblyUsedCount,
    required this.reclaimableBytes,
    required this.duplicateGroups,
    required this.similarGroups,
    required this.dynamicReferenceCount,
    required this.unresolvableCount,
    required this.errorCount,
    required this.warningCount,
    required this.infoCount,
    required this.health,
  });

  factory AuditSummary.from(AuditResult result) {
    var unused = 0;
    var possiblyUsed = 0;
    var reclaimable = 0;
    var duplicates = 0;
    var similar = 0;
    var dynamicRefs = 0;
    var unresolvable = 0;

    for (final Finding finding in result.findings) {
      switch (finding.code) {
        case FindingCode.unusedAsset:
          unused++;
          // Only unused files are genuinely reclaimable; duplicate and similar
          // groups need a human to pick a survivor first.
          reclaimable += finding.reclaimableBytes;
        case FindingCode.possiblyUsedAsset:
          possiblyUsed++;
        case FindingCode.duplicateAssets:
          duplicates++;
        case FindingCode.similarAssets:
        case FindingCode.scaledVariant:
        case FindingCode.similarSvg:
          similar++;
        case FindingCode.dynamicReference:
          dynamicRefs++;
        case FindingCode.unresolvableDynamicReference:
          unresolvable++;
      }
    }

    return AuditSummary._(
      assetCount: result.context.assets.length,
      packageCount: result.context.packages.length,
      unusedCount: unused,
      possiblyUsedCount: possiblyUsed,
      reclaimableBytes: reclaimable,
      duplicateGroups: duplicates,
      similarGroups: similar,
      dynamicReferenceCount: dynamicRefs,
      unresolvableCount: unresolvable,
      errorCount: result.errorCount,
      warningCount: result.warningCount,
      infoCount: result.infoCount,
      health: HealthScore.from(result),
    );
  }

  final int assetCount;
  final int packageCount;
  final int unusedCount;
  final int possiblyUsedCount;
  final int reclaimableBytes;
  final int duplicateGroups;
  final int similarGroups;
  final int dynamicReferenceCount;
  final int unresolvableCount;
  final int errorCount;
  final int warningCount;
  final int infoCount;

  /// Overall health of the asset tree, 0–100.
  final HealthScore health;

  Map<String, Object?> toJson() => <String, Object?>{
        'assetCount': assetCount,
        'packageCount': packageCount,
        'unused': unusedCount,
        'possiblyUsed': possiblyUsedCount,
        'reclaimableBytes': reclaimableBytes,
        'duplicateGroups': duplicateGroups,
        'similarGroups': similarGroups,
        'dynamicReferences': dynamicReferenceCount,
        'unresolvableReferences': unresolvableCount,
        'errors': errorCount,
        'warnings': warningCount,
        'info': infoCount,
        'health': health.toJson(),
      };
}

/// Human-facing section titles, keyed by finding code. Kept in one place so the
/// pretty and markdown renderers group identically.
const Map<String, String> kSectionTitles = <String, String>{
  FindingCode.unusedAsset: 'Unused assets',
  FindingCode.possiblyUsedAsset: 'Possibly used (dynamic reference)',
  FindingCode.dynamicReference: 'Dynamic references',
  FindingCode.unresolvableDynamicReference: 'Unresolvable dynamic references',
  FindingCode.missingDeclaredAsset: 'Declared but missing from disk',
  FindingCode.undeclaredReference: 'Referenced but not declared',
  FindingCode.undeclaredOnDisk: 'On disk but not declared',
  FindingCode.duplicateAssets: 'Exact duplicates',
  FindingCode.emptyFile: 'Empty files',
  FindingCode.similarAssets: 'Near-duplicate images',
  FindingCode.scaledVariant: 'Scaled variants',
  FindingCode.similarSvg: 'Near-duplicate SVGs',
  FindingCode.largeAsset: 'Large files',
  FindingCode.pngWithoutAlpha: 'PNG format hints',
  FindingCode.problematicFilename: 'Problematic filenames',
  FindingCode.caseCollision: 'Case collisions',
  FindingCode.unusedFontFamily: 'Unused font families',
  FindingCode.emptyAssetDirectory: 'Empty asset directories',
};

/// Groups findings by code, preserving the severity-sorted order they arrive in
/// so the most serious sections come first.
Map<String, List<Finding>> groupByCode(List<Finding> findings) {
  final grouped = <String, List<Finding>>{};
  for (final Finding finding in findings) {
    grouped.putIfAbsent(finding.code, () => <Finding>[]).add(finding);
  }
  return grouped;
}
