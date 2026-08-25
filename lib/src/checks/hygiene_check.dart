import '../hashing/perceptual_hash.dart';
import '../models/asset.dart';
import '../models/finding.dart';
import '../models/project_context.dart';
import '../util/paths.dart';
import 'check.dart';

/// Non-blocking quality warnings, plus one genuine landmine: two paths that
/// differ only by case build fine on macOS and Windows and fail on Linux CI.
class HygieneCheck implements Check {
  const HygieneCheck();

  @override
  String get id => CheckId.hygiene;

  @override
  String get name => 'Hygiene';

  @override
  Future<List<Finding>> run(ProjectContext ctx) async {
    final findings = <Finding>[
      ..._sizeAndFormat(ctx),
      ..._filenames(ctx),
      ..._caseCollisions(ctx),
      ..._fonts(ctx),
      ..._emptyDirectories(ctx),
    ];
    return findings;
  }

  List<Finding> _sizeAndFormat(ProjectContext ctx) {
    final findings = <Finding>[];

    for (final AssetFile asset in ctx.assets) {
      if (asset.sizeBytes > ctx.config.maxFileSizeBytes) {
        findings.add(Finding(
          severity: Severity.warning,
          code: FindingCode.largeAsset,
          message: '${asset.path} is ${humanBytes(asset.sizeBytes)} '
              '(limit ${ctx.config.maxFileSizeKb} KB). Consider WebP, or a '
              'smaller source image with `2.0x/` variants.',
          path: asset.path,
          data: <String, Object?>{
            'sizeBytes': asset.sizeBytes,
            'limitBytes': ctx.config.maxFileSizeBytes,
          },
        ));
      }

      if (asset.extension != '.png') continue;
      final ImageFingerprint? fingerprint = ctx.content.fingerprintOf(asset);
      if (fingerprint == null) continue;

      if (!fingerprint.hasAlphaChannel) {
        findings.add(Finding(
          severity: Severity.info,
          code: FindingCode.pngWithoutAlpha,
          message: '${asset.path} is a PNG with no alpha channel. WebP or JPEG '
              'would usually be smaller at the same quality.',
          path: asset.path,
          data: <String, Object?>{'sizeBytes': asset.sizeBytes},
        ));
      } else if (!fingerprint.usesTransparency) {
        findings.add(Finding(
          severity: Severity.info,
          code: FindingCode.pngWithoutAlpha,
          message: '${asset.path} carries an alpha channel but every pixel is '
              'opaque — the channel is pure overhead.',
          path: asset.path,
          data: <String, Object?>{
            'sizeBytes': asset.sizeBytes,
            'alphaUnused': true,
          },
        ));
      }
    }
    return findings;
  }

  List<Finding> _filenames(ProjectContext ctx) {
    final findings = <Finding>[];

    for (final AssetFile asset in ctx.assets) {
      final name = asset.basename;
      final problems = <String>[
        if (name.contains(' ')) 'spaces',
        if (name != name.toLowerCase()) 'uppercase letters',
        if (name.codeUnits.any((int c) => c > 127)) 'non-ASCII characters',
      ];
      if (problems.isEmpty) continue;

      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.problematicFilename,
        message: '${asset.path} contains ${problems.join(' and ')}. '
            'Asset lookups are case- and byte-sensitive on Android and iOS.',
        path: asset.path,
        data: <String, Object?>{'problems': problems},
      ));
    }
    return findings;
  }

  /// Two files whose paths differ only by case cannot coexist on a
  /// case-insensitive checkout, so this is an error rather than a warning.
  List<Finding> _caseCollisions(ProjectContext ctx) {
    final byLowercase = <String, List<AssetFile>>{};
    for (final AssetFile asset in ctx.assets) {
      byLowercase
          .putIfAbsent(asset.path.toLowerCase(), () => <AssetFile>[])
          .add(asset);
    }

    final findings = <Finding>[];
    for (final List<AssetFile> group in byLowercase.values) {
      if (group.length < 2) continue;
      group.sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));

      findings.add(Finding(
        severity: Severity.error,
        code: FindingCode.caseCollision,
        message: '${group.length} asset paths differ only by case. This builds '
            'on macOS and Windows and fails on case-sensitive Linux CI.',
        path: group.first.path,
        relatedPaths:
            group.skip(1).map((AssetFile a) => a.path).toList(growable: false),
        data: <String, Object?>{'count': group.length},
      ));
    }
    return findings;
  }

  List<Finding> _fonts(ProjectContext ctx) {
    final findings = <Finding>[];

    for (final FontFamilyDeclaration font in ctx.allFonts) {
      if (ctx.fontFamilyMentions.contains(font.family)) continue;

      findings.add(Finding(
        severity: Severity.warning,
        code: FindingCode.unusedFontFamily,
        message: 'Font family "${font.family}" is declared by '
            '${font.packageName} but its name never appears in any string, so '
            'no `TextStyle` can be selecting it.',
        path: font.assetPaths.isEmpty ? null : font.assetPaths.first,
        occurrences: <Occurrence>[font.origin],
        relatedPaths: font.assetPaths,
        data: <String, Object?>{
          'family': font.family,
          'package': font.packageName,
        },
      ));
    }
    return findings;
  }

  List<Finding> _emptyDirectories(ProjectContext ctx) {
    return ctx.emptyDirectories
        .map((AssetDeclaration declaration) => Finding(
              severity: Severity.warning,
              code: FindingCode.emptyAssetDirectory,
              message: '${declaration.packageName} declares '
                  '`${declaration.rawEntry}` but the directory holds no files.',
              path: declaration.directoryPath,
              occurrences: <Occurrence>[declaration.origin],
              data: <String, Object?>{'package': declaration.packageName},
            ))
        .toList(growable: false);
  }
}
