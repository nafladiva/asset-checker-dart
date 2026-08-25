import 'package:path/path.dart' as p;

import 'code_scanner.dart';
import 'config.dart';
import 'models/asset.dart';
import 'models/const_expr.dart';
import 'models/finding.dart';
import 'models/reference.dart';
import 'util/paths.dart';

/// What the resolver produces: concrete references, dynamic ones, the
/// leftovers it could not pin down, and the resulting usage verdict per asset.
class ResolutionResult {
  const ResolutionResult({
    required this.references,
    required this.dynamicReferences,
    required this.unresolvableReferences,
    required this.usage,
    required this.occurrencesByAsset,
    required this.unmatchedReferences,
  });

  final List<AssetReference> references;
  final List<DynamicReference> dynamicReferences;
  final List<UnresolvableReference> unresolvableReferences;
  final Map<String, UsageStatus> usage;
  final Map<String, List<Occurrence>> occurrencesByAsset;
  final List<AssetReference> unmatchedReferences;
}

/// Turns raw scanner output into a usage verdict for every asset.
///
/// The governing rule is asymmetric: marking an asset used when it isn't costs
/// the user a missed cleanup, but marking it unused when it isn't can delete a
/// file the app needs at runtime. Every ambiguous case therefore resolves
/// toward "used" or "possibly used".
class ReferenceResolver {
  ReferenceResolver({
    required this.config,
    required this.packages,
    required this.assets,
    required this.scan,
    required this.nativeReferences,
  }) {
    _indexAssets();
    _buildFallbackGenMap();
  }

  final AssetGuardConfig config;
  final List<PackageContext> packages;
  final List<AssetFile> assets;
  final CodeScanResult scan;
  final List<AssetReference> nativeReferences;

  final Map<String, AssetFile> _byProjectPath = <String, AssetFile>{};
  final Map<String, List<AssetFile>> _byPackagePath =
      <String, List<AssetFile>>{};
  final Map<String, List<AssetFile>> _byPackageAndPath =
      <String, List<AssetFile>>{};

  /// Every directory that contains at least one asset, in both project- and
  /// package-relative form, plus all ancestors. Used to pin interpolations.
  final Set<String> _assetDirectories = <String>{};

  /// Convention-derived flutter_gen accessors, used when no generated file is
  /// available to parse.
  final Map<String, String> _fallbackGen = <String, String>{};

  final Map<String, ResolvedValue> _constantCache = <String, ResolvedValue>{};
  final Set<String> _resolving = <String>{};
  final Set<String> _genResolvedNames = <String>{};

  late final Map<String, UsageStatus> _usage = <String, UsageStatus>{
    for (final AssetFile asset in assets) asset.path: UsageStatus.unused,
  };
  final Map<String, List<Occurrence>> _occurrences =
      <String, List<Occurrence>>{};
  final List<AssetReference> _references = <AssetReference>[];
  final List<DynamicReference> _dynamic = <DynamicReference>[];
  final List<UnresolvableReference> _unresolvable = <UnresolvableReference>[];
  final List<AssetReference> _unmatched = <AssetReference>[];

  ResolutionResult resolve() {
    for (final CandidateExpression candidate in scan.candidates) {
      _handleCandidate(candidate);
    }

    _resolveSymbolUses();
    _resolvePendingParameters();

    for (final AssetReference reference in nativeReferences) {
      final matches = _match(reference.value, null);
      for (final AssetFile asset in matches) {
        _markUsed(asset, reference.occurrence);
      }
      _references.add(reference);
    }

    if (config.treatUnresolvableAsWildcard && _unresolvable.isNotEmpty) {
      for (final AssetFile asset in assets) {
        _markPossiblyUsed(asset, _unresolvable.first.occurrence);
      }
    }

    _propagateVariants();

    return ResolutionResult(
      references: _references,
      dynamicReferences: _dynamic,
      unresolvableReferences: _unresolvable,
      usage: _usage,
      occurrencesByAsset: _occurrences,
      unmatchedReferences: _unmatched,
    );
  }

  // ---------------------------------------------------------------- indexing

  void _indexAssets() {
    for (final AssetFile asset in assets) {
      _byProjectPath[asset.path] = asset;
      _byPackagePath
          .putIfAbsent(asset.packagePath, () => <AssetFile>[])
          .add(asset);
      _byPackageAndPath
          .putIfAbsent(
              '${asset.packageName}|${asset.packagePath}', () => <AssetFile>[])
          .add(asset);

      for (final String form in <String>[asset.path, asset.packagePath]) {
        var directory = p.posix.dirname(form);
        while (directory.isNotEmpty && directory != '.' && directory != '/') {
          _assetDirectories.add(directory);
          directory = p.posix.dirname(directory);
        }
      }
    }
  }

  /// Mirrors flutter_gen's naming so `Assets.images.logo` resolves even when
  /// the generated file isn't committed.
  void _buildFallbackGenMap() {
    for (final AssetFile asset in assets) {
      if (asset.isVariant) continue;
      final segments = p.posix.split(asset.packagePath);
      if (segments.isEmpty) continue;

      final withoutRoot =
          segments.first == 'assets' ? segments.sublist(1) : segments;

      for (final List<String> variant in <List<String>>[
        withoutRoot,
        segments
      ]) {
        if (variant.isEmpty) continue;
        final directories =
            variant.sublist(0, variant.length - 1).map(_camelCase);
        final filename = variant.last;
        final stem = p.posix.basenameWithoutExtension(filename);
        final extension = p.posix.extension(filename).replaceFirst('.', '');

        final prefix = <String>['Assets', ...directories];
        _fallbackGen['${prefix.join('.')}.${_camelCase(stem)}'] =
            asset.packagePath;
        // flutter_gen disambiguates same-stem files by appending the
        // extension, e.g. `logoPng` next to `logoSvg`.
        _fallbackGen[
                '${prefix.join('.')}.${_camelCase('${stem}_$extension')}'] =
            asset.packagePath;
      }
    }
  }

  String _camelCase(String raw) {
    final parts = raw
        .split(RegExp(r'[_\-\s.]+'))
        .where((String s) => s.isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) return raw;
    final buffer = StringBuffer(_lowerFirst(parts.first));
    for (var i = 1; i < parts.length; i++) {
      buffer.write(_upperFirst(parts[i]));
    }
    return buffer.toString();
  }

  String _lowerFirst(String s) =>
      s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

  String _upperFirst(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  // --------------------------------------------------------------- candidates

  void _handleCandidate(CandidateExpression candidate) {
    final resolved = _resolve(candidate.expr);

    if (resolved.isExact) {
      _recordExact(
        resolved.exact!,
        candidate.occurrence,
        candidate.packageName,
        candidate.kind,
        candidate.via,
        explicitPackage: candidate.explicitPackage,
      );
      return;
    }

    if (resolved.isPartial) {
      _recordDynamic(
        resolved.literalSegments,
        candidate.occurrence,
        candidate.via,
        candidate.source,
      );
      return;
    }

    // Unknown. Only matters when it's the path argument of a load: an
    // arbitrary expression elsewhere in the file tells us nothing.
    if (candidate.isLoadArgument) {
      _unresolvable.add(UnresolvableReference(
        expression: candidate.source ?? '<expression>',
        occurrence: candidate.occurrence,
        reason: 'The asset path is computed at runtime and could not be '
            'traced to any literal or directory.',
      ));
    }
  }

  void _resolveSymbolUses() {
    scan.symbolUses.forEach((String symbol, List<Occurrence> occurrences) {
      if (occurrences.isEmpty) return;
      final resolved = _resolveName(symbol);
      if (resolved.isUnknown) return;

      final kind = _genResolvedNames.contains(symbol)
          ? ReferenceKind.flutterGen
          : ReferenceKind.constant;

      for (final Occurrence occurrence in occurrences) {
        if (resolved.isExact) {
          _recordExact(resolved.exact!, occurrence, null, kind, symbol);
        } else if (resolved.isPartial) {
          _recordDynamic(resolved.literalSegments, occurrence, symbol, null);
        }
      }
    });
  }

  /// Bundle loads that take a parameter are resolved from call sites before
  /// being declared unresolvable — `_load('assets/config.json')` three files
  /// away is a perfectly ordinary way to write this.
  void _resolvePendingParameters() {
    for (final PendingParameterRef pending in scan.pendingParameters) {
      final callSites = scan.invocationArguments[pending.functionName];
      var satisfied = false;

      if (callSites != null) {
        for (final List<ConstExpr> arguments in callSites) {
          if (pending.argumentIndex >= arguments.length) continue;
          final resolved = _resolve(arguments[pending.argumentIndex]);
          if (resolved.isExact) {
            satisfied = true;
            _recordExact(
              resolved.exact!,
              pending.occurrence,
              pending.packageName,
              ReferenceKind.constant,
              '${pending.functionName}(${pending.parameterName})',
            );
          } else if (resolved.isPartial) {
            satisfied = true;
            _recordDynamic(
              resolved.literalSegments,
              pending.occurrence,
              '${pending.functionName}(${pending.parameterName})',
              pending.source,
            );
          }
        }
      }

      if (!satisfied) {
        _unresolvable.add(UnresolvableReference(
          expression: pending.source,
          occurrence: pending.occurrence,
          reason: '`${pending.parameterName}` is a parameter of '
              '`${pending.functionName}` and no call site passes a traceable '
              'value.',
        ));
      }
    }
  }

  // ---------------------------------------------------------------- recording

  void _recordExact(
    String value,
    Occurrence occurrence,
    String? fromPackage,
    ReferenceKind kind,
    String? via, {
    String? explicitPackage,
  }) {
    final matches =
        _match(value, fromPackage, explicitPackage: explicitPackage);
    final reference = AssetReference(
      value: value,
      kind: kind,
      occurrence: occurrence,
      via: via,
    );

    if (matches.isEmpty) {
      if (_looksLikeAssetPath(value)) {
        _references.add(reference);
        _unmatched.add(reference);
      }
      return;
    }

    _references.add(reference);
    for (final AssetFile asset in matches) {
      _markUsed(asset, occurrence);
    }
  }

  void _recordDynamic(
    List<String> segments,
    Occurrence occurrence,
    String? via,
    String? source,
  ) {
    final prefix = _longestMatchingDirectory(segments);

    if (prefix == null) {
      // No directory pinned it, but a literal segment may still name a file.
      var matchedByName = false;
      for (final String segment in segments) {
        final basename = p.posix.basename(normalizeAssetPath(segment));
        if (basename.isEmpty || !basename.contains('.')) continue;
        for (final AssetFile asset in assets) {
          if (asset.basename == basename) {
            matchedByName = true;
            if (config.treatDynamicAsUsed) _markPossiblyUsed(asset, occurrence);
          }
        }
      }
      if (!matchedByName) return;

      _dynamic.add(DynamicReference(
        prefix: '',
        rawSource: source ?? segments.join(r'${…}'),
        occurrence: occurrence,
        via: via,
      ));
      return;
    }

    final covered = _assetsUnder(prefix);
    if (config.treatDynamicAsUsed) {
      for (final AssetFile asset in covered) {
        _markPossiblyUsed(asset, occurrence);
      }
    }

    _dynamic.add(DynamicReference(
      prefix: prefix,
      rawSource: source ?? segments.join(r'${…}'),
      occurrence: occurrence,
      via: via,
    ));
  }

  /// Finds the most specific known asset directory named by any literal
  /// segment. Longest match wins so `assets/icons` beats `assets`.
  String? _longestMatchingDirectory(List<String> segments) {
    String? best;
    for (final String segment in segments) {
      final normalized = normalizeAssetPath(segment);
      if (normalized.isEmpty) continue;
      for (final String directory in _assetDirectories) {
        if (!normalized.contains(directory)) continue;
        if (best == null || directory.length > best.length) best = directory;
      }
    }
    return best;
  }

  /// Every asset at or below [directory], in either path form. Recursive on
  /// purpose: `'assets/icons/$name'` can reach nested files too.
  List<AssetFile> _assetsUnder(String directory) {
    final prefix = directory.endsWith('/') ? directory : '$directory/';
    return assets
        .where((AssetFile asset) =>
            asset.path.startsWith(prefix) ||
            asset.packagePath.startsWith(prefix))
        .toList(growable: false);
  }

  void _markUsed(AssetFile asset, Occurrence occurrence) {
    _usage[asset.path] = UsageStatus.used;
    _occurrences.putIfAbsent(asset.path, () => <Occurrence>[]).add(occurrence);
  }

  void _markPossiblyUsed(AssetFile asset, Occurrence occurrence) {
    if (_usage[asset.path] != UsageStatus.used) {
      _usage[asset.path] = UsageStatus.possiblyUsed;
    }
    _occurrences.putIfAbsent(asset.path, () => <Occurrence>[]).add(occurrence);
  }

  /// A referenced variant keeps its parent alive and vice versa, so neither is
  /// ever reported unused on its own.
  void _propagateVariants() {
    for (final AssetFile asset in assets) {
      final parent = asset.variantOfPath;
      if (parent == null) continue;

      final parentStatus = _usage[parent] ?? UsageStatus.unused;
      final own = _usage[asset.path] ?? UsageStatus.unused;
      final strongest = _strongest(parentStatus, own);

      _usage[asset.path] = strongest;
      if (_usage.containsKey(parent)) _usage[parent] = strongest;
    }
  }

  UsageStatus _strongest(UsageStatus a, UsageStatus b) {
    if (a == UsageStatus.used || b == UsageStatus.used) return UsageStatus.used;
    if (a == UsageStatus.possiblyUsed || b == UsageStatus.possiblyUsed) {
      return UsageStatus.possiblyUsed;
    }
    return UsageStatus.unused;
  }

  // ----------------------------------------------------------------- matching

  List<AssetFile> _match(
    String rawValue,
    String? fromPackage, {
    String? explicitPackage,
  }) {
    final value = normalizeAssetPath(rawValue);
    if (value.isEmpty) return const <AssetFile>[];

    final packageReference = parsePackageReference(value);
    if (packageReference != null) {
      return _byPackageAndPath[
              '${packageReference.package}|${packageReference.path}'] ??
          const <AssetFile>[];
    }

    // An explicit `package:` argument names the owning bundle, so it outranks
    // the package the calling file lives in. Without this, an app referencing
    // a shared package's asset resolves to its own same-named file instead.
    if (explicitPackage != null) {
      final owned = _byPackageAndPath['$explicitPackage|$value'];
      if (owned != null && owned.isNotEmpty) return owned;
    }

    if (fromPackage != null) {
      final own = _byPackageAndPath['$fromPackage|$value'];
      if (own != null && own.isNotEmpty) return own;
    }

    final byPackagePath = _byPackagePath[value];
    if (byPackagePath != null && byPackagePath.isNotEmpty) return byPackagePath;

    final byProject = _byProjectPath[value];
    if (byProject != null) return <AssetFile>[byProject];

    return const <AssetFile>[];
  }

  /// Filters out the vast majority of strings in a codebase that obviously
  /// aren't asset paths, so `undeclared reference` findings stay trustworthy.
  bool _looksLikeAssetPath(String value) {
    if (value.isEmpty || value.length > 300) return false;
    if (value.contains('://') || value.startsWith('package:')) return false;
    if (value.startsWith('/') || value.contains(r'$')) return false;
    if (!value.contains('/')) return false;
    // Glob patterns (`assets/**/*.json`) name a rule, not a file — they show up
    // in ignore lists and config, and are never a real asset path.
    if (value.contains('*') || value.contains('?')) return false;

    final extension = p.posix.extension(value).toLowerCase();
    if (extension.isEmpty || extension.length > 6) return false;
    if (const <String>{'.dart', '.yaml', '.yml', '.lock', '.md'}
        .contains(extension)) {
      return false;
    }

    // Anchor on a directory the project actually uses for assets, otherwise
    // any `foo/bar.txt` in a doc comment becomes a finding.
    final firstSegment = p.posix.split(value).first;
    return _assetDirectories.any((String d) =>
            d == firstSegment || d.startsWith('$firstSegment/')) ||
        firstSegment == 'assets' ||
        firstSegment == 'fonts';
  }

  // ---------------------------------------------------------------- resolving

  ResolvedValue _resolve(ConstExpr expr) {
    switch (expr) {
      case LiteralExpr(:final String value):
        return ResolvedValue.exact(value);
      case RefExpr(:final String name):
        return _resolveName(name);
      case ConcatExpr(:final List<ConstExpr> parts):
        return _resolveSequence(parts);
      case InterpolationExpr(:final List<ConstExpr?> parts):
        return _resolveSequence(parts);
      case ClassRefExpr():
        return const ResolvedValue.unknown();
      case UnknownExpr():
        return const ResolvedValue.unknown();
    }
  }

  ResolvedValue _resolveSequence(List<ConstExpr?> parts) {
    final segments = <String>[];
    final buffer = StringBuffer();
    var allExact = true;

    void flush() {
      if (buffer.isNotEmpty) {
        segments.add(buffer.toString());
        buffer.clear();
      }
    }

    for (final ConstExpr? part in parts) {
      if (part == null) {
        allExact = false;
        flush();
        continue;
      }
      final resolved = _resolve(part);
      if (resolved.isExact) {
        buffer.write(resolved.exact);
      } else {
        allExact = false;
        flush();
        segments.addAll(resolved.literalSegments);
      }
    }

    if (allExact) return ResolvedValue.exact(buffer.toString());
    flush();
    return segments.isEmpty
        ? const ResolvedValue.unknown()
        : ResolvedValue.partial(segments);
  }

  ResolvedValue _resolveName(String name) {
    final cached = _constantCache[name];
    if (cached != null) return cached;

    final generated = _resolveGenChain(name);
    if (generated != null) {
      _genResolvedNames.add(name);
      final value = ResolvedValue.exact(generated);
      _constantCache[name] = value;
      return value;
    }

    final expr = scan.constants[name];
    if (expr == null) return const ResolvedValue.unknown();

    // Guard against `const a = b; const b = a;` and similar cycles.
    if (!_resolving.add(name)) return const ResolvedValue.unknown();
    final resolved = _resolve(expr);
    _resolving.remove(name);

    _constantCache[name] = resolved;
    return resolved;
  }

  /// Walks a dotted accessor through the parsed generated classes, falling back
  /// to convention-derived names when no generated file was found.
  String? _resolveGenChain(String dotted) {
    final segments = dotted.split('.');
    if (segments.length < 2) return null;

    var currentClass = segments.first;
    if (scan.genClasses.containsKey(currentClass)) {
      for (var i = 1; i < segments.length; i++) {
        final members = scan.genClasses[currentClass];
        if (members == null) break;
        final ConstExpr? value = members[segments[i]];
        if (value == null) break;
        if (value is ClassRefExpr) {
          currentClass = value.className;
          continue;
        }
        if (value is LiteralExpr) return value.value;
        break;
      }
    }

    final direct = _fallbackGen[dotted];
    if (direct != null) return direct;

    // `Assets.icons.arrowBack.svg()` records the chain including the call
    // target; try successively shorter prefixes.
    for (var end = segments.length - 1; end >= 2; end--) {
      final candidate = _fallbackGen[segments.sublist(0, end).join('.')];
      if (candidate != null) return candidate;
    }
    return null;
  }
}
