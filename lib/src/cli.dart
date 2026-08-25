import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'checks/check.dart';
import 'config.dart';
import 'deleter.dart';
import 'logger.dart';
import 'models/finding.dart';
import 'report/json_reporter.dart';
import 'report/markdown_reporter.dart';
import 'report/pretty_reporter.dart';
import 'report/reporter.dart';
import 'runner.dart';
import 'version.dart';

/// Process exit codes. `2` is reserved for the user's mistake so CI can tell a
/// misconfigured job from a genuinely failing audit.
abstract final class ExitCodes {
  static const int success = 0;
  static const int findings = 1;
  static const int usageError = 2;
}

ArgParser buildParser() {
  return ArgParser()
    ..addOption('path',
        abbr: 'p', help: 'Project root to audit.', valueHelp: 'dir')
    ..addMultiOption('check',
        help: 'Which checks to run. Repeatable.',
        allowed: CheckId.values,
        defaultsTo: <String>[CheckId.all],
        valueHelp: 'name')
    ..addOption('format',
        abbr: 'f',
        help: 'Output format.',
        allowed: <String>['pretty', 'json', 'markdown'],
        defaultsTo: 'pretty')
    ..addOption('output',
        abbr: 'o', help: 'Write the report to a file.', valueHelp: 'file')
    ..addOption('similarity-threshold',
        help: 'Max Hamming distance for near-duplicate images (0-64).',
        valueHelp: 'int')
    ..addOption('max-file-size-kb',
        help: 'Size above which a file gets a hygiene warning.',
        valueHelp: 'int')
    ..addOption('max-hash-size-mb',
        help: 'Skip perceptual hashing for files larger than this.',
        valueHelp: 'int')
    ..addOption('fail-on',
        help: 'Lowest severity that exits non-zero.',
        allowed: <String>['none', 'warning', 'error'],
        defaultsTo: 'error')
    ..addOption('min-health',
        help: 'Exit non-zero if the health score falls below this (0-100).',
        valueHelp: 'percent')
    ..addMultiOption('ignore',
        help: 'Glob of paths to skip. Repeatable.', valueHelp: 'glob')
    ..addFlag('delete-unused',
        negatable: false, help: 'Delete assets nothing references.')
    ..addFlag('dry-run',
        defaultsTo: true,
        help: 'With --delete-unused, only list what would go. '
            'Use --no-dry-run to actually delete.')
    ..addFlag('yes',
        abbr: 'y', negatable: false, help: 'Skip the confirmation prompt.')
    ..addFlag('color', defaultsTo: true, help: 'Colourise pretty output.')
    ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Log progress.')
    ..addFlag('version', negatable: false, help: 'Print the version and exit.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');
}

/// Runs one invocation and returns the process exit code.
///
/// Everything is injectable so the CLI itself is testable without spawning a
/// subprocess.
Future<int> runCli(
  List<String> args, {
  IOSink? out,
  IOSink? err,
  String? Function()? readLine,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = buildParser();

  final ArgResults results;
  try {
    results = parser.parse(args);
  } on FormatException catch (e) {
    stderrSink.writeln(e.message);
    stderrSink.writeln();
    stderrSink.writeln(_usage(parser));
    return ExitCodes.usageError;
  }

  if (results.flag('help')) {
    stdoutSink.writeln(_usage(parser));
    return ExitCodes.success;
  }
  if (results.flag('version')) {
    stdoutSink.writeln('asset_guard $packageVersion');
    return ExitCodes.success;
  }

  try {
    final config = _resolveConfig(results);
    final logger = Logger(verbose: config.verbose, sink: stderrSink);

    if (config.deleteUnused && !config.runsCheck(CheckId.unused)) {
      stderrSink.writeln(
          '--delete-unused needs the unused check; add --check unused.');
      return ExitCodes.usageError;
    }

    final result = await AssetGuardRunner(logger: logger).run(config);
    final report = _reporterFor(config).render(result);

    final output = config.output;
    if (output == null) {
      stdoutSink.write(report);
    } else {
      final file = File(
          p.isAbsolute(output) ? output : p.join(config.projectRoot, output));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(report);
      stderrSink.writeln('Report written to ${file.path}');
    }

    if (config.deleteUnused) {
      final interactive =
          config.format == OutputFormat.pretty && output == null;
      final outcome = await UnusedDeleter(
        config: config,
        out: interactive ? stdoutSink : stderrSink,
        readLine: readLine,
      ).run(result);

      if (!outcome.aborted && !outcome.dryRun) {
        final sink = interactive ? stdoutSink : stderrSink;
        sink.writeln();
        sink.writeln('Deleted ${outcome.deleted.length} file(s).');
        for (final String entry in outcome.pubspecEntriesRemoved) {
          sink.writeln('Removed pubspec entry — $entry');
        }
      }
    }

    // The health gate is independent of --fail-on: a team may tolerate
    // individual warnings while still refusing to let the tree get worse.
    final int? minHealth = config.minHealth;
    final health = AuditSummary.from(result).health;
    final belowThreshold = minHealth != null && health.roundedScore < minHealth;
    if (belowThreshold) {
      stderrSink.writeln('Asset health ${health.roundedScore}% is below the '
          'required $minHealth%.');
    }

    return result.shouldFail(config.failOn) || belowThreshold
        ? ExitCodes.findings
        : ExitCodes.success;
  } on ConfigException catch (e) {
    stderrSink.writeln(e.message);
    return ExitCodes.usageError;
  }
}

AssetGuardConfig _resolveConfig(ArgResults results) {
  final rawPath = results.option('path') ?? Directory.current.path;
  final root = p.normalize(p.absolute(rawPath));
  if (!Directory(root).existsSync()) {
    throw ConfigException('No such directory: $root');
  }

  // File first, then CLI flags on top — but only flags the user actually
  // typed, so defaults never clobber configured values.
  var config = loadConfigFile(root);

  Severity? failOn = config.failOn;
  var clearFailOn = false;
  if (results.wasParsed('fail-on')) {
    final value = results.option('fail-on')!;
    if (value == 'none') {
      clearFailOn = true;
      failOn = null;
    } else {
      failOn = Severity.tryParse(value);
    }
  }

  config = config.copyWith(
    ignore: results.wasParsed('ignore')
        ? <String>[...config.ignore, ...results.multiOption('ignore')]
        : null,
    similarityThreshold:
        _intOption(results, 'similarity-threshold', min: 0, max: 64),
    maxFileSizeKb: _intOption(results, 'max-file-size-kb', min: 0),
    maxHashSizeBytes: () {
      final mb = _intOption(results, 'max-hash-size-mb', min: 0);
      return mb == null ? null : mb * 1024 * 1024;
    }(),
    failOn: failOn,
    clearFailOn: clearFailOn,
    minHealth: _intOption(results, 'min-health', min: 0, max: 100),
    checks: results.multiOption('check').toSet(),
    format: OutputFormat.tryParse(results.option('format')!),
    output: results.option('output'),
    verbose: results.flag('verbose'),
    deleteUnused: results.flag('delete-unused'),
    dryRun: results.flag('dry-run'),
    assumeYes: results.flag('yes'),
    color: results.flag('color') && _supportsColor(),
  );

  return config;
}

int? _intOption(ArgResults results, String name, {int? min, int? max}) {
  if (!results.wasParsed(name)) return null;
  final raw = results.option(name)!;
  final value = int.tryParse(raw);
  if (value == null) {
    throw ConfigException('--$name expects an integer (got "$raw").');
  }
  if (min != null && value < min) {
    throw ConfigException('--$name must be at least $min (got $value).');
  }
  if (max != null && value > max) {
    throw ConfigException('--$name must be at most $max (got $value).');
  }
  return value;
}

bool _supportsColor() {
  if (Platform.environment.containsKey('NO_COLOR')) return false;
  try {
    return stdout.hasTerminal;
  } on Object {
    return false;
  }
}

Reporter _reporterFor(AssetGuardConfig config) {
  switch (config.format) {
    case OutputFormat.pretty:
      return PrettyReporter(color: config.color);
    case OutputFormat.json:
      return const JsonReporter();
    case OutputFormat.markdown:
      return const MarkdownReporter();
  }
}

String _usage(ArgParser parser) => '''
asset_guard — audit Flutter assets for unused, missing and duplicate files.

Usage: dart run asset_guard [options]

${parser.usage}

Configuration may also live in `asset_guard.yaml` at the project root.
CLI flags win over the file.

Exit codes: 0 clean, 1 findings at or above --fail-on, 2 bad usage.''';
