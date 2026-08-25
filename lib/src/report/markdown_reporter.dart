import '../models/finding.dart';
import '../runner.dart';
import '../util/paths.dart';
import 'reporter.dart';

/// Markdown for PR comments and job summaries
/// (`asset_guard --format markdown >> $GITHUB_STEP_SUMMARY`).
class MarkdownReporter implements Reporter {
  const MarkdownReporter();

  @override
  String render(AuditResult result) {
    final summary = AuditSummary.from(result);
    final buffer = StringBuffer()
      ..writeln('# Flutter Asset Guard')
      ..writeln()
      ..writeln('${summary.assetCount} assets across ${summary.packageCount} '
          'package${summary.packageCount == 1 ? '' : 's'}.')
      ..writeln()
      ..writeln('| Metric | Value |')
      ..writeln('| --- | --- |')
      ..writeln('| **Asset health** | '
          '**${summary.health.roundedScore}%** (grade ${summary.health.grade}) '
          '`${summary.health.bar()}` |')
      ..writeln('| Clean assets | '
          '${summary.health.cleanAssets} / ${summary.health.totalAssets} |')
      ..writeln('| Unused | ${summary.unusedCount} |')
      ..writeln('| Reclaimable | ${humanBytes(summary.reclaimableBytes)} |')
      ..writeln('| Duplicate groups | ${summary.duplicateGroups} |')
      ..writeln('| Similar groups | ${summary.similarGroups} |')
      ..writeln('| Possibly used (kept) | ${summary.possiblyUsedCount} |')
      ..writeln('| Errors | ${summary.errorCount} |')
      ..writeln('| Warnings | ${summary.warningCount} |')
      ..writeln();

    if (result.findings.isEmpty) {
      buffer.writeln('No problems found. ✅');
      return buffer.toString();
    }

    groupByCode(result.findings).forEach((String code, List<Finding> findings) {
      buffer
        ..writeln('## ${kSectionTitles[code] ?? code} (${findings.length})')
        ..writeln()
        ..writeln('| Severity | Path | Detail |')
        ..writeln('| --- | --- | --- |');

      for (final Finding finding in findings) {
        final location = finding.occurrences.isEmpty
            ? ''
            : ' <br> `${finding.occurrences.first.display}`';
        final related = finding.relatedPaths.isEmpty
            ? ''
            : ' <br> ${finding.relatedPaths.take(5).map((String r) => '`$r`').join(' ')}'
                '${finding.relatedPaths.length > 5 ? ' …' : ''}';
        buffer.writeln('| ${finding.severity.label} '
            '| `${finding.path ?? '—'}` '
            '| ${_escape(finding.message)}$location$related |');
      }
      buffer.writeln();
    });

    return buffer.toString();
  }

  /// Pipes would break the table; backticks in messages are intentional.
  String _escape(String value) =>
      value.replaceAll('|', r'\|').replaceAll('\n', ' ');
}
