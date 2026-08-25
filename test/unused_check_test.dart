import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  group('reference detection', () {
    test('a plain string literal marks an asset used', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/used.png')
        ..png('assets/images/orphan.png')
        ..file('lib/main.dart', '''
import 'package:flutter/material.dart';

Widget build() => Image.asset('assets/images/used.png');
''');

      final result = await audit(project);

      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['assets/images/orphan.png']);
    });

    test('a const class field is followed to the asset it names', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/logo.png')
        ..png('assets/images/never_referenced.png')
        ..file('lib/app_assets.dart', '''
class AppAssets {
  static const String logo = 'assets/images/logo.png';
  static const String neverReferenced = 'assets/images/never_referenced.png';
}
''')
        ..file('lib/main.dart', '''
import 'app_assets.dart';

void main() {
  print(AppAssets.logo);
}
''');

      final result = await audit(project);

      // `neverReferenced` is declared but the symbol is never used, so its
      // asset must still be reported — otherwise every constant would mark its
      // own target used and the check would be worthless.
      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['assets/images/never_referenced.png']);
    });

    test('adjacent strings and + concatenation resolve', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/adjacent.png')
        ..png('assets/images/plus.png')
        ..file('lib/main.dart', r'''
const String base = 'assets/images/';

void main() {
  final a = 'assets/images/'
      'adjacent.png';
  final b = base + 'plus.png';
  print('$a $b');
}
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
    });

    test('flutter_gen accessors resolve through the generated file', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/logo.png')
        ..png('assets/images/unused_gen.png')
        ..file('lib/gen/assets.gen.dart', r'''
/// GENERATED CODE - DO NOT MODIFY BY HAND
/// FlutterGen
class $AssetsImagesGen {
  const $AssetsImagesGen();

  AssetGenImage get logo => const AssetGenImage('assets/images/logo.png');
  AssetGenImage get unusedGen =>
      const AssetGenImage('assets/images/unused_gen.png');
}

class Assets {
  Assets._();
  static const $AssetsImagesGen images = $AssetsImagesGen();
}
''')
        ..file('lib/main.dart', '''
import 'gen/assets.gen.dart';

void main() {
  print(Assets.images.logo);
}
''');

      final result = await audit(project);

      // The generated file's own literals must not count as references, or
      // `unusedGen` would look used.
      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['assets/images/unused_gen.png']);
    });

    test('flutter_gen naming resolves without a generated file', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/icons/']))
        ..png('assets/icons/arrow_back.png')
        ..file('lib/main.dart', '''
void main() {
  print(Assets.icons.arrowBack);
}
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
    });

    test('assets referenced only from native config are not unused', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/splash.png')
        ..file('lib/main.dart', 'void main() {}')
        ..file('web/index.html', '''
<html><body><img src="assets/images/splash.png"></body></html>
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
    });
  });

  group('dynamic references', () {
    test('interpolation marks the whole directory possiblyUsed, not unused',
        () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/flags/']))
        ..png('assets/flags/us.png')
        ..png('assets/flags/gb.png')
        ..png('assets/flags/de.png')
        ..file('lib/main.dart', r'''
Widget flag(String code) => Image.asset('assets/flags/$code.png');
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty,
          reason: 'a dynamic path into the directory must suppress unused');

      expect(
        pathsWithCode(result, FindingCode.possiblyUsedAsset),
        containsAll(<String>[
          'assets/flags/de.png',
          'assets/flags/gb.png',
          'assets/flags/us.png',
        ]),
      );

      final dynamicFindings =
          findingsWithCode(result, FindingCode.dynamicReference);
      expect(dynamicFindings, hasLength(1));
      expect(dynamicFindings.single.path, 'assets/flags');
      expect(dynamicFindings.single.occurrences.single.file, 'lib/main.dart');
      expect(dynamicFindings.single.occurrences.single.line, 1);
    });

    test('interpolation only covers its own directory', () async {
      project
        ..file(
            'pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>[
              'assets/flags/',
              'assets/images/',
            ]))
        ..png('assets/flags/us.png')
        ..png('assets/images/orphan.png')
        ..file('lib/main.dart', r'''
Widget flag(String code) => Image.asset('assets/flags/$code.png');
''');

      final result = await audit(project);

      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['assets/images/orphan.png']);
    });

    test('a bundle load taking a parameter is reported as unresolvable',
        () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/data/']))
        ..file('assets/data/config.json', '{}')
        ..file('lib/main.dart', '''
import 'package:flutter/services.dart';

Future<String> loadAnything(String path) => rootBundle.loadString(path);
''');

      final result = await audit(project);

      final unresolvable =
          findingsWithCode(result, FindingCode.unresolvableDynamicReference);
      expect(unresolvable, hasLength(1));
      expect(unresolvable.single.severity, Severity.warning);
      expect(unresolvable.single.occurrences.single.file, 'lib/main.dart');
    });

    test('a parameterised loader is resolved from its call sites', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/data/']))
        ..file('assets/data/config.json', '{}')
        ..file('lib/main.dart', '''
import 'package:flutter/services.dart';

Future<String> loadAsset(String path) => rootBundle.loadString(path);

void main() {
  loadAsset('assets/data/config.json');
}
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unresolvableDynamicReference),
          isEmpty);
      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
    });

    test('treat_dynamic_as_used: false lets dynamic assets be reported',
        () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/flags/']))
        ..png('assets/flags/us.png')
        ..file('lib/main.dart', r'''
Widget flag(String code) => Image.asset('assets/flags/$code.png');
''');

      final result = await audit(project,
          configure: (AssetGuardConfig c) =>
              c.copyWith(treatDynamicAsUsed: false));

      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['assets/flags/us.png']);
    });
  });

  group('resolution variants', () {
    test('a 2.0x variant is never reported on its own', () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/logo.png')
        ..png('assets/images/2.0x/logo.png', width: 128, height: 128)
        ..png('assets/images/3.0x/logo.png', width: 192, height: 192)
        ..file('lib/main.dart', '''
Widget build() => Image.asset('assets/images/logo.png');
''');

      final result = await audit(project);

      expect(findingsWithCode(result, FindingCode.unusedAsset), isEmpty);
      expect(result.context.usageOf('assets/images/2.0x/logo.png'),
          UsageStatus.used);
    });

    test('an unused parent reports its variants as related, not separately',
        () async {
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/old.png')
        ..png('assets/images/2.0x/old.png', width: 128, height: 128)
        ..file('lib/main.dart', 'void main() {}');

      final result = await audit(project);

      final unused = findingsWithCode(result, FindingCode.unusedAsset);
      expect(unused, hasLength(1));
      expect(unused.single.path, 'assets/images/old.png');
      expect(
          unused.single.relatedPaths, <String>['assets/images/2.0x/old.png']);
    });
  });

  group('monorepo', () {
    test('a reference from one package keeps another package\'s asset alive',
        () async {
      project
        ..file('pubspec.yaml',
            'name: workspace\nenvironment:\n  sdk: ">=3.4.0 <4.0.0"\n')
        ..file('packages/design/pubspec.yaml',
            flutterPubspec(name: 'design', assets: <String>['assets/icons/']))
        ..png('packages/design/assets/icons/star.png')
        ..png('packages/design/assets/icons/unused.png')
        ..file('packages/app/pubspec.yaml', flutterPubspec(name: 'app'))
        ..file('packages/app/lib/main.dart', '''
Widget build() => Image.asset('packages/design/assets/icons/star.png');
''');

      final result = await audit(project);

      expect(pathsWithCode(result, FindingCode.unusedAsset),
          <String>['packages/design/assets/icons/unused.png']);
    });
  });
}
