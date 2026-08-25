import 'asset_scanner.dart';
import 'checks/check.dart';
import 'checks/duplicate_check.dart';
import 'checks/hygiene_check.dart';
import 'checks/missing_check.dart';
import 'checks/similar_check.dart';
import 'checks/unused_check.dart';
import 'code_scanner.dart';
import 'config.dart';
import 'hashing/content_cache.dart';
import 'logger.dart';
import 'models/asset.dart';
import 'models/finding.dart';
import 'models/project_context.dart';
import 'models/reference.dart';
import 'pubspec_parser.dart';
import 'reference_resolver.dart';

/// A completed audit: the context it ran against and everything it found.
class AuditResult {
  const AuditResult({required this.context, required this.findings});

  final ProjectContext context;
  final List<Finding> findings;

  int get errorCount =>
      findings.where((Finding f) => f.severity == Severity.error).length;
  int get warningCount =>
      findings.where((Finding f) => f.severity == Severity.warning).length;
  int get infoCount =>
      findings.where((Finding f) => f.severity == Severity.info).length;

  /// Whether [failOn] should turn this run into a non-zero exit.
  bool shouldFail(Severity? failOn) {
    if (failOn == null) return false;
    return findings.any((Finding f) => f.severity.index >= failOn.index);
  }
}

/// Registry of available checks. Adding a check means adding it here — the
/// runner itself never changes.
const List<Check> kAllChecks = <Check>[
  UnusedCheck(),
  MissingCheck(),
  DuplicateCheck(),
  SimilarCheck(),
  HygieneCheck(),
];

/// Orchestrates the pipeline: parse pubspecs, walk disk, walk source, resolve
/// references, then run each enabled check against the assembled context.
class AssetGuardRunner {
  AssetGuardRunner({
    this.checks = kAllChecks,
    Logger? logger,
  }) : logger = logger ?? Logger(verbose: false);

  final List<Check> checks;
  final Logger logger;

  Future<AuditResult> run(AssetGuardConfig config) async {
    final stopwatch = Stopwatch()..start();

    logger.trace('Discovering packages under ${config.projectRoot}');
    final packages = const PubspecParser().discoverPackages(config.projectRoot);
    if (packages.isEmpty) {
      throw ConfigException(
          'No pubspec.yaml found under ${config.projectRoot}. '
          'Point --path at a Flutter project or workspace root.');
    }
    logger.trace('Found ${packages.length} package(s): '
        '${packages.map((PackageContext p) => p.name).join(', ')}');

    final scanned =
        const AssetScanner().scan(config.projectRoot, packages, config);
    logger.trace('Found ${scanned.assets.length} asset file(s), '
        '${scanned.declarations.length} declaration(s)');

    final code = const CodeScanner().scan(config.projectRoot, packages, config);
    logger.trace('Parsed ${code.filesScanned} Dart file(s), '
        '${code.candidates.length} string expression(s)');

    final native = const NativeScanner()
        .scan(config.projectRoot, packages, scanned.assets, config);
    logger.trace('Matched ${native.length} reference(s) in platform folders');

    final resolution = ReferenceResolver(
      config: config,
      packages: packages,
      assets: scanned.assets,
      scan: code,
      nativeReferences: native,
    ).resolve();

    final unusedCount = resolution.usage.values
        .where((UsageStatus s) => s == UsageStatus.unused)
        .length;
    logger.trace('Resolved ${resolution.references.length} reference(s); '
        '$unusedCount asset(s) unreferenced');

    final context = ProjectContext(
      config: config,
      packages: packages,
      assets: scanned.assets,
      references: resolution.references,
      dynamicReferences: resolution.dynamicReferences,
      unresolvableReferences: resolution.unresolvableReferences,
      fontFamilyMentions: code.literalStrings,
      usage: resolution.usage,
      occurrencesByAsset: resolution.occurrencesByAsset,
      missingDeclarations: scanned.missingDeclarations,
      emptyDirectories: scanned.emptyDirectories,
      declarations: scanned.declarations,
      unmatchedReferences: resolution.unmatchedReferences,
      content: ContentCache(maxHashSizeBytes: config.maxHashSizeBytes),
    );

    final findings = <Finding>[];
    for (final Check check in checks) {
      if (!config.runsCheck(check.id)) continue;
      final checkWatch = Stopwatch()..start();
      findings.addAll(await check.run(context));
      logger.trace('${check.name}: ${checkWatch.elapsedMilliseconds}ms');
    }

    if (context.content.skippedForSize.isNotEmpty) {
      logger.trace('Skipped perceptual hashing for '
          '${context.content.skippedForSize.length} oversized file(s)');
    }

    findings.sort(compareFindings);
    logger.trace('Audit finished in ${stopwatch.elapsedMilliseconds}ms');

    return AuditResult(context: context, findings: findings);
  }
}
