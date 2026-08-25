import '../models/asset.dart';
import '../models/finding.dart';
import '../models/project_context.dart';
import '../models/reference.dart';
import '../util/paths.dart';
import 'check.dart';

/// Reports assets nothing references, and — separately — the dynamic patterns
/// that made other assets un-analysable.
///
/// Resolution variants are never reported on their own: `2.0x/logo.png` exists
/// because `logo.png` does, so the parent is the only meaningful subject.
class UnusedCheck implements Check {
  const UnusedCheck();

  @override
  String get id => CheckId.unused;

  @override
  String get name => 'Unused assets';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async {
    final findings = <Finding>[];

    for (final AssetFile asset in ctx.assets) {
      if (asset.isVariant) continue;

      switch (ctx.usageOf(asset.path)) {
        case UsageStatus.unused:
          final variants = ctx.variantsOf(asset.path).toList(growable: false);
          final reclaimable = asset.sizeBytes +
              variants.fold<int>(
                  0, (int sum, AssetFile v) => sum + v.sizeBytes);

          findings.add(Finding(
            severity: Severity.warning,
            code: FindingCode.unusedAsset,
            message: 'Nothing references ${asset.path} '
                '(${humanBytes(asset.sizeBytes)}).',
            path: asset.path,
            relatedPaths:
                variants.map((AssetFile v) => v.path).toList(growable: false),
            data: <String, Object?>{
              'reclaimableBytes': reclaimable,
              'sizeBytes': asset.sizeBytes,
              'package': asset.packageName,
              'declared': asset.isDeclared,
              'variantCount': variants.length,
            },
          ));

        case UsageStatus.possiblyUsed:
          final occurrences =
              ctx.occurrencesByAsset[asset.path] ?? const <Occurrence>[];
          findings.add(Finding(
            severity: Severity.info,
            code: FindingCode.possiblyUsedAsset,
            message: 'Only a dynamic reference could reach ${asset.path}; '
                'it will never be reported as unused or deleted.',
            path: asset.path,
            occurrences: occurrences.take(5).toList(growable: false),
            data: <String, Object?>{
              'sizeBytes': asset.sizeBytes,
              'package': asset.packageName,
            },
          ));

        case UsageStatus.used:
          break;
      }
    }

    for (final DynamicReference reference in ctx.dynamicReferences) {
      final covered = reference.prefix.isEmpty
          ? const <String>[]
          : ctx.assets
              .where((AssetFile a) =>
                  a.path.startsWith('${reference.prefix}/') ||
                  a.packagePath.startsWith('${reference.prefix}/'))
              .map((AssetFile a) => a.path)
              .toList(growable: false);

      findings.add(Finding(
        severity: Severity.info,
        code: FindingCode.dynamicReference,
        message: reference.prefix.isEmpty
            ? 'Dynamic asset path `${reference.rawSource}` — matched by '
                'filename only. Review that the intended files are covered.'
            : 'Dynamic asset path `${reference.rawSource}` pins to '
                '${reference.prefix}/; all ${covered.length} file(s) under it '
                'are treated as possibly used.',
        path: reference.prefix.isEmpty ? null : reference.prefix,
        occurrences: <Occurrence>[reference.occurrence],
        relatedPaths: covered,
        data: <String, Object?>{
          'prefix': reference.prefix,
          'via': reference.via,
          'coveredCount': covered.length,
        },
      ));
    }

    for (final UnresolvableReference reference in ctx.unresolvableReferences) {
      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.unresolvableDynamicReference,
        message: 'Unresolvable asset load `${reference.expression}`. '
            '${reference.reason} Review it by hand — this call can reach '
            'assets the audit cannot see.',
        occurrences: <Occurrence>[reference.occurrence],
        data: <String, Object?>{'reason': reference.reason},
      ));
    }

    return findings;
  }
}
