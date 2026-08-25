/// Audits a Flutter project's assets for unused, missing, duplicated and
/// near-duplicate files.
///
/// Most users want the `asset_guard` executable. This library is exported for
/// embedding the audit in a custom tool or writing project-specific checks
/// against the [Check] interface.
library;

export 'src/asset_scanner.dart';
export 'src/checks/check.dart';
export 'src/checks/duplicate_check.dart';
export 'src/checks/hygiene_check.dart';
export 'src/checks/missing_check.dart';
export 'src/checks/similar_check.dart';
export 'src/checks/unused_check.dart';
export 'src/cli.dart' show ExitCodes, buildParser, runCli;
export 'src/code_scanner.dart';
export 'src/config.dart';
export 'src/deleter.dart';
export 'src/hashing/content_cache.dart';
export 'src/hashing/exact_hash.dart';
export 'src/hashing/perceptual_hash.dart';
export 'src/hashing/svg_normalizer.dart';
export 'src/logger.dart';
export 'src/models/asset.dart';
export 'src/models/const_expr.dart';
export 'src/models/finding.dart';
export 'src/models/project_context.dart';
export 'src/models/reference.dart';
export 'src/pubspec_parser.dart';
export 'src/reference_resolver.dart';
export 'src/report/json_reporter.dart';
export 'src/report/markdown_reporter.dart';
export 'src/report/pretty_reporter.dart';
export 'src/report/reporter.dart';
export 'src/runner.dart';
export 'src/util/paths.dart';
export 'src/version.dart';
