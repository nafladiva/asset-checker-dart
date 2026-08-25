import 'dart:convert';
import 'dart:io';

import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() {
    project = FixtureProject.create();
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/used.png')
      ..png('assets/images/orphan.png')
      ..file('lib/main.dart', '''
void main() {
  Image.asset('assets/images/used.png');
}
''');
  });

  tearDown(() => project.dispose());

  Future<({int code, String out, String err})> run(List<String> args) async {
    final out = CapturedOutput();
    final err = CapturedOutput();
    final code = await runCli(
      <String>['--path', project.root, '--no-color', ...args],
      out: out.sink,
      err: err.sink,
    );
    return (code: code, out: await out.text(), err: await err.text());
  }

  test('--help and --version exit cleanly', () async {
    final help = await run(<String>['--help']);
    expect(help.code, ExitCodes.success);
    expect(help.out, contains('--delete-unused'));

    final version = await run(<String>['--version']);
    expect(version.code, ExitCodes.success);
    expect(version.out.trim(), 'asset_guard $packageVersion');
  });

  test('an unknown flag is a usage error, not a crash', () async {
    final result = await run(<String>['--nonsense']);

    expect(result.code, ExitCodes.usageError);
    expect(result.err, contains('Could not find an option named'));
  });

  test('a missing project directory is a usage error', () async {
    final out = CapturedOutput();
    final err = CapturedOutput();
    final code = await runCli(
      <String>['--path', '${project.root}/does_not_exist'],
      out: out.sink,
      err: err.sink,
    );
    await out.text();

    expect(code, ExitCodes.usageError);
    expect(await err.text(), contains('No such directory'));
  });

  test('pretty output groups findings and prints the summary footer', () async {
    final result = await run(<String>['--check', 'unused']);

    expect(result.out, contains('Unused assets'));
    expect(result.out, contains('assets/images/orphan.png'));
    expect(result.out, isNot(contains('assets/images/used.png')));
    expect(result.out, contains('1 unused ('));
    expect(result.out, contains('duplicate groups'));
    expect(result.out, isNot(contains('\x1B[')),
        reason: '--no-color was passed');
  });

  test('json output matches the documented schema', () async {
    final result = await run(<String>['--format', 'json', '--check', 'unused']);
    final decoded = jsonDecode(result.out) as Map<String, Object?>;

    expect(decoded['schemaVersion'], JsonReporter.schemaVersion);
    expect(decoded['packages'], <String>['my_app']);
    expect(decoded['summary'], isA<Map<String, Object?>>());

    final findings =
        (decoded['findings']! as List<Object?>).cast<Map<String, Object?>>();
    final unused = findings.firstWhere(
        (Map<String, Object?> f) => f['code'] == FindingCode.unusedAsset);

    expect(
        unused.keys,
        containsAll(<String>[
          'severity',
          'code',
          'message',
          'path',
          'occurrences',
          'relatedPaths'
        ]));
    expect(unused['severity'], 'warning');
    expect(unused['path'], 'assets/images/orphan.png');
    expect(unused['occurrences'], isA<List<Object?>>());
    expect(unused['relatedPaths'], isA<List<Object?>>());
  });

  test('markdown output renders a summary table', () async {
    final result = await run(<String>['--format', 'markdown']);

    expect(result.out, contains('# Flutter Asset Guard'));
    expect(result.out, contains('| Unused | 1 |'));
    expect(result.out, contains('## Unused assets'));
  });

  test('--output writes the report to a file instead of stdout', () async {
    final result = await run(<String>['--format', 'json', '-o', 'report.json']);

    expect(result.out, isEmpty);
    expect(result.err, contains('Report written to'));

    final written = File(project.absolute('report.json')).readAsStringSync();
    expect(jsonDecode(written), isA<Map<String, Object?>>());
  });

  test('exit code reflects --fail-on', () async {
    // An unused asset is a warning, so the default (error) passes.
    expect((await run(<String>['--check', 'unused'])).code, ExitCodes.success);
    expect(
      (await run(<String>['--check', 'unused', '--fail-on', 'warning'])).code,
      ExitCodes.findings,
    );
    expect(
      (await run(<String>['--check', 'unused', '--fail-on', 'none'])).code,
      ExitCodes.success,
    );
  });

  test('an error-severity finding fails the default CI gate', () async {
    project.file(
        'pubspec.yaml',
        flutterPubspec(name: 'my_app', assets: <String>[
          'assets/images/',
          'assets/images/absent.png',
        ]));

    final result = await run(<String>['--check', 'missing']);

    expect(result.code, ExitCodes.findings);
    expect(result.out, contains('Declared but missing from disk'));
    expect(result.out, contains('absent.png'));
  });

  test('--check limits which checks run', () async {
    final result = await run(<String>['--format', 'json', '--check', 'dupes']);
    final decoded = jsonDecode(result.out) as Map<String, Object?>;
    final codes = (decoded['findings']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((Map<String, Object?> f) => f['code'])
        .toSet();

    expect(codes, isNot(contains(FindingCode.unusedAsset)));
  });

  test('--ignore adds to configured globs', () async {
    final result = await run(<String>[
      '--format',
      'json',
      '--check',
      'unused',
      '--ignore',
      'assets/images/orphan.png'
    ]);
    final decoded = jsonDecode(result.out) as Map<String, Object?>;

    expect(decoded['findings'], isEmpty);
  });

  test('CLI flags win over asset_guard.yaml', () async {
    project.file('asset_guard.yaml', 'fail_on: warning\n');

    expect((await run(<String>['--check', 'unused'])).code, ExitCodes.findings,
        reason: 'config file alone should fail on warnings');
    expect(
      (await run(<String>['--check', 'unused', '--fail-on', 'none'])).code,
      ExitCodes.success,
      reason: 'the flag must override the file',
    );
  });
}
