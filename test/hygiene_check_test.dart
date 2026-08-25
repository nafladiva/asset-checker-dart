import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  late FixtureProject project;

  setUp(() => project = FixtureProject.create());
  tearDown(() => project.dispose());

  test('files over the size limit are reported with a hint', () async {
    // Deliberately incompressible: a generated gradient PNG shrinks to a few
    // hundred bytes, which would make this test pass or fail on codec luck.
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/data/']))
      ..bytes('assets/data/huge.bin',
          List<int>.generate(3000, (int i) => (i * 37) % 256))
      ..bytes('assets/data/small.bin', List<int>.filled(10, 0))
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(
      project,
      checks: <Check>[const HygieneCheck()],
      configure: (AssetGuardConfig c) => c.copyWith(maxFileSizeKb: 1),
    );

    final large = findingsWithCode(result, FindingCode.largeAsset);
    expect(large, hasLength(1));
    expect(large.single.path, 'assets/data/huge.bin');
    expect(large.single.message, contains('WebP'));
  });

  test('a PNG with no alpha channel is flagged', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/opaque.png', alpha: false)
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const HygieneCheck()]);
    final findings = findingsWithCode(result, FindingCode.pngWithoutAlpha);

    expect(findings, hasLength(1));
    expect(findings.single.path, 'assets/images/opaque.png');
    expect(findings.single.data['alphaUnused'], isNull);
  });

  test('an alpha channel that is fully opaque is flagged as overhead',
      () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/wasteful.png', alpha: true)
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const HygieneCheck()]);
    final findings = findingsWithCode(result, FindingCode.pngWithoutAlpha);

    expect(findings, hasLength(1));
    expect(findings.single.data['alphaUnused'], isTrue);
  });

  test('filenames with spaces and uppercase are reported', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
      ..png('assets/images/My Icon.png')
      ..png('assets/images/fine.png')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const HygieneCheck()]);
    final findings = findingsWithCode(result, FindingCode.problematicFilename);

    expect(findings, hasLength(1));
    expect(findings.single.path, 'assets/images/My Icon.png');
    expect(findings.single.data['problems'],
        <String>['spaces', 'uppercase letters']);
  });

  test('paths differing only by case are an error', () async {
    // Built in memory: a case-insensitive macOS volume cannot hold both files.
    final context = syntheticContext(assets: <AssetFile>[
      syntheticAsset('assets/images/logo.png'),
      syntheticAsset('assets/images/Logo.png'),
      syntheticAsset('assets/images/other.png'),
    ]);

    final findings = await const HygieneCheck().run(context);
    final collisions = findings
        .where((Finding f) => f.code == FindingCode.caseCollision)
        .toList(growable: false);

    expect(collisions, hasLength(1));
    expect(collisions.single.severity, Severity.error);
    expect(collisions.single.path, 'assets/images/Logo.png');
    expect(collisions.single.relatedPaths, <String>['assets/images/logo.png']);
  });

  test('a font family never named in a string is reported', () async {
    project
      ..file('pubspec.yaml', '''
${flutterPubspec(name: 'my_app')}  fonts:
    - family: UsedFamily
      fonts:
        - asset: assets/fonts/used.ttf
    - family: OrphanFamily
      fonts:
        - asset: assets/fonts/orphan.ttf
''')
      ..file('assets/fonts/used.ttf', 'stub')
      ..file('assets/fonts/orphan.ttf', 'stub')
      ..file('lib/main.dart', '''
const style = TextStyle(fontFamily: 'UsedFamily');
''');

    final result = await audit(project, checks: <Check>[const HygieneCheck()]);
    final findings = findingsWithCode(result, FindingCode.unusedFontFamily);

    expect(findings, hasLength(1));
    expect(findings.single.data['family'], 'OrphanFamily');
    expect(findings.single.relatedPaths, <String>['assets/fonts/orphan.ttf']);
  });

  test('an empty declared directory is reported', () async {
    project
      ..file('pubspec.yaml',
          flutterPubspec(name: 'my_app', assets: <String>['assets/empty/']))
      ..directory('assets/empty')
      ..file('lib/main.dart', 'void main() {}');

    final result = await audit(project, checks: <Check>[const HygieneCheck()]);
    final findings = findingsWithCode(result, FindingCode.emptyAssetDirectory);

    expect(findings, hasLength(1));
    expect(findings.single.path, 'assets/empty');
  });
}
