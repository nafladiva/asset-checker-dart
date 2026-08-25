import '../config.dart';
import '../hashing/content_cache.dart';
import 'asset.dart';
import 'finding.dart';
import 'reference.dart';

/// Everything the checks are allowed to see. Built once by the runner, then
/// passed to every [Check] — checks never touch the filesystem directly except
/// through [content].
class ProjectContext {
  ProjectContext({
    required this.config,
    required this.packages,
    required this.assets,
    required this.references,
    required this.dynamicReferences,
    required this.unresolvableReferences,
    required this.fontFamilyMentions,
    required this.usage,
    required this.occurrencesByAsset,
    required this.missingDeclarations,
    required this.emptyDirectories,
    required this.declarations,
    required this.unmatchedReferences,
    required this.content,
  }) : assetByPath = <String, AssetFile>{
          for (final AssetFile asset in assets) asset.path: asset,
        };

  final AssetGuardConfig config;
  final List<PackageContext> packages;

  /// Every candidate asset found on disk, excluding ignored paths.
  final List<AssetFile> assets;

  final Map<String, AssetFile> assetByPath;

  /// Concrete references resolved to a path string.
  final List<AssetReference> references;

  /// Interpolations pinned to a directory prefix.
  final List<DynamicReference> dynamicReferences;

  /// Bundle loads that could not be pinned anywhere.
  final List<UnresolvableReference> unresolvableReferences;

  /// Every string seen in a `fontFamily:` position or plain literal, used to
  /// decide whether a declared font family is referenced anywhere.
  final Set<String> fontFamilyMentions;

  final Map<String, UsageStatus> usage;

  /// Where each used asset was referenced from.
  final Map<String, List<Occurrence>> occurrencesByAsset;

  /// Pubspec entries whose target doesn't exist on disk.
  final List<AssetDeclaration> missingDeclarations;

  /// Directory entries that exist but hold no files.
  final List<AssetDeclaration> emptyDirectories;

  /// Every declaration across the workspace, including synthesized entries for
  /// font files so both are checked for existence the same way.
  final List<AssetDeclaration> declarations;

  /// Asset-looking strings in code that match no file on disk.
  final List<AssetReference> unmatchedReferences;

  final ContentCache content;

  String get root => config.projectRoot;

  /// Whether any package in the workspace ships an asset bundle.
  ///
  /// A pure-Dart workspace has no bundle at all, so "referenced but not
  /// declared" is not a meaningful thing to say about it.
  bool get hasFlutterPackage =>
      packages.any((PackageContext pkg) => pkg.isFlutterPackage);

  UsageStatus usageOf(String assetPath) =>
      usage[assetPath] ?? UsageStatus.unused;

  /// Resolution variants belonging to [assetPath].
  Iterable<AssetFile> variantsOf(String assetPath) =>
      assets.where((AssetFile a) => a.variantOfPath == assetPath);

  /// All declarations across every package in the workspace.
  Iterable<AssetDeclaration> get allDeclarations =>
      packages.expand((PackageContext pkg) => pkg.declarations);

  Iterable<FontFamilyDeclaration> get allFonts =>
      packages.expand((PackageContext pkg) => pkg.fonts);
}
