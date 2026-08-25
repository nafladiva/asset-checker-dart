import 'dart:typed_data';

import 'package:asset_guard/asset_guard.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  group('sha256Hex', () {
    test('is stable and differs for different bytes', () {
      final a = Uint8List.fromList(<int>[1, 2, 3]);
      final b = Uint8List.fromList(<int>[1, 2, 4]);

      expect(sha256Hex(a), sha256Hex(Uint8List.fromList(<int>[1, 2, 3])));
      expect(sha256Hex(a), isNot(sha256Hex(b)));
      expect(sha256Hex(a), hasLength(64));
    });
  });

  group('dHash', () {
    const hasher = PerceptualHasher();

    test('is invariant to scale for the same image', () {
      final large = hasher
          .fingerprint(Uint8List.fromList(pngBytes(width: 64, height: 64)))!;
      final small = hasher
          .fingerprint(Uint8List.fromList(pngBytes(width: 32, height: 32)))!;

      expect(hammingDistance(large.dHash, small.dHash), 0);
      expect(large.hasSameDimensionsAs(small), isFalse);
    });

    test('separates visually opposite images', () {
      final gradient = hasher
          .fingerprint(Uint8List.fromList(pngBytes(pattern: 'gradient')))!;
      final reverse =
          hasher.fingerprint(Uint8List.fromList(pngBytes(pattern: 'reverse')))!;

      expect(hammingDistance(gradient.dHash, reverse.dHash), greaterThan(5));
    });

    test('reports alpha channel presence and whether it is used', () {
      final opaque =
          hasher.fingerprint(Uint8List.fromList(pngBytes(alpha: false)))!;
      final withAlpha =
          hasher.fingerprint(Uint8List.fromList(pngBytes(alpha: true)))!;

      expect(opaque.hasAlphaChannel, isFalse);
      expect(withAlpha.hasAlphaChannel, isTrue);
      expect(withAlpha.usesTransparency, isFalse);
    });

    test('returns null for bytes that are not an image', () {
      expect(hasher.fingerprint(Uint8List.fromList(<int>[1, 2, 3, 4])), isNull);
    });
  });

  group('hammingDistance', () {
    test('counts differing bits', () {
      expect(hammingDistance(0, 0), 0);
      expect(hammingDistance(0, 1), 1);
      expect(hammingDistance(0x0F, 0x00), 4);
      expect(hammingDistance(-1, 0), 64, reason: 'all 64 bits set');
    });
  });

  group('SvgNormalizer', () {
    const normalizer = SvgNormalizer();

    test('ignores comments, xml declarations and ids', () {
      const a = '<svg viewBox="0 0 10 10"><path id="one" d="M0 0 L5 5"/></svg>';
      const b = '''
<?xml version="1.0"?>
<!-- exported -->
<svg viewBox="0 0 10 10">
  <path id="Layer_2" d="M0 0 L5 5"/>
</svg>
''';

      expect(normalizer.normalizedHash(a), normalizer.normalizedHash(b));
    });

    test('rounds sub-pixel jitter away', () {
      const a = '<svg><path d="M10.001 20.002"/></svg>';
      const b = '<svg><path d="M10.004 20.001"/></svg>';

      expect(normalizer.normalizedHash(a), normalizer.normalizedHash(b));
    });

    test('keeps genuinely different geometry apart', () {
      const a = '<svg><path d="M0 0 L5 5"/></svg>';
      const b = '<svg><path d="M0 0 H99"/></svg>';

      expect(normalizer.normalizedHash(a), isNot(normalizer.normalizedHash(b)));
    });

    test('returns null for input that is not SVG', () {
      expect(normalizer.normalize('{"json": true}'), isNull);
    });

    test('extracts path geometry only', () {
      const svg =
          '<svg><path fill="#fff" d="M1 2 L3 4"/><path d="M5 6"/></svg>';

      expect(normalizer.pathData(svg), 'M1 2 L3 4 M5 6');
    });
  });

  group('bigramSimilarity', () {
    test('scores identical strings 1 and disjoint strings 0', () {
      expect(bigramSimilarity('abcdef', 'abcdef'), 1);
      expect(bigramSimilarity('aaaa', 'zzzz'), 0);
    });

    test('scores near-identical strings high', () {
      expect(
          bigramSimilarity('M10 20 L30 40', 'M10 20 L30 41'), greaterThan(0.7));
    });
  });

  group('humanBytes', () {
    test('formats each magnitude', () {
      expect(humanBytes(512), '512 B');
      expect(humanBytes(2048), '2.0 KB');
      expect(humanBytes(1024 * 1024 * 3), '3.0 MB');
    });
  });

  group('path helpers', () {
    test('normalizes separators and redundant segments', () {
      expect(normalizeAssetPath(r'assets\images\logo.png'),
          'assets/images/logo.png');
      expect(normalizeAssetPath('./assets//logo.png'), 'assets/logo.png');
    });

    test('parses package references', () {
      final parsed = parsePackageReference('packages/design/assets/star.png');

      expect(parsed?.package, 'design');
      expect(parsed?.path, 'assets/star.png');
      expect(parsePackageReference('assets/star.png'), isNull);
    });

    test('recognises resolution variant directories', () {
      expect(variantScaleOf('2.0x'), 2.0);
      expect(variantScaleOf('3x'), 3.0);
      expect(variantScaleOf('images'), isNull);
    });
  });
}
