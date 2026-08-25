import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Builds a result with no filesystem behind it, so the scoring arithmetic can
/// be asserted exactly rather than inferred from a fixture's findings.
AuditResult resultWith({
  required List<AssetFile> assets,
  List<Finding> findings = const <Finding>[],
}) =>
    AuditResult(
      context: syntheticContext(assets: assets),
      findings: findings,
    );

Finding finding(
  Severity severity,
  String code, {
  String? path,
  List<String> related = const <String>[],
  int reclaimable = 0,
}) =>
    Finding(
      severity: severity,
      code: code,
      message: 'test',
      path: path,
      relatedPaths: related,
      data: <String, Object?>{'reclaimableBytes': reclaimable},
    );

void main() {
  group('scoring', () {
    test('a project with no findings scores 100', () {
      final health = HealthScore.from(resultWith(assets: <AssetFile>[
        syntheticAsset('assets/a.png'),
        syntheticAsset('assets/b.png'),
        syntheticAsset('assets/c.png'),
      ]));

      expect(health.roundedScore, 100);
      expect(health.grade, 'A');
      expect(health.cleanAssets, 3);
      expect(health.totalAssets, 3);
    });

    test('a warning halves that asset\'s contribution', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[
          syntheticAsset('assets/a.png'),
          syntheticAsset('assets/b.png'),
        ],
        findings: <Finding>[
          finding(Severity.warning, FindingCode.unusedAsset,
              path: 'assets/b.png'),
        ],
      ));

      // (1.0 + 0.5) / 2
      expect(health.roundedScore, 75);
      expect(health.cleanAssets, 1);
      expect(health.assetsWithWarning, 1);
    });

    test('an error zeroes that asset\'s contribution', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[
          syntheticAsset('assets/a.png'),
          syntheticAsset('assets/b.png'),
        ],
        findings: <Finding>[
          finding(Severity.error, FindingCode.caseCollision,
              path: 'assets/b.png'),
        ],
      ));

      expect(health.roundedScore, 50);
      expect(health.assetsWithError, 1);
    });

    test('info findings do not affect the score', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[syntheticAsset('assets/a.png')],
        findings: <Finding>[
          finding(Severity.info, FindingCode.possiblyUsedAsset,
              path: 'assets/a.png'),
          finding(Severity.info, FindingCode.pngWithoutAlpha,
              path: 'assets/a.png'),
        ],
      ));

      expect(health.roundedScore, 100,
          reason:
              'a dynamic reference is the tool being careful, not a defect');
      expect(health.cleanAssets, 1);
    });

    test('the worst severity against an asset wins', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[syntheticAsset('assets/a.png')],
        findings: <Finding>[
          finding(Severity.warning, FindingCode.largeAsset,
              path: 'assets/a.png'),
          finding(Severity.error, FindingCode.caseCollision,
              path: 'assets/a.png'),
        ],
      ));

      expect(health.roundedScore, 0);
      expect(health.assetsWithError, 1);
      expect(health.assetsWithWarning, 0,
          reason: 'an asset is counted once, at its worst severity');
    });

    test('related paths in a group are penalised too', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[
          syntheticAsset('assets/a.png'),
          syntheticAsset('assets/b.png'),
        ],
        findings: <Finding>[
          finding(Severity.warning, FindingCode.duplicateAssets,
              path: 'assets/a.png', related: <String>['assets/b.png']),
        ],
      ));

      expect(health.assetsWithWarning, 2);
      expect(health.roundedScore, 50);
    });

    test('findings with no file behind them still count against the score', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[syntheticAsset('assets/a.png')],
        findings: <Finding>[
          // A declared directory that does not exist matches no asset on disk.
          finding(Severity.error, FindingCode.missingDeclaredAsset,
              path: 'assets/ghost'),
        ],
      ));

      expect(health.projectLevelErrors, 1);
      expect(health.roundedScore, 50,
          reason: 'a broken pubspec must not be able to score 100%');
    });

    test('a project with nothing to audit is not unhealthy', () {
      final health = HealthScore.from(resultWith(assets: <AssetFile>[]));

      expect(health.roundedScore, 100);
      expect(health.grade, 'A');
    });

    test('reclaimable bytes count only unused assets', () {
      final health = HealthScore.from(resultWith(
        assets: <AssetFile>[syntheticAsset('assets/a.png', sizeBytes: 1000)],
        findings: <Finding>[
          finding(Severity.warning, FindingCode.unusedAsset,
              path: 'assets/a.png', reclaimable: 400),
          finding(Severity.warning, FindingCode.duplicateAssets,
              path: 'assets/a.png', reclaimable: 999),
        ],
      ));

      expect(health.reclaimableBytes, 400,
          reason: 'a duplicate group still needs a human to pick a survivor');
      expect(health.totalBytes, 1000);
      expect(health.wastePercent, 40);
    });
  });

  group('presentation', () {
    HealthScore scoreOf(int clean, int warned) => HealthScore.from(resultWith(
          assets: <AssetFile>[
            for (var i = 0; i < clean + warned; i++)
              syntheticAsset('assets/a$i.png'),
          ],
          findings: <Finding>[
            for (var i = clean; i < clean + warned; i++)
              finding(Severity.warning, FindingCode.unusedAsset,
                  path: 'assets/a$i.png'),
          ],
        ));

    test('grades follow the documented thresholds', () {
      expect(scoreOf(10, 0).grade, 'A'); // 100
      expect(scoreOf(8, 2).grade, 'A'); // 90
      expect(scoreOf(6, 4).grade, 'B'); // 80
      expect(scoreOf(4, 6).grade, 'C'); // 70
      expect(scoreOf(2, 8).grade, 'D'); // 60
      expect(scoreOf(0, 10).grade, 'F'); // 50
    });

    test('the bar is fixed width and tracks the score', () {
      expect(scoreOf(10, 0).bar(width: 10), '██████████');
      expect(scoreOf(0, 10).bar(width: 10), '█████░░░░░');
      expect(scoreOf(4, 6).bar(width: 20).length, 20);
    });
  });

  group('CLI gate', () {
    late FixtureProject project;

    setUp(() {
      project = FixtureProject.create();
      project
        ..file('pubspec.yaml',
            flutterPubspec(name: 'my_app', assets: <String>['assets/images/']))
        ..png('assets/images/used.png')
        ..png('assets/images/orphan.png', pattern: 'reverse')
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

    test('pretty output reports the score and its breakdown', () async {
      final result = await run(<String>['--check', 'unused']);

      expect(result.out, contains('Asset health'));
      expect(result.out, contains('%'));
      expect(result.out, contains('of 2 assets'));
    });

    test('json exposes health under summary', () async {
      final result =
          await run(<String>['--format', 'json', '--check', 'unused']);

      expect(result.out, contains('"health"'));
      expect(result.out, contains('"grade"'));
      expect(result.out, contains('"wastePercent"'));
    });

    test('markdown includes a health row', () async {
      final result = await run(<String>['--format', 'markdown']);

      expect(result.out, contains('Asset health'));
    });

    test('--min-health fails below the threshold and passes above', () async {
      // One of two assets is unused, so the score is 75.
      expect(
          (await run(<String>['--check', 'unused', '--min-health', '80'])).code,
          ExitCodes.findings);
      expect(
          (await run(<String>['--check', 'unused', '--min-health', '70'])).code,
          ExitCodes.success);
    });

    test('--min-health explains why it failed', () async {
      final result =
          await run(<String>['--check', 'unused', '--min-health', '95']);

      expect(result.err, contains('below the required 95%'));
    });

    test('the health gate is independent of --fail-on', () async {
      final result = await run(<String>[
        '--check',
        'unused',
        '--fail-on',
        'none',
        '--min-health',
        '90',
      ]);

      expect(result.code, ExitCodes.findings,
          reason: '--fail-on none must not disable an explicit health gate');
    });

    test('an out-of-range --min-health is a usage error', () async {
      final result = await run(<String>['--min-health', '150']);

      expect(result.code, ExitCodes.usageError);
      expect(result.err, contains('at most 100'));
    });

    test('min_health may be set in asset_guard.yaml', () async {
      project.file('asset_guard.yaml', 'min_health: 90\n');

      final result = await run(<String>['--check', 'unused']);

      expect(result.code, ExitCodes.findings);
    });
  });
}
