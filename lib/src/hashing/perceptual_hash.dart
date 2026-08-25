import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Everything the similarity and hygiene checks need from one raster file,
/// computed from a single decode.
class ImageFingerprint {
  const ImageFingerprint({
    required this.width,
    required this.height,
    required this.dHash,
    required this.hasAlphaChannel,
    required this.usesTransparency,
    required this.frameCount,
  });

  final int width;
  final int height;

  /// 64-bit difference hash packed into an int (native Dart ints are 64-bit).
  final int dHash;

  /// True when the encoded image carries an alpha channel at all.
  final bool hasAlphaChannel;

  /// True when at least one pixel is actually non-opaque. An image with an
  /// alpha channel where every pixel is opaque is wasting a channel.
  final bool usesTransparency;

  final int frameCount;

  bool get isAnimated => frameCount > 1;

  /// Same drawing at a different pixel size — the signature of a hand-resized
  /// copy that should have been a `2.0x/` variant.
  bool hasSameDimensionsAs(ImageFingerprint other) =>
      width == other.width && height == other.height;
}

/// Extensions we attempt to decode for perceptual comparison.
const Set<String> kRasterExtensions = <String>{
  '.png',
  '.jpg',
  '.jpeg',
  '.webp',
  '.bmp',
  '.gif',
};

/// Computes difference hashes (dHash) for raster images.
///
/// dHash resizes to 9x8 greyscale and records, for each row, whether each pixel
/// is brighter than its right-hand neighbour — 64 comparisons, 64 bits. It is
/// robust to rescaling and mild recompression, which is what "near-duplicate"
/// means for app assets, and it is cheap enough to run over a whole asset tree.
class PerceptualHasher {
  const PerceptualHasher();

  /// Returns `null` when the bytes aren't a decodable raster image.
  ///
  /// Only the first frame of an animation is decoded: comparing later frames
  /// would be both slow and meaningless for duplicate detection.
  ImageFingerprint? fingerprint(Uint8List bytes) {
    final img.Image? frame;
    final int frameCount;
    try {
      // Format sniffing is inside the guard on purpose: several decoders read
      // fixed-size headers and throw a RangeError on truncated input rather
      // than declining it. A corrupt file must not abort the whole audit.
      final img.Decoder? decoder = img.findDecoderForData(bytes);
      if (decoder == null) return null;

      final img.DecodeInfo? info = decoder.startDecode(bytes);
      if (info == null) return null;
      frameCount = info.numFrames;
      frame = decoder.decodeFrame(0);
    } on Object {
      return null;
    }
    if (frame == null) return null;

    return ImageFingerprint(
      width: frame.width,
      height: frame.height,
      dHash: _dHash(frame),
      hasAlphaChannel: frame.numChannels >= 4,
      usesTransparency: frame.numChannels >= 4 && _hasNonOpaquePixel(frame),
      frameCount: frameCount < 1 ? 1 : frameCount,
    );
  }

  int _dHash(img.Image source) {
    final img.Image small = img.copyResize(
      source,
      width: 9,
      height: 8,
      interpolation: img.Interpolation.average,
    );

    var hash = 0;
    var bit = 0;
    for (var y = 0; y < 8; y++) {
      for (var x = 0; x < 8; x++) {
        final left = _luminance(small, x, y);
        final right = _luminance(small, x + 1, y);
        if (left > right) {
          hash |= 1 << bit;
        }
        bit++;
      }
    }
    return hash;
  }

  double _luminance(img.Image image, int x, int y) {
    final img.Pixel pixel = image.getPixel(x, y);
    // Rec. 601 luma. Computed by hand rather than via the package's helper so
    // the value stays stable across `image` releases.
    return 0.299 * pixel.r + 0.587 * pixel.g + 0.114 * pixel.b;
  }

  bool _hasNonOpaquePixel(img.Image image) {
    final num maxValue = image.maxChannelValue;
    for (final img.Pixel pixel in image) {
      if (pixel.a < maxValue) return true;
    }
    return false;
  }
}

/// Number of differing bits between two dHashes. 0 means indistinguishable at
/// this resolution; <= 5 is the usual "looks the same to a human" band.
int hammingDistance(int a, int b) {
  var value = a ^ b;
  var count = 0;
  while (value != 0) {
    value &= value - 1; // Clears the lowest set bit.
    count++;
  }
  return count;
}
