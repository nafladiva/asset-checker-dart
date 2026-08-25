import 'dart:convert';

import '../models/asset.dart';
import '../models/finding.dart';
import '../runner.dart';
import 'reporter.dart';

/// Machine-readable output for CI annotations.
///
/// The top-level shape and every key under `findings[]` are a stable contract:
/// `{severity, code, message, path, occurrences[], relatedPaths[]}`. New keys
/// may be added; existing ones will not change meaning.
class JsonReporter implements Reporter {
  const JsonReporter({this.pretty = true});

  final bool pretty;

  /// Bumped only when the schema changes incompatibly.
  static const int schemaVersion = 1;

  @override
  String render(AuditResult result) {
    final payload = <String, Object?>{
      'schemaVersion': schemaVersion,
      'root': result.context.root,
      'packages': result.context.packages
          .map((PackageContext pkg) => pkg.name)
          .toList(growable: false),
      'summary': AuditSummary.from(result).toJson(),
      'findings': result.findings
          .map((Finding f) => f.toJson())
          .toList(growable: false),
    };

    return pretty
        ? '${const JsonEncoder.withIndent('  ').convert(payload)}\n'
        : '${jsonEncode(payload)}\n';
  }
}
