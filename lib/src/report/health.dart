import '../models/asset.dart';
import '../models/finding.dart';
import '../runner.dart';

/// An at-a-glance score for the state of a project's assets.
///
/// The score answers one question: *what fraction of the asset tree is in good
/// shape?* Every asset is worth one point, reduced by the worst finding
/// against it, and the percentage is the average.
///
/// Two deliberate choices keep the number honest:
///
/// * **Info findings do not count.** `POSSIBLY_USED_ASSET` is the audit being
///   careful about a dynamic reference, not a defect — scoring it would punish
///   a project for patterns the tool explicitly supports. PNG format hints are
///   suggestions, not problems.
/// * **Findings with no file behind them still count.** A pubspec entry
///   pointing at a missing directory belongs to no asset on disk; ignoring it
///   would let a broken pubspec score 100%.
class HealthScore {
  const HealthScore({
    required this.score,
    required this.totalAssets,
    required this.cleanAssets,
    required this.assetsWithWarning,
    required this.assetsWithError,
    required this.projectLevelErrors,
    required this.projectLevelWarnings,
    required this.reclaimableBytes,
    required this.totalBytes,
  });

  /// Points awarded per asset, by the worst finding against it.
  static const double _cleanWeight = 1;
  static const double _warningWeight = 0.5;
  static const double _errorWeight = 0;

  factory HealthScore.from(AuditResult result) {
    final assets = result.context.assets;
    final byPath = result.context.assetByPath;

    // Worst non-info severity recorded against each asset.
    final worst = <String, Severity>{};
    var projectErrors = 0;
    var projectWarnings = 0;

    for (final Finding finding in result.findings) {
      if (finding.severity == Severity.info) continue;

      final subjects = <String>[
        if (finding.path != null) finding.path!,
        ...finding.relatedPaths,
      ].where(byPath.containsKey).toSet();

      if (subjects.isEmpty) {
        if (finding.severity == Severity.error) {
          projectErrors++;
        } else {
          projectWarnings++;
        }
        continue;
      }

      for (final String path in subjects) {
        final Severity? current = worst[path];
        if (current == null || finding.severity.index > current.index) {
          worst[path] = finding.severity;
        }
      }
    }

    var clean = 0;
    var warned = 0;
    var errored = 0;
    for (final AssetFile asset in assets) {
      switch (worst[asset.path]) {
        case Severity.error:
          errored++;
        case Severity.warning:
          warned++;
        case _:
          clean++;
      }
    }

    final units = assets.length + projectErrors + projectWarnings;
    final points = clean * _cleanWeight +
        warned * _warningWeight +
        errored * _errorWeight +
        projectWarnings * _warningWeight +
        projectErrors * _errorWeight;

    return HealthScore(
      // A project with nothing to audit is not unhealthy.
      score: units == 0 ? 100 : (points / units) * 100,
      totalAssets: assets.length,
      cleanAssets: clean,
      assetsWithWarning: warned,
      assetsWithError: errored,
      projectLevelErrors: projectErrors,
      projectLevelWarnings: projectWarnings,
      reclaimableBytes: result.findings
          .where((Finding f) => f.code == FindingCode.unusedAsset)
          .fold<int>(0, (int sum, Finding f) => sum + f.reclaimableBytes),
      totalBytes:
          assets.fold<int>(0, (int sum, AssetFile a) => sum + a.sizeBytes),
    );
  }

  /// 0–100.
  final double score;

  final int totalAssets;
  final int cleanAssets;
  final int assetsWithWarning;
  final int assetsWithError;

  /// Findings that concern the project rather than a file on disk, such as a
  /// declared directory that doesn't exist.
  final int projectLevelErrors;
  final int projectLevelWarnings;

  /// Bytes recoverable by deleting unused assets. Duplicate and near-duplicate
  /// groups are excluded because a human still has to choose a survivor.
  final int reclaimableBytes;

  final int totalBytes;

  int get roundedScore => score.round();

  /// Share of the bundle that unused files account for.
  double get wastePercent =>
      totalBytes == 0 ? 0 : (reclaimableBytes / totalBytes) * 100;

  /// Coarse band for dashboards and PR comments.
  String get grade {
    if (score >= 90) return 'A';
    if (score >= 80) return 'B';
    if (score >= 70) return 'C';
    if (score >= 60) return 'D';
    return 'F';
  }

  /// A fixed-width meter, e.g. `████████████████░░░░`.
  String bar({int width = 20}) {
    final filled = ((score / 100) * width).round().clamp(0, width);
    return '${'█' * filled}${'░' * (width - filled)}';
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'score': double.parse(score.toStringAsFixed(1)),
        'grade': grade,
        'totalAssets': totalAssets,
        'cleanAssets': cleanAssets,
        'assetsWithWarning': assetsWithWarning,
        'assetsWithError': assetsWithError,
        'projectLevelErrors': projectLevelErrors,
        'projectLevelWarnings': projectLevelWarnings,
        'reclaimableBytes': reclaimableBytes,
        'totalBytes': totalBytes,
        'wastePercent': double.parse(wastePercent.toStringAsFixed(1)),
      };
}
