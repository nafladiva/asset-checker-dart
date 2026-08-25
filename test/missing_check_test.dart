import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('a declared file that does not exist is an error', () async {
    project
      ..file(
          'pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>[
            'assets/images/present.png',
            'assets/images/absent.png',
          ]))
      ..png('assets/images/present.png')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);
    final missing = findingsWithCode(result, FindingCode.missingDeclaredAsset);

    expect(missing, hasLength(1));
    expect(missing.single.severity, Severity.error);
    expect(missing.single.path, 'assets/images/absent.png');
    expect(missing.single.occurrences.single.file, 'pubspec.yaml');
    expect(missing.single.occurrences.single.line, isNotNull);
  });

  test('code referencing an undeclared path is an error', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/logo.png')
      ..file('lib/main.dart', '''
void main() {
  Image.asset('assets/images/logo.png');
  Image.asset('assets/images/typo.png');
}
''');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);
    final undeclared =
        findingsWithCode(result, FindingCode.undeclaredReference);

    expect(undeclared, hasLength(1));
    expect(undeclared.single.severity, Severity.error);
    expect(undeclared.single.path, 'assets/images/typo.png');
    expect(undeclared.single.data['existsOnDisk'], isFalse);
  });

  test('a file on disk that no entry covers is a warning', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/declared.png')
      ..png('assets/extra/stray.png')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);
    final undeclared = findingsWithCode(result, FindingCode.undeclaredOnDisk);

    expect(undeclared, hasLength(1));
    expect(undeclared.single.severity, Severity.warning);
    expect(undeclared.single.path, 'assets/extra/stray.png');
  });

  test('a directory entry covers direct children but not nested ones',
      () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/top.png')
      ..png('assets/images/nested/deep.png')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);

    expect(pathsWithCode(result, FindingCode.undeclaredOnDisk),
        <String>['assets/images/nested/deep.png'],
        reason: 'Flutter directory entries are not recursive');
  });

  test('a 2.0x variant is covered by whatever covers its parent', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/logo.png')
      ..png('assets/images/2.0x/logo.png', width: 128, height: 128)
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);

    expect(findingsWithCode(result, FindingCode.undeclaredOnDisk), isEmpty);
  });

  test('font files are checked for existence like any other declaration',
      () async {
    project
      ..file('pubspec.yaml', '''
${flutterPubspec(name: 'my_app')}  fonts:
    - family: Roboto
      fonts:
        - asset: assets/fonts/roboto.ttf
''')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);
    final missing = findingsWithCode(result, FindingCode.missingDeclaredAsset);

    expect(missing, hasLength(1));
    expect(missing.single.path, 'assets/fonts/roboto.ttf');
  });

  test('a pure-Dart workspace reports no undeclared references', () async {
    // No `flutter:` section anywhere means there is no asset bundle, so
    // asset-shaped strings in source are just strings.
    project
      ..file('pubspec.yaml',
          'name: cli_tool\nenvironment:\n  sdk: ">=3.4.0 <4.0.0"\n')
      ..file('lib/main.dart', '''
const examplePathForDocs = 'assets/images/logo.png';
void main() => print(examplePathForDocs);
''');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);

    expect(findingsWithCode(result, FindingCode.undeclaredReference), isEmpty);
  });

  test('glob patterns are never treated as asset paths', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/logo.png')
      ..file('lib/main.dart', '''
const ignorePatterns = <String>[
  'assets/legacy/**',
  'assets/**/*.json',
];
void main() {
  Image.asset('assets/images/logo.png');
  print(ignorePatterns);
}
''');

    final result = await audit(project, checks: <Check>[const MissingCheck()]);

    expect(findingsWithCode(result, FindingCode.undeclaredReference), isEmpty);
  });

  test('ignored globs are excluded entirely', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/declared.png')
      ..png('assets/legacy/old.png')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(
      project,
      configure: (AssetGuardConfig c) =>
          c.copyWith(ignore: <String>['assets/legacy/**']),
    );

    expect(
      result.findings.where((Finding f) => (f.path ?? '').contains('legacy')),
      isEmpty,
    );
  });
}
