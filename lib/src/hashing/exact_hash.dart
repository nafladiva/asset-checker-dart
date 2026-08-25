import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// SHA-256 of raw file bytes, hex-encoded.
///
/// Used to group byte-identical assets. Deliberately hashes bytes rather than
/// decoded pixels — two PNGs with identical pixels but different encoders are
/// *not* exact duplicates, and the similarity check catches those instead.
String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();
