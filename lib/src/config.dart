import 'dart:io';

import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'models/finding.dart';

enum OutputFormat {
  pretty,
  json,
  markdown;

  static OutputFormat? tryParse(String value) {
    for (final OutputFormat format in OutputFormat.values) {
      if (format.name == value.trim().toLowerCase()) return format;
    }
    return null;
  }
}

/// Directories that are never assets and are expensive to walk.
const Set<String> kAlwaysSkippedDirectories = <String>{
  '.git',
  '.dart_tool',
  '.idea',
  '.vscode',
  'build',
  '.symlinks',
  'Pods',
  'DerivedData',
  'node_modules',
  '.fvm',
  '.melos_tool',
};

/// Resolved settings for one run. CLI flags win over `asset_guard.yaml`, which
/// wins over these defaults.
class AssetGuardConfig {
  AssetGuardConfig({
    required this.projectRoot,
    this.ignore = const <String>[],
    this.similarityThreshold = 5,
    this.maxFileSizeKb = 500,
    this.maxHashSizeBytes = 10 * 1024 * 1024,
    this.failOn = Severity.error,
    this.treatDynamicAsUsed = true,
    this.treatUnresolvableAsWildcard = false,
    this.checks = const <String>{'all'},
    this.format = OutputFormat.pretty,
    this.output,
    this.verbose = false,
    this.deleteUnused = false,
    this.dryRun = true,
    this.assumeYes = false,
    this.color = true,
  }) : _ignoreGlobs = _compileGlobs(ignore);

  /// Compiles ignore patterns up front so a typo surfaces as a readable
  /// message at startup rather than a scanner stack trace mid-audit.
  static List<Glob> _compileGlobs(List<String> patterns) {
    final compiled = <Glob>[];
    for (final String pattern in patterns) {
      try {
        compiled.add(Glob(pattern, context: p.posix));
      } on FormatException catch (e) {
        throw ConfigException(
            'Invalid ignore glob "$pattern": ${e.message}');
      }
    }
    return List<Glob>.unmodifiable(compiled);
  }

  /// Absolute, normalized path to the project root.
  final String projectRoot;

  final List<String> ignore;
  final int similarityThreshold;
  final int maxFileSizeKb;
  final int maxHashSizeBytes;

  /// `null` means `--fail-on none`: always exit 0.
  final Severity? failOn;

  /// When true, a dynamic reference marks matching assets possibly-used rather
  /// than leaving them to be reported as unused.
  final bool treatDynamicAsUsed;

  /// When true, a bundle load with a completely unresolvable argument marks
  /// *every* asset possibly-used. Off by default: it silences the whole unused
  /// check, which is rarely what people want. Such calls always block deletion
  /// regardless of this setting.
  final bool treatUnresolvableAsWildcard;

  final Set<String> checks;
  final OutputFormat format;
  final String? output;
  final bool verbose;
  final bool deleteUnused;
  final bool dryRun;
  final bool assumeYes;
  final bool color;

  final List<Glob> _ignoreGlobs;

  int get maxFileSizeBytes => maxFileSizeKb * 1024;

  bool runsCheck(String id) => checks.contains('all') || checks.contains(id);

  /// [projectRelativePath] must be POSIX-style and relative to [projectRoot].
  bool isIgnored(String projectRelativePath) {
    for (final Glob glob in _ignoreGlobs) {
      if (glob.matches(projectRelativePath)) return true;
    }
    return false;
  }

  AssetGuardConfig copyWith({
    List<String>? ignore,
    int? similarityThreshold,
    int? maxFileSizeKb,
    int? maxHashSizeBytes,
    Severity? failOn,
    bool clearFailOn = false,
    bool? treatDynamicAsUsed,
    bool? treatUnresolvableAsWildcard,
    Set<String>? checks,
    OutputFormat? format,
    String? output,
    bool? verbose,
    bool? deleteUnused,
    bool? dryRun,
    bool? assumeYes,
    bool? color,
  }) {
    return AssetGuardConfig(
      projectRoot: projectRoot,
      ignore: ignore ?? this.ignore,
      similarityThreshold: similarityThreshold ?? this.similarityThreshold,
      maxFileSizeKb: maxFileSizeKb ?? this.maxFileSizeKb,
      maxHashSizeBytes: maxHashSizeBytes ?? this.maxHashSizeBytes,
      failOn: clearFailOn ? null : (failOn ?? this.failOn),
      treatDynamicAsUsed: treatDynamicAsUsed ?? this.treatDynamicAsUsed,
      treatUnresolvableAsWildcard:
          treatUnresolvableAsWildcard ?? this.treatUnresolvableAsWildcard,
      checks: checks ?? this.checks,
      format: format ?? this.format,
      output: output ?? this.output,
      verbose: verbose ?? this.verbose,
      deleteUnused: deleteUnused ?? this.deleteUnused,
      dryRun: dryRun ?? this.dryRun,
      assumeYes: assumeYes ?? this.assumeYes,
      color: color ?? this.color,
    );
  }
}

/// Raised for malformed user input so the CLI can print a clean message
/// instead of a stack trace.
class ConfigException implements Exception {
  ConfigException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads `asset_guard.yaml` from [projectRoot] and applies it over defaults.
/// Missing file means "defaults"; malformed file is an error worth surfacing.
AssetGuardConfig loadConfigFile(String projectRoot) {
  final base = AssetGuardConfig(projectRoot: projectRoot);
  final file = File(p.join(projectRoot, 'asset_guard.yaml'));
  if (!file.existsSync()) return base;

  final Object? parsed;
  try {
    parsed = loadYaml(file.readAsStringSync());
  } on FormatException catch (e) {
    // YamlException is a FormatException subtype; catching the base covers
    // scanner errors the yaml package raises outside its own exception type.
    throw ConfigException('asset_guard.yaml is not valid YAML: ${e.message}');
  }
  if (parsed == null) return base;
  if (parsed is! YamlMap) {
    throw ConfigException(
        'asset_guard.yaml must contain a YAML map at the top level.');
  }

  Severity? failOn = base.failOn;
  final Object? rawFailOn = parsed['fail_on'];
  if (rawFailOn != null) {
    final text = rawFailOn.toString();
    if (text.trim().toLowerCase() == 'none') {
      failOn = null;
    } else {
      failOn = Severity.tryParse(text) ??
          (throw ConfigException(
              'asset_guard.yaml: fail_on must be one of none, warning, error (got "$text").'));
    }
  }

  return base.copyWith(
    ignore: _stringList(parsed['ignore'], 'ignore'),
    similarityThreshold:
        _int(parsed['similarity_threshold'], 'similarity_threshold'),
    maxFileSizeKb: _int(parsed['max_file_size_kb'], 'max_file_size_kb'),
    maxHashSizeBytes: _mbToBytes(parsed['max_hash_size_mb']),
    failOn: failOn,
    clearFailOn: rawFailOn != null &&
        rawFailOn.toString().trim().toLowerCase() == 'none',
    treatDynamicAsUsed:
        _bool(parsed['treat_dynamic_as_used'], 'treat_dynamic_as_used'),
    treatUnresolvableAsWildcard: _bool(parsed['treat_unresolvable_as_wildcard'],
        'treat_unresolvable_as_wildcard'),
  );
}

List<String>? _stringList(Object? value, String key) {
  if (value == null) return null;
  if (value is! YamlList) {
    throw ConfigException('asset_guard.yaml: $key must be a list.');
  }
  return value.map((Object? e) => e.toString()).toList(growable: false);
}

int? _int(Object? value, String key) {
  if (value == null) return null;
  if (value is int) return value;
  final parsed = int.tryParse(value.toString());
  if (parsed == null) {
    throw ConfigException(
        'asset_guard.yaml: $key must be an integer (got "$value").');
  }
  return parsed;
}

int? _mbToBytes(Object? value) {
  final mb = _int(value, 'max_hash_size_mb');
  return mb == null ? null : mb * 1024 * 1024;
}

bool? _bool(Object? value, String key) {
  if (value == null) return null;
  if (value is bool) return value;
  throw ConfigException(
      'asset_guard.yaml: $key must be true or false (got "$value").');
}
