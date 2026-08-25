import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Layouts specific to modular / melos-style Flutter projects, where assets
/// live in several packages and are referenced across package boundaries.
void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  /// A generated file whose accessor name cannot be derived by convention:
  /// the getter is `star` but the asset is nested at `assets/icons/star.png`,
  /// so the fallback would only ever produce `Assets.icons.star`. Resolving
  /// `Assets.g.star` therefore proves the generated file itself was parsed.
  String genFile(String getter, String assetPath) => '''
/// GENERATED CODE - DO NOT MODIFY BY HAND
/// FlutterGen
class \$AssetsGen {
  const \$AssetsGen();
  AssetGenImage get $getter => const AssetGenImage('$assetPath');
}

class Assets {
  Assets._();
  static const \$AssetsGen g = \$AssetsGen();
}
''';

  test('flutter_gen resolves through the generated file, not the convention',
      () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/icons/']))
      ..png('assets/icons/star.png')
      ..file(
          'lib/gen/assets.gen.dart', genFile('star', 'assets/icons/star.png'))
      ..file('lib/page.dart', '''
import 'gen/assets.gen.dart';
Widget build() => Image.asset(Assets.g.star.path);
''');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty,
        reason: '`Assets.g.star` is only resolvable by parsing the gen file; '
            'the naming convention would produce `Assets.icons.star`');
  });

  test('a bare generated constructor call is recognised without type info',
      () async {
    // `$AssetsGen()` has no `const`/`new`, so the unresolved parser reports it
    // as a method invocation. If that isn't handled, the root `Assets` class
    // registers zero members and every generated accessor silently fails.
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/icons/']))
      ..png('assets/icons/star.png')
      ..file(
          'lib/gen/assets.gen.dart', genFile('star', 'assets/icons/star.png'))
      ..file('lib/page.dart', '''
import 'gen/assets.gen.dart';
Widget build() => Image.asset(Assets.g.star.path);
''');

    final packages = const PubspecParser().discoverPackages(project.root);
    final scan = const CodeScanner().scan(
        project.root, packages, AssetGuardConfig(projectRoot: project.root));

    expect(
        scan.genClasses.keys, containsAll(<String>[r'$AssetsGen', 'Assets']));
    expect(scan.genClasses['Assets']!['g'], isA<ClassRefExpr>());
    expect((scan.genClasses['Assets']!['g']! as ClassRefExpr).className,
        r'$AssetsGen');
  });

  test('two packages may each declare their own generated Assets class',
      () async {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('packages/alpha/pubspec.yaml',
          flutterPubspec(name: 'alpha', assets: <String>['assets/icons/']))
      ..png('packages/alpha/assets/icons/star.png')
      ..file('packages/alpha/lib/gen/assets.gen.dart',
          genFile('star', 'assets/icons/star.png'))
      ..file('packages/alpha/lib/page.dart', '''
import 'gen/assets.gen.dart';
Widget a() => Image.asset(Assets.g.star.path);
''')
      ..file('packages/beta/pubspec.yaml',
          flutterPubspec(name: 'beta', assets: <String>['assets/icons/']))
      ..png('packages/beta/assets/icons/moon.png', pattern: 'reverse')
      ..file('packages/beta/lib/gen/assets.gen.dart',
          genFile('moon', 'assets/icons/moon.png'))
      ..file('packages/beta/lib/page.dart', '''
import 'gen/assets.gen.dart';
Widget b() => Image.asset(Assets.g.moon.path);
''');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty,
        reason: 'one package\'s generated class must not erase another\'s');
  });

  test('a package: argument outranks the package the caller lives in',
      () async {
    // Both packages hold a file at the same package-relative path. The app
    // references the design system's copy and never its own.
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('apps/mobile/pubspec.yaml',
          flutterPubspec(name: 'mobile', assets: <String>['assets/']))
      ..png('apps/mobile/assets/logo.png')
      ..file('packages/design_system/pubspec.yaml',
          flutterPubspec(name: 'design_system', assets: <String>['assets/']))
      ..png('packages/design_system/assets/logo.png', pattern: 'reverse')
      ..file('apps/mobile/lib/main.dart', '''
Widget a() => Image.asset('assets/logo.png', package: 'design_system');
''');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(pathsWithCode(result, FindingCode.unusedAsset),
        <String>['apps/mobile/assets/logo.png'],
        reason: 'the design system copy is the one actually loaded');
  });

  test('AssetImage honours the package argument too', () async {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('apps/mobile/pubspec.yaml', flutterPubspec(name: 'mobile'))
      ..file('packages/ui/pubspec.yaml',
          flutterPubspec(name: 'ui', assets: <String>['assets/']))
      ..png('packages/ui/assets/bg.png')
      ..file('apps/mobile/lib/main.dart', '''
const provider = AssetImage('assets/bg.png', package: 'ui');
void main() => print(provider);
''');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
  });

  test('feature-module directories are discovered like any other package',
      () async {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('features/auth/pubspec.yaml',
          flutterPubspec(name: 'auth', assets: <String>['assets/']))
      ..png('features/auth/assets/used.png')
      ..png('features/auth/assets/orphan.png', pattern: 'reverse')
      ..file('features/auth/lib/auth.dart', '''
Widget a() => Image.asset('assets/used.png');
''')
      ..file('modules/billing/pubspec.yaml',
          flutterPubspec(name: 'billing', assets: <String>['assets/']))
      ..png('modules/billing/assets/card.png', width: 32, height: 32)
      ..file('modules/billing/lib/billing.dart', '''
Widget b() => Image.asset('assets/card.png');
''');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(pathsWithCode(result, FindingCode.unusedAsset),
        <String>['features/auth/assets/orphan.png'],
        reason: 'discovery is by pubspec, not by a hardcoded packages/ folder');
  });

  test('same-named assets in sibling packages stay independent', () async {
    project
      ..file('pubspec.yaml', 'name: workspace\n')
      ..file('packages/one/pubspec.yaml',
          flutterPubspec(name: 'one', assets: <String>['assets/']))
      ..png('packages/one/assets/icon.png')
      ..file('packages/one/lib/one.dart', '''
Widget a() => Image.asset('packages/one/assets/icon.png');
''')
      ..file('packages/two/pubspec.yaml',
          flutterPubspec(name: 'two', assets: <String>['assets/']))
      ..png('packages/two/assets/icon.png', pattern: 'reverse')
      ..file('packages/two/lib/two.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const UnusedCheck()]);

    expect(pathsWithCode(result, FindingCode.unusedAsset),
        <String>['packages/two/assets/icon.png'],
        reason:
            'an explicit packages/<name>/ reference names exactly one file');
  });
}
