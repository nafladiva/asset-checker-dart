import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('distinguishes file entries from directory entries', () {
    project
      ..file(
          'pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>[
            'assets/images/',
            'assets/logo.png',
          ]))
      ..png('assets/logo.png')
      ..directory('assets/images');

    final packages = const PubspecParser().discoverPackages(project.root);
    final declarations = packages.single.declarations;

    expect(declarations, hasLength(2));
    expect(declarations[0].kind, AssetDeclarationKind.directory);
    expect(declarations[0].path, 'assets/images/');
    expect(declarations[0].directoryPath, 'assets/images');
    expect(declarations[1].kind, AssetDeclarationKind.file);
    expect(declarations[1].path, 'assets/logo.png');
  });

  test('treats an existing directory as one even without a trailing slash', () {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images']))
      ..png('assets/images/logo.png');

    final packages = const PubspecParser().discoverPackages(project.root);

    expect(packages.single.declarations.single.kind,
        AssetDeclarationKind.directory);
  });

  test('parses the map form with flavors', () {
    project.file('pubspec.yaml', '''
name: my_app
environment:
  sdk: ">=3.4.0 <4.0.0"
flutter:
  assets:
    - path: assets/premium/
      flavors:
        - paid
''');
    project.directory('assets/premium');

    final packages = const PubspecParser().discoverPackages(project.root);
    final declaration = packages.single.declarations.single;

    expect(declaration.path, 'assets/premium/');
    expect(declaration.flavors, <String>['paid']);
  });

  test('captures font families, their files and the declaration line', () {
    project.file('pubspec.yaml', '''
${flutterPubspec(name: 'my_app')}  fonts:
    - family: Roboto
      fonts:
        - asset: assets/fonts/roboto.ttf
          weight: 400
        - asset: assets/fonts/roboto_bold.ttf
          weight: 700
''');

    final packages = const PubspecParser().discoverPackages(project.root);
    final font = packages.single.fonts.single;

    expect(font.family, 'Roboto');
    expect(font.assetPaths, <String>[
      'assets/fonts/roboto.ttf',
      'assets/fonts/roboto_bold.ttf',
    ]);
    expect(font.origin.file, 'pubspec.yaml');
    expect(font.origin.line, isNotNull);
  });

  test('discovers every package in a melos-style workspace, root first', () {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('packages/core/pubspec.yaml', 'name: core\n')
      ..file('packages/ui/pubspec.yaml',
          flutterPubspec(name: 'ui', assets: <String>['assets/icons/']))
      ..directory('packages/ui/assets/icons');

    final packages = const PubspecParser().discoverPackages(project.root);

    expect(packages.map((PackageContext p) => p.name),
        <String>['workspace', 'core', 'ui']);
    expect(
        packages
            .firstWhere((PackageContext p) => p.name == 'ui')
            .isFlutterPackage,
        isTrue);
    expect(
        packages
            .firstWhere((PackageContext p) => p.name == 'core')
            .isFlutterPackage,
        isFalse);
  });

  test('package-relative entries resolve to project-relative paths', () {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('packages/ui/pubspec.yaml',
          flutterPubspec(name: 'ui', assets: <String>['assets/icons/star.png']))
      ..png('packages/ui/assets/icons/star.png');

    final packages = const PubspecParser().discoverPackages(project.root);
    final ui = packages.firstWhere((PackageContext p) => p.name == 'ui');

    expect(ui.declarations.single.path, 'packages/ui/assets/icons/star.png');
  });

  test('skips build and tool directories when discovering packages', () {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('build/vendored/pubspec.yaml', 'name: vendored\n')
      ..file('.dart_tool/thing/pubspec.yaml', 'name: tooling\n');

    final packages = const PubspecParser().discoverPackages(project.root);

    expect(packages.map((PackageContext p) => p.name), <String>['workspace']);
  });

  test('a malformed pubspec is skipped rather than aborting the audit', () {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('packages/broken/pubspec.yaml', 'name: [unclosed\n')
      ..file('packages/ok/pubspec.yaml', 'name: ok\n');

    final packages = const PubspecParser().discoverPackages(project.root);

    expect(packages.map((PackageContext p) => p.name),
        <String>['workspace', 'ok']);
  });
}
