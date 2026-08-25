import 'dart:io';

import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

bool get gitAvailable {
  try {
    return Process.runSync('git', <String>['--version']).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

void commitEverything(FixtureProject project) {
  Process.runSync('git', <String>['init', '-q'],
      workingDirectory: project.root);
  Process.runSync('git', <String>['add', '-A'], workingDirectory: project.root);
  Process.runSync(
    'git',
    <String>[
      '-c',
      'user.email=test@example.com',
      '-c',
      'user.name=Test',
      'commit',
      '-q',
      '-m',
      'fixture',
    ],
    workingDirectory: project.root,
  );
}

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

  AssetGuardConfig configFor({bool dryRun = true, bool assumeYes = true}) =>
      AssetGuardConfig(
        projectRoot: project.root,
        color: false,
        deleteUnused: true,
        dryRun: dryRun,
        assumeYes: assumeYes,
      );

  Future<DeleteOutcome> delete(
    AssetGuardConfig config, {
    String? Function()? readLine,
  }) async {
    final result = await AssetGuardRunner().run(config);
    final out = CapturedOutput();
    final outcome = await UnusedDeleter(
      config: config,
      out: out.sink,
      readLine: readLine ?? () => 'yes',
    ).run(result);
    await out.text();
    return outcome;
  }

  test('dry run is the default and deletes nothing', () async {
    final outcome = await delete(configFor());

    expect(outcome.dryRun, isTrue);
    expect(outcome.deleted, <String>['assets/images/orphan.png']);
    expect(
        File(project.absolute('assets/images/orphan.png')).existsSync(), isTrue,
        reason: 'a dry run must leave the file in place');
  });

  test('refuses to delete outside a git working tree', () async {
    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.aborted, isTrue);
    expect(outcome.abortReason, contains('git working tree'));
    expect(File(project.absolute('assets/images/orphan.png')).existsSync(),
        isTrue);
  });

  test('refuses when the working tree is dirty', () async {
    commitEverything(project);
    project.file('lib/extra.dart', '// uncommitted');

    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.aborted, isTrue);
    expect(outcome.abortReason, contains('uncommitted changes'));
    expect(File(project.absolute('assets/images/orphan.png')).existsSync(),
        isTrue);
  }, skip: gitAvailable ? null : 'git is not installed');

  test('deletes only the unused file from a clean tree', () async {
    commitEverything(project);

    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.aborted, isFalse);
    expect(outcome.deleted, <String>['assets/images/orphan.png']);
    expect(File(project.absolute('assets/images/orphan.png')).existsSync(),
        isFalse);
    expect(
        File(project.absolute('assets/images/used.png')).existsSync(), isTrue);
  }, skip: gitAvailable ? null : 'git is not installed');

  test('a "no" at the prompt cancels', () async {
    commitEverything(project);

    final outcome = await delete(
      configFor(dryRun: false, assumeYes: false),
      readLine: () => 'n',
    );

    expect(outcome.aborted, isTrue);
    expect(outcome.abortReason, contains('Cancelled'));
    expect(File(project.absolute('assets/images/orphan.png')).existsSync(),
        isTrue);
  }, skip: gitAvailable ? null : 'git is not installed');

  test('never deletes an asset reachable through a dynamic path', () async {
    project
      ..removeDirectory('assets/images')
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/flags/']))
      ..png('assets/flags/us.png')
      ..png('assets/flags/gb.png')
      ..file('lib/main.dart', r'''
Widget flag(String code) => Image.asset('assets/flags/$code.png');
''');
    commitEverything(project);

    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.deleted, isEmpty);
    expect(File(project.absolute('assets/flags/us.png')).existsSync(), isTrue);
    expect(File(project.absolute('assets/flags/gb.png')).existsSync(), isTrue);
  }, skip: gitAvailable ? null : 'git is not installed');

  test('deletes variants alongside their unused parent', () async {
    project
      ..png('assets/images/2.0x/orphan.png', width: 128, height: 128)
      ..png('assets/images/2.0x/used.png', width: 128, height: 128);
    commitEverything(project);

    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.deleted, <String>[
      'assets/images/2.0x/orphan.png',
      'assets/images/orphan.png',
    ]);
    expect(File(project.absolute('assets/images/2.0x/used.png')).existsSync(),
        isTrue);
  }, skip: gitAvailable ? null : 'git is not installed');

  test('strips the pubspec entry when a directory empties out', () async {
    project
      ..file(
          'pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>[
            'assets/images/',
            'assets/legacy/',
          ]))
      ..png('assets/legacy/dead.png');
    commitEverything(project);

    final outcome = await delete(configFor(dryRun: false));

    expect(outcome.deleted, contains('assets/legacy/dead.png'));
    expect(outcome.directoriesRemoved, contains('assets/legacy'));
    expect(outcome.pubspecEntriesRemoved, hasLength(1));

    final pubspec = File(project.absolute('pubspec.yaml')).readAsStringSync();
    expect(pubspec, isNot(contains('assets/legacy/')));
    expect(pubspec, contains('assets/images/'),
        reason: 'the still-populated entry must survive');
  }, skip: gitAvailable ? null : 'git is not installed');
}
