import 'finding.dart';
import 'reference.dart';

/// A tiny expression IR for the string-valued subset of Dart the scanner cares
/// about.
///
/// The AST visitor lowers into this so the resolver — which does the
/// cross-file constant propagation — never depends on `package:analyzer`
/// types, and so results are trivially testable.
sealed class ConstExpr {
  const ConstExpr();
}

/// A known string, e.g. `'assets/logo.png'`.
class LiteralExpr extends ConstExpr {
  const LiteralExpr(this.value);
  final String value;
}

/// A reference to a named constant or a flutter_gen accessor chain.
/// [name] may be dotted, e.g. `AppAssets.logo` or `Assets.images.logo`.
class RefExpr extends ConstExpr {
  const RefExpr(this.name);
  final String name;
}

/// Compile-time concatenation: adjacent strings or `+`.
class ConcatExpr extends ConstExpr {
  const ConcatExpr(this.parts);
  final List<ConstExpr> parts;
}

/// A string interpolation. `null` entries are the `${...}` holes whose value
/// isn't statically known.
class InterpolationExpr extends ConstExpr {
  const InterpolationExpr(this.parts);
  final List<ConstExpr?> parts;
}

/// A flutter_gen class instance, e.g. the `$AssetsImagesGen()` behind
/// `Assets.images`. Resolving a chain walks through these.
class ClassRefExpr extends ConstExpr {
  const ClassRefExpr(this.className);
  final String className;
}

/// Anything else. Kept (with source text) so unresolvable bundle loads can be
/// reported with the expression the author actually wrote.
class UnknownExpr extends ConstExpr {
  const UnknownExpr(this.source);
  final String source;
}

/// The outcome of resolving a [ConstExpr].
class ResolvedValue {
  const ResolvedValue.exact(String this.exact)
      : literalSegments = const <String>[];

  /// Partially known: the literal chunks surrounding dynamic holes.
  const ResolvedValue.partial(this.literalSegments) : exact = null;

  const ResolvedValue.unknown()
      : exact = null,
        literalSegments = const <String>[];

  /// The full string when every part was known.
  final String? exact;

  /// Literal chunks of a partially-known string, in source order.
  final List<String> literalSegments;

  bool get isExact => exact != null;
  bool get isPartial => exact == null && literalSegments.isNotEmpty;
  bool get isUnknown => exact == null && literalSegments.isEmpty;
}

/// A string-valued expression found in source that might name an asset.
class CandidateExpression {
  const CandidateExpression({
    required this.expr,
    required this.occurrence,
    required this.packageName,
    required this.kind,
    this.via,
    this.isLoadArgument = false,
    this.source,
  });

  final ConstExpr expr;
  final Occurrence occurrence;
  final String packageName;
  final ReferenceKind kind;

  /// The symbol the value came through, for report wording.
  final String? via;

  /// True when this expression is the path argument of an asset/bundle load.
  /// Those get reported as unresolvable when they can't be pinned down, since
  /// an unresolvable load can reach anything in the bundle.
  final bool isLoadArgument;

  /// Original source text, used in messages about unresolvable loads.
  final String? source;
}

/// A bundle load whose path argument is a parameter of the enclosing function.
///
/// The resolver tries to satisfy it from call sites elsewhere in the project
/// before giving up and reporting it as unresolvable.
class PendingParameterRef {
  const PendingParameterRef({
    required this.functionName,
    required this.parameterName,
    required this.argumentIndex,
    required this.occurrence,
    required this.packageName,
    required this.source,
  });

  final String functionName;
  final String parameterName;
  final int argumentIndex;
  final Occurrence occurrence;
  final String packageName;
  final String source;
}
