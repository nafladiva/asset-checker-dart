import 'finding.dart';

/// How an asset path was arrived at in source. Purely informational — it drives
/// report wording, not correctness.
enum ReferenceKind {
  /// A plain `'assets/logo.png'` literal.
  literal,

  /// Implicitly concatenated adjacent string literals.
  adjacentStrings,

  /// Reached through a `const`/`final` variable or class constant.
  constant,

  /// Compile-time `+` concatenation of literals/constants.
  concatenation,

  /// A flutter_gen accessor such as `Assets.images.logo`.
  flutterGen,

  /// Found by scanning `android/`, `ios/`, `web/`, `macos/` and friends.
  native,
}

extension ReferenceKindLabel on ReferenceKind {
  String get label {
    switch (this) {
      case ReferenceKind.literal:
        return 'string literal';
      case ReferenceKind.adjacentStrings:
        return 'adjacent strings';
      case ReferenceKind.constant:
        return 'constant';
      case ReferenceKind.concatenation:
        return 'concatenation';
      case ReferenceKind.flutterGen:
        return 'flutter_gen accessor';
      case ReferenceKind.native:
        return 'native/platform file';
    }
  }
}

/// A fully-resolved reference to a concrete asset path.
class AssetReference {
  const AssetReference({
    required this.value,
    required this.kind,
    required this.occurrence,
    this.via,
  });

  /// The resolved path string as it appeared in source.
  final String value;

  final ReferenceKind kind;
  final Occurrence occurrence;

  /// For [ReferenceKind.constant] / [ReferenceKind.flutterGen], the symbol that
  /// produced the value, e.g. `AppAssets.logo` — shown in reports so a reader
  /// can find the indirection.
  final String? via;

  @override
  String toString() => 'AssetReference($value via ${via ?? kind.label})';
}

/// A reference whose full path can't be known statically, but whose literal
/// prefix pins it to a directory — e.g. `'assets/flags/${code}.png'`.
///
/// Every asset under [prefix] is marked possibly-used rather than unused.
class DynamicReference {
  const DynamicReference({
    required this.prefix,
    required this.rawSource,
    required this.occurrence,
    this.via,
  });

  /// Project-relative POSIX directory prefix, without a trailing slash.
  final String prefix;

  /// The interpolation as written, for the human reviewing the report.
  final String rawSource;

  final Occurrence occurrence;
  final String? via;

  @override
  String toString() => 'DynamicReference($prefix from $rawSource)';
}

/// A bundle load whose argument could not be pinned to any directory at all,
/// e.g. `rootBundle.loadString(path)` where `path` is a parameter with no
/// resolvable call site.
///
/// These are reported for human review. They also block `--delete-unused`,
/// because such a call can reach any asset in the bundle.
class UnresolvableReference {
  const UnresolvableReference({
    required this.expression,
    required this.occurrence,
    required this.reason,
  });

  /// Source text of the call, e.g. `rootBundle.loadString(path)`.
  final String expression;

  final Occurrence occurrence;

  /// Why resolution failed, phrased for the report.
  final String reason;
}

/// Whether an asset is reachable from code.
enum UsageStatus {
  /// A concrete reference resolves to this file.
  used,

  /// Only a dynamic pattern could reach it. Never reported as unused, never
  /// deleted.
  possiblyUsed,

  /// Nothing references it.
  unused,
}
