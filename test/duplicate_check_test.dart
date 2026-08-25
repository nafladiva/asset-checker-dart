import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('byte-identical files are grouped with the wasted bytes', () async {
    final bytes = pngBytes(width: 32, height: 32);
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..bytes('assets/images/logo.png', bytes)
      ..bytes('assets/images/logo_copy.png', bytes)
      ..bytes('assets/images/brand.png', bytes)
      ..file('lib/main.dart', '''
void main() {
  Image.asset('assets/images/logo.png');
  Image.asset('assets/images/logo_copy.png');
  Image.asset('assets/images/brand.png');
}
''');

    final result =
        await audit(project, checks: <Check>[const DuplicateCheck()]);
    final duplicates = findingsWithCode(result, FindingCode.duplicateAssets);

    expect(duplicates, hasLength(1));
    expect(duplicates.single.path, 'assets/images/brand.png');
    expect(duplicates.single.relatedPaths, <String>[
      'assets/images/logo.png',
      'assets/images/logo_copy.png',
    ]);
    expect(duplicates.single.data['count'], 3);
    expect(duplicates.single.reclaimableBytes, bytes.length * 2);
  });

  test('files with different bytes are not grouped', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/a.png', pattern: 'gradient')
      ..png('assets/images/b.png', pattern: 'reverse')
      ..file('lib/main.dart', 'void main() {}');

    final result =
        await audit(project, checks: <Check>[const DuplicateCheck()]);

    expect(findingsWithCode(result, FindingCode.duplicateAssets), isEmpty);
  });

  test('zero-byte files are reported separately, never grouped', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/data/']))
      ..file('assets/data/empty_one.json', '')
      ..file('assets/data/empty_two.json', '')
      ..file('lib/main.dart', 'void main() {}');

    final result =
        await audit(project, checks: <Check>[const DuplicateCheck()]);

    expect(findingsWithCode(result, FindingCode.duplicateAssets), isEmpty,
        reason: 'empty files all share a hash and would form a fake group');
    expect(pathsWithCode(result, FindingCode.emptyFile), <String>[
      'assets/data/empty_one.json',
      'assets/data/empty_two.json',
    ]);
  });
}
