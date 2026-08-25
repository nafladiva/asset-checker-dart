import 'package:path/path.dart' as p;

import '../models/finding.dart';
import '../runner.dart';
import '../util/paths.dart';
import 'reporter.dart';

/// Terminal output: grouped sections, colour by severity, relative paths.
class PrettyReporter implements Reporter {
  const PrettyReporter({this.color = true});

  /// Disabled for pipes, `--no-color`, and CI logs that mangle escapes.
  final bool color;

  static const String _reset = '[0m';
  static const String _bold = '[1m';
  static const String _dim = '[2m';
  static const String _red = '[31m';
  static const String _yellow = '[33m';
  static const String _blue = '[34m';
  static const String _cyan = '[36m';
  static const String _green = '[32m';

  /// Indent for lines continuing a finding: two spaces, the seven-column
  /// severity label, then two more. Must stay in step with [_severityLabel].
  static const String _continuation = '           ';

  @override
  String render(AuditResult result) {
    final summary = AuditSummary.from(result);
    final buffer = StringBuffer();

    buffer.writeln(_paint('Flutter Asset Guard', _bold));
    buffer.writeln(_paint(
      '${p.basename(result.context.root)}  ·  '
      '${summary.packageCount} package${summary.packageCount == 1 ? '' : 's'}  ·  '
      '${summary.assetCount} asset${summary.assetCount == 1 ? '' : 's'}',
      _dim,
    ));
    buffer.writeln();

    if (result.findings.isEmpty) {
      buffer.writeln(_paint('No problems found.', _green));
      return buffer.toString();
    }

    groupByCode(result.findings).forEach((String code, List<Finding> findings) {
      buffer.write(_renderSection(code, findings));
    });

    buffer.writeln(_paint('Summary', _bold));
    buffer.writeln('  ${_summaryLine(summary)}');
    buffer.writeln('  ${_countsLine(summary)}');
    return buffer.toString();
  }

  String _renderSection(String code, List<Finding> findings) {
    final buffer = StringBuffer();
    final title = kSectionTitles[code] ?? code;

    final reclaimable =
        findings.fold<int>(0, (int sum, Finding f) => sum + f.reclaimableBytes);
    final suffix = reclaimable > 0
        ? '${findings.length} · ${humanBytes(reclaimable)} reclaimable'
        : '${findings.length}';

    buffer.writeln('${_paint(title, _bold)} ${_paint('($suffix)', _dim)}');

    for (final Finding finding in findings) {
      final label = _severityLabel(finding.severity);
      final subject = finding.path ?? '';
      buffer.writeln('  $label  ${_paint(subject, _cyan)}');
      buffer.writeln('$_continuation${finding.message}');

      for (final Occurrence occurrence in finding.occurrences.take(3)) {
        buffer.writeln(
            '$_continuation${_paint('at ${occurrence.display}', _dim)}');
      }

      for (final String related in finding.relatedPaths.take(5)) {
        buffer.writeln('$_continuation${_paint('+ $related', _dim)}');
      }
      if (finding.relatedPaths.length > 5) {
        buffer.writeln('$_continuation'
            '${_paint('+ ${finding.relatedPaths.length - 5} more', _dim)}');
      }
    }

    buffer.writeln();
    return buffer.toString();
  }

  String _summaryLine(AuditSummary summary) {
    return '${summary.unusedCount} unused '
        '(${humanBytes(summary.reclaimableBytes)} reclaimable), '
        '${summary.duplicateGroups} duplicate '
        '${summary.duplicateGroups == 1 ? 'group' : 'groups'}, '
        '${summary.similarGroups} similar '
        '${summary.similarGroups == 1 ? 'group' : 'groups'}';
  }

  String _countsLine(AuditSummary summary) {
    final parts = <String>[
      _paint('${summary.errorCount} error${summary.errorCount == 1 ? '' : 's'}',
          summary.errorCount > 0 ? _red : _dim),
      _paint(
          '${summary.warningCount} warning${summary.warningCount == 1 ? '' : 's'}',
          summary.warningCount > 0 ? _yellow : _dim),
      _paint('${summary.infoCount} info', _dim),
    ];
    if (summary.possiblyUsedCount > 0) {
      parts.add(_paint(
          '${summary.possiblyUsedCount} possibly used (never deleted)', _blue));
    }
    return parts.join(', ');
  }

  String _severityLabel(Severity severity) {
    switch (severity) {
      case Severity.error:
        return _paint('error  ', '$_bold$_red');
      case Severity.warning:
        return _paint('warning', _yellow);
      case Severity.info:
        return _paint('info   ', _dim);
    }
  }

  String _paint(String text, String code) => color ? '$code$text$_reset' : text;
}
