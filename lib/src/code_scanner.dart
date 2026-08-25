import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'models/asset.dart';
import 'models/const_expr.dart';
import 'models/finding.dart';
import 'models/reference.dart';
import 'util/paths.dart';

/// Raw output of the AST pass, before constant propagation.
class CodeScanResult {
  CodeScanResult({
    required this.candidates,
    required this.constants,
    required this.genClasses,
    required this.symbolUses,
    required this.pendingParameters,
    required this.invocationArguments,
    required this.literalStrings,
    required this.filesScanned,
  });

  /// Every string-valued expression that might name an asset.
  final List<CandidateExpression> candidates;

  /// Constant name (simple *and* `Class.member`) to its initializer.
  final Map<String, ConstExpr> constants;

  /// flutter_gen class name to its members.
  final Map<String, Map<String, ConstExpr>> genClasses;

  /// Identifiers and dotted chains referenced in code, with where they appear.
  final Map<String, List<Occurrence>> symbolUses;

  final List<PendingParameterRef> pendingParameters;

  /// Function/constructor name to the argument lists it was called with, used
  /// to satisfy [pendingParameters] from call sites.
  final Map<String, List<List<ConstExpr>>> invocationArguments;

  /// Every string literal in the project — used to decide whether a font
  /// family name is mentioned anywhere.
  final Set<String> literalStrings;

  final int filesScanned;
}

/// Source directories that are scanned for asset references, relative to each
/// package root.
const List<String> kSourceDirectories = <String>[
  'lib',
  'test',
  'integration_test',
  'bin',
  'tool',
];

/// Platform directories grepped for asset paths (launch screens, `index.html`,
/// native splash configuration).
const List<String> kNativeDirectories = <String>[
  'android',
  'ios',
  'web',
  'macos',
  'windows',
  'linux',
];

const Set<String> _kNativeTextExtensions = <String>{
  '.xml',
  '.plist',
  '.html',
  '.json',
  '.gradle',
  '.kts',
  '.pbxproj',
  '.storyboard',
  '.xib',
  '.entitlements',
  '.properties',
  '.cfg',
  '.rc',
  '.swift',
  '.kt',
  '.java',
  '.m',
  '.h',
  '.cc',
  '.cpp',
  '.yaml',
  '.yml',
};

const Set<String> _kBundleLoadMethods = <String>{
  'loadString',
  'load',
  'loadBuffer',
  'loadStructuredData',
  'loadStructuredBinaryData',
};

/// Static factories whose first argument is an asset path.
const Set<String> _kAssetFactoryMethods = <String>{'asset'};

/// Constructors whose first argument is an asset path.
const Set<String> _kAssetProviderTypes = <String>{
  'AssetImage',
  'ExactAssetImage',
};

/// Walks Dart source with the analyzer and lowers every string-valued
/// expression into [ConstExpr].
///
/// Parsing is syntactic (`parseString`) rather than fully resolved: resolution
/// would require the target project to have completed `pub get` and would cost
/// orders of magnitude more time, while buying nothing for the patterns that
/// actually name assets.
class CodeScanner {
  const CodeScanner();

  CodeScanResult scan(
    String projectRoot,
    List<PackageContext> packages,
    AssetGuardConfig config,
  ) {
    final candidates = <CandidateExpression>[];
    final constants = <String, ConstExpr>{};
    final genClasses = <String, Map<String, ConstExpr>>{};
    final symbolUses = <String, List<Occurrence>>{};
    final pending = <PendingParameterRef>[];
    final invocations = <String, List<List<ConstExpr>>>{};
    final literals = <String>{};
    var filesScanned = 0;

    for (final PackageContext pkg in packages) {
      for (final String dirName in kSourceDirectories) {
        final dir = Directory(p.join(pkg.rootDirectory, dirName));
        if (!dir.existsSync()) continue;

        for (final File file in _dartFiles(dir)) {
          final relative = relativePosix(file.path, from: projectRoot);
          if (config.isIgnored(relative)) continue;

          final String source;
          try {
            source = file.readAsStringSync();
          } on FileSystemException {
            continue;
          }

          filesScanned++;
          final unit = parseString(
            content: source,
            path: file.path,
            throwIfDiagnostics: false,
          );

          // Generated asset classes are parsed for their getter -> path map
          // only. Treating their literals as references would mark every
          // generated asset used, defeating the whole check.
          if (_isGeneratedAssetFile(file.path, source)) {
            _collectGenClasses(unit.unit, genClasses);
            continue;
          }

          unit.unit.accept(_AssetAstVisitor(
            filePath: relative,
            packageName: pkg.name,
            lineInfo: unit.lineInfo,
            candidates: candidates,
            constants: constants,
            symbolUses: symbolUses,
            pending: pending,
            invocations: invocations,
            literals: literals,
          ));
        }
      }
    }

    return CodeScanResult(
      candidates: candidates,
      constants: constants,
      genClasses: genClasses,
      symbolUses: symbolUses,
      pendingParameters: pending,
      invocationArguments: invocations,
      literalStrings: literals,
      filesScanned: filesScanned,
    );
  }

  Iterable<File> _dartFiles(Directory dir) sync* {
    final List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(recursive: true, followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final FileSystemEntity entity in entries) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.dart')) continue;
      final segments = p.split(entity.path);
      if (segments.any((String s) => kAlwaysSkippedDirectories.contains(s))) {
        continue;
      }
      yield entity;
    }
  }

  bool _isGeneratedAssetFile(String path, String source) {
    final name = p.basename(path);
    return name.endsWith('.gen.dart') ||
        source.contains('FlutterGen') ||
        source.contains('package:flutter_gen');
  }

  void _collectGenClasses(
    CompilationUnit unit,
    Map<String, Map<String, ConstExpr>> out,
  ) {
    for (final CompilationUnitMember declaration in unit.declarations) {
      if (declaration is! ClassDeclaration) continue;
      final members = <String, ConstExpr>{};

      for (final ClassMember member in declaration.members) {
        if (member is MethodDeclaration && member.isGetter) {
          final expr = _genBodyExpr(member.body);
          if (expr != null) members[member.name.lexeme] = expr;
        } else if (member is FieldDeclaration) {
          // The declared type is the most reliable signal for a nested
          // accessor: `static const $AssetsImagesGen images = ...`.
          final NamedType? declaredType = member.fields.type is NamedType
              ? member.fields.type! as NamedType
              : null;

          for (final VariableDeclaration variable in member.fields.variables) {
            final initializer = variable.initializer;
            final expr =
                initializer == null ? null : _genValueExpr(initializer);
            if (expr != null) {
              members[variable.name.lexeme] = expr;
            } else if (declaredType != null) {
              members[variable.name.lexeme] =
                  ClassRefExpr(declaredType.name2.lexeme);
            }
          }
        }
      }

      if (members.isEmpty) continue;

      // Merge rather than overwrite. In a modular project every package
      // generates its own `class Assets`, so keying by class name alone would
      // let the last package parsed erase all the others. First definition of
      // a member wins; the resolved path is package-relative and matched
      // across every package afterwards, so a genuine clash resolves toward
      // "used" rather than silently reporting a live asset as unused.
      final target =
          out.putIfAbsent(declaration.name.lexeme, () => <String, ConstExpr>{});
      for (final MapEntry<String, ConstExpr> entry in members.entries) {
        target.putIfAbsent(entry.key, () => entry.value);
      }
    }
  }

  ConstExpr? _genBodyExpr(FunctionBody body) {
    if (body is ExpressionFunctionBody) return _genValueExpr(body.expression);
    if (body is BlockFunctionBody) {
      for (final Statement statement in body.block.statements) {
        if (statement is ReturnStatement && statement.expression != null) {
          return _genValueExpr(statement.expression!);
        }
      }
    }
    return null;
  }

  /// Lowers the right-hand side of a generated member.
  ///
  /// `AssetGenImage('assets/x.png')` yields the path; `$AssetsImagesGen()`
  /// yields a class reference the resolver follows to the next chain segment.
  ConstExpr? _genValueExpr(Expression expression) {
    if (expression is SimpleStringLiteral) return LiteralExpr(expression.value);

    if (expression is InstanceCreationExpression) {
      for (final Expression argument in expression.argumentList.arguments) {
        if (argument is SimpleStringLiteral) return LiteralExpr(argument.value);
      }
      return ClassRefExpr(expression.constructorName.type.name2.lexeme);
    }

    if (expression is MethodInvocation) {
      for (final Expression argument in expression.argumentList.arguments) {
        if (argument is SimpleStringLiteral) return LiteralExpr(argument.value);
      }
      // Without type resolution the parser reports `$AssetsImagesGen()` as a
      // method invocation, since it cannot know the identifier names a class.
      // Only an explicit `const`/`new` produces InstanceCreationExpression, so
      // flutter_gen's root `Assets` class reaches us in this form.
      final name = expression.methodName.name;
      if (_looksLikeTypeName(name)) return ClassRefExpr(name);
    }
    return null;
  }

  /// Constructor-style naming: flutter_gen emits `$AssetsImagesGen`, and Dart
  /// types are conventionally capitalised.
  bool _looksLikeTypeName(String name) {
    if (name.isEmpty) return false;
    if (name.startsWith(r'$')) return true;
    final first = name[0];
    return first.toUpperCase() == first && first.toLowerCase() != first;
  }
}

class _AssetAstVisitor extends RecursiveAstVisitor<void> {
  _AssetAstVisitor({
    required this.filePath,
    required this.packageName,
    required this.lineInfo,
    required this.candidates,
    required this.constants,
    required this.symbolUses,
    required this.pending,
    required this.invocations,
    required this.literals,
  });

  final String filePath;
  final String packageName;
  final LineInfo lineInfo;
  final List<CandidateExpression> candidates;
  final Map<String, ConstExpr> constants;
  final Map<String, List<Occurrence>> symbolUses;
  final List<PendingParameterRef> pending;
  final Map<String, List<List<ConstExpr>>> invocations;
  final Set<String> literals;

  /// Non-zero while inside an initializer we already captured as a constant.
  /// Prevents `static const logo = 'assets/logo.png'` from counting as a
  /// reference to itself — the whole point of the constant test.
  int _inCapturedInitializer = 0;

  /// Offsets of expressions already captured as an asset-load argument.
  ///
  /// `Image.asset('assets/x/$y.png')` is visited twice — once as the call's
  /// argument, then again when recursion reaches the interpolation itself.
  /// Without this the same reference is reported twice.
  final Set<int> _capturedOffsets = <int>{};

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    literals.add(node.value);
    if (node.parent is! AdjacentStrings) {
      _addCandidate(LiteralExpr(node.value), node, ReferenceKind.literal);
    }
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    _addCandidate(
      ConcatExpr(node.strings.map(_toConstExpr).toList(growable: false)),
      node,
      ReferenceKind.adjacentStrings,
    );
    super.visitAdjacentStrings(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _addCandidate(_interpolationExpr(node), node, ReferenceKind.literal);
    super.visitStringInterpolation(node);
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final Expression? initializer = node.initializer;
    if (initializer == null) {
      super.visitVariableDeclaration(node);
      return;
    }

    final expr = _toConstExpr(initializer);
    if (expr is UnknownExpr) {
      super.visitVariableDeclaration(node);
      return;
    }

    final name = node.name.lexeme;
    final owner = _enclosingTypeName(node);
    constants[name] = expr;
    if (owner != null) constants['$owner.$name'] = expr;

    _inCapturedInitializer++;
    super.visitVariableDeclaration(node);
    _inCapturedInitializer--;
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    _recordUse('${node.prefix.name}.${node.identifier.name}', node);
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final chain = _dottedName(node);
    if (chain != null) _recordUse(chain, node);
    super.visitPropertyAccess(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final parent = node.parent;
    // Qualified access, declarations and argument labels are handled elsewhere
    // or aren't uses at all.
    final isQualifiedPart = parent is PrefixedIdentifier ||
        parent is PropertyAccess ||
        parent is Label ||
        parent is NamedExpression ||
        (parent is MethodInvocation && parent.methodName == node) ||
        parent is VariableDeclaration ||
        parent is FormalParameter ||
        parent is ConstructorDeclaration ||
        parent is MethodDeclaration ||
        parent is ClassDeclaration;
    if (!isQualifiedPart) _recordUse(node.name, node);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    invocations.putIfAbsent(name, () => <List<ConstExpr>>[]).add(
        node.argumentList.arguments.map(_toConstExpr).toList(growable: false));

    if (_isBundleLoad(node) || _kAssetFactoryMethods.contains(name)) {
      _handleLoadArgument(node.argumentList, node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name2.lexeme;
    invocations.putIfAbsent(typeName, () => <List<ConstExpr>>[]).add(
        node.argumentList.arguments.map(_toConstExpr).toList(growable: false));

    if (_kAssetProviderTypes.contains(typeName)) {
      _handleLoadArgument(node.argumentList, node);
    }
    super.visitInstanceCreationExpression(node);
  }

  bool _isBundleLoad(MethodInvocation node) {
    if (!_kBundleLoadMethods.contains(node.methodName.name)) return false;
    final target = node.target;
    if (target == null) return false;
    final source = target.toSource().toLowerCase();
    return source.contains('bundle');
  }

  /// The path argument of an asset load gets special treatment: if it can't be
  /// pinned to a literal or a directory prefix, it becomes a reported
  /// unresolvable reference rather than being silently dropped.
  void _handleLoadArgument(ArgumentList arguments, AstNode node) {
    final positional = arguments.arguments
        .where((Expression a) => a is! NamedExpression)
        .toList(growable: false);
    if (positional.isEmpty) return;

    final Expression first = positional.first;
    final source = _truncate(node.toSource());
    _capturedOffsets.add(first.offset);
    final explicitPackage = _packageArgument(arguments);

    if (first is SimpleIdentifier) {
      final parameterIndex = _enclosingParameterIndex(node, first.name);
      if (parameterIndex != null) {
        pending.add(PendingParameterRef(
          functionName: _enclosingFunctionName(node) ?? '',
          parameterName: first.name,
          argumentIndex: parameterIndex,
          occurrence: _at(node, source),
          packageName: packageName,
          source: source,
        ));
        return;
      }
    }

    candidates.add(CandidateExpression(
      expr: _toConstExpr(first),
      occurrence: _at(node, source),
      packageName: packageName,
      kind: ReferenceKind.literal,
      isLoadArgument: true,
      source: source,
      explicitPackage: explicitPackage,
    ));
  }

  /// The literal value of a `package:` named argument, if present.
  String? _packageArgument(ArgumentList arguments) {
    for (final Expression argument in arguments.arguments) {
      if (argument is! NamedExpression) continue;
      if (argument.name.label.name != 'package') continue;
      final Expression value = argument.expression;
      if (value is SimpleStringLiteral) return value.value;
    }
    return null;
  }

  int? _enclosingParameterIndex(AstNode node, String name) {
    final parameters = _enclosingParameters(node);
    if (parameters == null) return null;
    for (var i = 0; i < parameters.length; i++) {
      if (parameters[i].name?.lexeme == name) return i;
    }
    return null;
  }

  List<FormalParameter>? _enclosingParameters(AstNode node) {
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method != null) return method.parameters?.parameters;
    final function = node.thisOrAncestorOfType<FunctionDeclaration>();
    if (function != null) {
      return function.functionExpression.parameters?.parameters;
    }
    return null;
  }

  String? _enclosingFunctionName(AstNode node) {
    final method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method != null) return method.name.lexeme;
    final function = node.thisOrAncestorOfType<FunctionDeclaration>();
    if (function != null) return function.name.lexeme;
    return null;
  }

  String? _enclosingTypeName(AstNode node) {
    final klass = node.thisOrAncestorOfType<ClassDeclaration>();
    if (klass != null) return klass.name.lexeme;
    final mixin = node.thisOrAncestorOfType<MixinDeclaration>();
    if (mixin != null) return mixin.name.lexeme;
    final extension = node.thisOrAncestorOfType<ExtensionDeclaration>();
    if (extension != null) return extension.name?.lexeme;
    final enumeration = node.thisOrAncestorOfType<EnumDeclaration>();
    if (enumeration != null) return enumeration.name.lexeme;
    return null;
  }

  void _addCandidate(ConstExpr expr, AstNode node, ReferenceKind kind) {
    if (_inCapturedInitializer > 0) return;
    if (_capturedOffsets.contains(node.offset)) return;
    candidates.add(CandidateExpression(
      expr: expr,
      occurrence: _at(node, _truncate(node.toSource())),
      packageName: packageName,
      kind: kind,
    ));
  }

  void _recordUse(String name, AstNode node) {
    final list = symbolUses.putIfAbsent(name, () => <Occurrence>[]);
    // Cap per symbol: reports only ever show a handful, and a hot constant can
    // otherwise accumulate thousands of identical entries.
    if (list.length < 20) list.add(_at(node, _truncate(node.toSource())));
  }

  Occurrence _at(AstNode node, String snippet) {
    final location = lineInfo.getLocation(node.offset);
    return Occurrence(
      file: filePath,
      line: location.lineNumber,
      column: location.columnNumber,
      snippet: snippet,
    );
  }

  InterpolationExpr _interpolationExpr(StringInterpolation node) {
    final parts = <ConstExpr?>[];
    for (final InterpolationElement element in node.elements) {
      if (element is InterpolationString) {
        parts.add(LiteralExpr(element.value));
      } else if (element is InterpolationExpression) {
        final inner = _toConstExpr(element.expression);
        parts.add(inner is UnknownExpr ? null : inner);
      }
    }
    return InterpolationExpr(parts);
  }

  ConstExpr _toConstExpr(Expression expression) {
    if (expression is SimpleStringLiteral) return LiteralExpr(expression.value);
    if (expression is AdjacentStrings) {
      return ConcatExpr(
          expression.strings.map(_toConstExpr).toList(growable: false));
    }
    if (expression is StringInterpolation) {
      return _interpolationExpr(expression);
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '+') {
      return ConcatExpr(<ConstExpr>[
        _toConstExpr(expression.leftOperand),
        _toConstExpr(expression.rightOperand),
      ]);
    }
    final dotted = _dottedName(expression);
    if (dotted != null) return RefExpr(dotted);
    return UnknownExpr(_truncate(expression.toSource()));
  }

  String? _dottedName(Expression expression) {
    if (expression is SimpleIdentifier) return expression.name;
    if (expression is PrefixedIdentifier) {
      return '${expression.prefix.name}.${expression.identifier.name}';
    }
    if (expression is PropertyAccess) {
      final Expression? target = expression.target;
      if (target == null) return null;
      final prefix = _dottedName(target);
      return prefix == null ? null : '$prefix.${expression.propertyName.name}';
    }
    return null;
  }
}

String _truncate(String value, [int max = 120]) {
  final single = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  return single.length <= max ? single : '${single.substring(0, max - 1)}…';
}

/// Greps platform folders for asset paths.
///
/// Native config references assets as plain strings in XML, plists and HTML,
/// so there is no AST to walk — but missing them would wrongly flag launch
/// images and splash screens as unused.
class NativeScanner {
  const NativeScanner();

  /// Token that looks like a file path or filename with an extension.
  static final RegExp _pathToken = RegExp(r'[\w./\\-]+\.\w{2,5}');

  List<AssetReference> scan(
    String projectRoot,
    List<PackageContext> packages,
    List<AssetFile> assets,
    AssetGuardConfig config,
  ) {
    if (assets.isEmpty) return const <AssetReference>[];

    final byPackagePath = <String, AssetFile>{};
    final byBasename = <String, List<AssetFile>>{};
    for (final AssetFile asset in assets) {
      byPackagePath.putIfAbsent(asset.packagePath, () => asset);
      byBasename.putIfAbsent(asset.basename, () => <AssetFile>[]).add(asset);
    }

    final references = <AssetReference>[];
    final seen = <String>{};

    for (final PackageContext pkg in packages) {
      for (final String dirName in kNativeDirectories) {
        final dir = Directory(p.join(pkg.rootDirectory, dirName));
        if (!dir.existsSync()) continue;

        final List<FileSystemEntity> entries;
        try {
          entries = dir.listSync(recursive: true, followLinks: false);
        } on FileSystemException {
          continue;
        }

        for (final FileSystemEntity entity in entries) {
          if (entity is! File) continue;
          final extension = p.extension(entity.path).toLowerCase();
          if (!_kNativeTextExtensions.contains(extension)) continue;

          final segments = p.split(entity.path);
          if (segments
              .any((String s) => kAlwaysSkippedDirectories.contains(s))) {
            continue;
          }

          final String content;
          try {
            if (entity.lengthSync() > 2 * 1024 * 1024) continue;
            content = entity.readAsStringSync();
          } on Object {
            continue;
          }

          final origin = relativePosix(entity.path, from: projectRoot);
          for (final Match match in _pathToken.allMatches(content)) {
            final token = normalizeAssetPath(match[0]!);

            final AssetFile? direct = byPackagePath[token];
            final candidates = direct != null
                ? <AssetFile>[direct]
                // Native config often names just the file, so fall back to
                // basename. Over-matching here only ever marks an asset used,
                // which is the safe direction.
                : byBasename[p.posix.basename(token)] ?? const <AssetFile>[];

            for (final AssetFile asset in candidates) {
              if (!seen.add('${asset.path}|$origin')) continue;
              references.add(AssetReference(
                value: asset.packagePath,
                kind: ReferenceKind.native,
                occurrence: Occurrence(file: origin, snippet: match[0]),
              ));
            }
          }
        }
      }
    }
    return references;
  }
}
