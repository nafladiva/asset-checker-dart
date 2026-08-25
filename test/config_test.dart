import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('defaults apply when no config file exists', () {
    final config = loadConfigFile(project.root);

    expect(config.similarityThreshold, 5);
    expect(config.maxFileSizeKb, 500);
    expect(config.maxHashSizeBytes, 10 * 1024 * 1024);
    expect(config.failOn, Severity.error);
    expect(config.treatDynamicAsUsed, isTrue);
    expect(config.treatUnresolvableAsWildcard, isFalse);
  });

  test('reads every documented key', () {
    project.file('asset_guard.yaml', '''
ignore:
  - assets/legacy/**
  - assets/**/*.json
similarity_threshold: 8
max_file_size_kb: 250
fail_on: warning
treat_dynamic_as_used: false
''');

    final config = loadConfigFile(project.root);

    expect(config.ignore, <String>['assets/legacy/**', 'assets/**/*.json']);
    expect(config.similarityThreshold, 8);
    expect(config.maxFileSizeKb, 250);
    expect(config.failOn, Severity.warning);
    expect(config.treatDynamicAsUsed, isFalse);
  });

  test('fail_on: none disables failure entirely', () {
    project.file('asset_guard.yaml', 'fail_on: none\n');

    expect(loadConfigFile(project.root).failOn, isNull);
  });

  test('malformed values raise a readable error', () {
    project.file('asset_guard.yaml', 'similarity_threshold: soon\n');

    expect(
      () => loadConfigFile(project.root),
      throwsA(isA<ConfigException>().having(
          (ConfigException e) => e.message, 'message', contains('integer'))),
    );
  });

  test('a non-map document is rejected', () {
    project.file('asset_guard.yaml', '- just\n- a list\n');

    expect(() => loadConfigFile(project.root), throwsA(isA<ConfigException>()));
  });

  test('an invalid ignore glob is a readable error, not a scanner crash', () {
    expect(
      () => AssetGuardConfig(
          projectRoot: project.root, ignore: <String>['[unclosed']),
      throwsA(isA<ConfigException>().having((ConfigException e) => e.message,
          'message', contains('Invalid ignore glob "[unclosed"'))),
    );
  });

  test('an invalid glob in the config file is reported the same way', () {
    project.file('asset_guard.yaml', 'ignore:\n  - "[unclosed"\n');

    expect(
      () => loadConfigFile(project.root),
      throwsA(isA<ConfigException>().having((ConfigException e) => e.message,
          'message', contains('Invalid ignore glob'))),
    );
  });

  test('YAML that fails to scan is reported as a config error', () {
    project.file('asset_guard.yaml', 'ignore:\n  - ok\n\tbad: tab\n');

    expect(
      () => loadConfigFile(project.root),
      throwsA(isA<ConfigException>().having((ConfigException e) => e.message,
          'message', contains('not valid YAML'))),
    );
  });

  test('ignore globs match POSIX-style project-relative paths', () {
    final config = AssetGuardConfig(
      projectRoot: project.root,
      ignore: <String>['assets/legacy/**', '**/*.json'],
    );

    expect(config.isIgnored('assets/legacy/old.png'), isTrue);
    expect(config.isIgnored('assets/legacy/deep/old.png'), isTrue);
    expect(config.isIgnored('assets/data/config.json'), isTrue);
    expect(config.isIgnored('assets/images/logo.png'), isFalse);
  });

  test('runsCheck honours "all" and explicit selections', () {
    final all = AssetGuardConfig(projectRoot: project.root);
    expect(all.runsCheck(CheckId.unused), isTrue);
    expect(all.runsCheck(CheckId.hygiene), isTrue);

    final some = all.copyWith(checks: <String>{CheckId.unused, CheckId.dupes});
    expect(some.runsCheck(CheckId.unused), isTrue);
    expect(some.runsCheck(CheckId.hygiene), isFalse);
  });
}
