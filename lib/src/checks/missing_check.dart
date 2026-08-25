import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/asset.dart';
import '../models/finding.dart';
import '../models/project_context.dart';
import '../models/reference.dart';
import 'check.dart';

/// Catches the three ways a pubspec and the filesystem can disagree.
///
/// The first two are runtime crashes waiting to happen, so they are errors; the
/// third is only waste, so it is a warning.
class MissingCheck implements Check {
  const MissingCheck();

  @override
  String get id => CheckId.missing;

  @override
  String get name => 'Missing and undeclared assets';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async {
    final findings = <Finding>[];

    for (final AssetDeclaration declaration in ctx.missingDeclarations) {
      findings.add(Finding(
        severity: Severity.error,
        code: FindingCode.missingDeclaredAsset,
        message: '${declaration.packageName} declares '
            '`${declaration.rawEntry}` but nothing exists at that path.',
        path: declaration.directoryPath,
        occurrences: <Occurrence>[declaration.origin],
        data: <String, Object?>{
          'package': declaration.packageName,
          'entry': declaration.rawEntry,
          'kind': declaration.kind.name,
        },
      ));
    }

    // Without a Flutter package there is no asset bundle to be missing from,
    // and asset-shaped strings in a pure-Dart workspace are just strings.
    final reported = <String>{};
    for (final AssetReference reference in ctx.hasFlutterPackage
        ? ctx.unmatchedReferences
        : const <AssetReference>[]) {
      if (!reported.add(reference.value)) continue;

      final existsOnDisk = _existsSomewhere(ctx, reference.value);
      findings.add(Finding(
        severity: Severity.error,
        code: FindingCode.undeclaredReference,
        message: existsOnDisk
            ? 'Code references `${reference.value}`, which exists on disk but '
                'is not covered by any pubspec `assets:` entry — it will be '
                'missing from the bundle at runtime.'
            : 'Code references `${reference.value}`, but no such file exists '
                'and nothing declares it.',
        path: reference.value,
        occurrences: <Occurrence>[reference.occurrence],
        data: <String, Object?>{
          'existsOnDisk': existsOnDisk,
          'via': reference.via,
        },
      ));
    }

    for (final AssetFile asset in ctx.assets) {
      // A variant is covered by whatever covers its parent.
      if (asset.isVariant || asset.isDeclared) continue;

      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.undeclaredOnDisk,
        message: '${asset.path} sits in an asset directory but no pubspec '
            'entry covers it, so it will not ship.',
        path: asset.path,
        data: <String, Object?>{
          'package': asset.packageName,
          'sizeBytes': asset.sizeBytes,
        },
      ));
    }

    return findings;
  }

  /// A reference is package-relative, so it has to be tried against every
  /// package root before concluding the file is absent.
  bool _existsSomewhere(ProjectContext ctx, String reference) {
    for (final PackageContext package in ctx.packages) {
      if (File(p.join(package.rootDirectory, reference)).existsSync()) {
        return true;
      }
    }
    return File(p.join(ctx.root, reference)).existsSync();
  }
}
