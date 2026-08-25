import 'dart:io';

import 'package:path/path.dart' as p;

import 'config.dart';
import 'models/asset.dart';
import 'models/finding.dart';
import 'models/reference.dart';
import 'runner.dart';
import 'util/paths.dart';

/// What a delete pass did, or why it refused.
class DeleteOutcome {
  const DeleteOutcome({
    required this.deleted,
    required this.freedBytes,
    required this.pubspecEntriesRemoved,
    required this.directoriesRemoved,
    this.abortReason,
    this.dryRun = false,
  });

  final List<String> deleted;
  final int freedBytes;
  final List<String> pubspecEntriesRemoved;
  final List<String> directoriesRemoved;

  /// Non-null when nothing was deleted and why.
  final String? abortReason;

  final bool dryRun;

  bool get aborted => abortReason != null;
}

/// Deletes unused assets, with the safety rules that make the flag usable at
/// all: version control required, clean tree required, explicit confirmation,
/// and a hard refusal to touch anything that might be reachable dynamically.
class UnusedDeleter {
  UnusedDeleter({
    required this.config,
    IOSink? out,
    String? Function()? readLine,
  })  : _out = out ?? stdout,
        _readLine = readLine ?? stdin.readLineSync;

  final AssetGuardConfig config;
  final IOSink _out;
  final String? Function() _readLine;

  Future<DeleteOutcome> run(AuditResult result) async {
    final candidates = _candidates(result);

    if (candidates.isEmpty) {
      return const DeleteOutcome(
        deleted: <String>[],
        freedBytes: 0,
        pubspecEntriesRemoved: <String>[],
        directoriesRemoved: <String>[],
        abortReason: 'No unused assets to delete.',
      );
    }

    final totalBytes =
        candidates.fold<int>(0, (int sum, AssetFile a) => sum + a.sizeBytes);

    _out.writeln();
    _out.writeln('${candidates.length} unused asset(s), '
        '${humanBytes(totalBytes)}:');
    for (final AssetFile asset in candidates) {
      _out.writeln('  ${asset.path}  (${humanBytes(asset.sizeBytes)})');
    }

    if (config.dryRun) {
      _out.writeln();
      _out.writeln('Dry run — nothing deleted. '
          'Re-run with --delete-unused --no-dry-run to apply.');
      return DeleteOutcome(
        deleted:
            candidates.map((AssetFile a) => a.path).toList(growable: false),
        freedBytes: totalBytes,
        pubspecEntriesRemoved: const <String>[],
        directoriesRemoved: const <String>[],
        dryRun: true,
      );
    }

    final blocker = _versionControlBlocker();
    if (blocker != null) return _abort(blocker);

    if (result.context.unresolvableReferences.isNotEmpty && !config.assumeYes) {
      _out.writeln();
      _out.writeln('${result.context.unresolvableReferences.length} '
          'unresolvable dynamic reference(s) were found. Those calls can load '
          'assets this audit cannot see.');
    }

    if (!config.assumeYes && !_confirm()) {
      return _abort('Cancelled at the confirmation prompt.');
    }

    final deleted = <String>[];
    var freed = 0;
    for (final AssetFile asset in candidates) {
      try {
        File(asset.absolutePath).deleteSync();
        deleted.add(asset.path);
        freed += asset.sizeBytes;
      } on FileSystemException catch (e) {
        _out.writeln('  could not delete ${asset.path}: ${e.message}');
      }
    }

    final cleanup = _cleanUpEmptyDirectories(result);

    return DeleteOutcome(
      deleted: deleted,
      freedBytes: freed,
      pubspecEntriesRemoved: cleanup.entries,
      directoriesRemoved: cleanup.directories,
    );
  }

  /// Only assets the unused check actually reported, plus their resolution
  /// variants. Anything marked possibly-used is excluded by construction —
  /// the unused check never emits it.
  List<AssetFile> _candidates(AuditResult result) {
    final assets = <String, AssetFile>{};

    for (final Finding finding in result.findings) {
      if (finding.code != FindingCode.unusedAsset) continue;

      for (final String path in <String>[
        if (finding.path != null) finding.path!,
        ...finding.relatedPaths,
      ]) {
        final asset = result.context.assetByPath[path];
        if (asset == null) continue;
        if (result.context.usageOf(asset.path) != UsageStatus.unused) continue;
        assets[path] = asset;
      }
    }

    final sorted = assets.values.toList()
      ..sort((AssetFile a, AssetFile b) => a.path.compareTo(b.path));
    return sorted;
  }

  /// Deleting without a clean checkout means the user cannot undo a mistake.
  String? _versionControlBlocker() {
    final ProcessResult inside;
    try {
      inside = Process.runSync(
        'git',
        <String>['rev-parse', '--is-inside-work-tree'],
        workingDirectory: config.projectRoot,
      );
    } on ProcessException {
      return 'git is not available, so deletions could not be undone. '
          'Refusing to delete.';
    }

    if (inside.exitCode != 0) {
      return '${config.projectRoot} is not inside a git working tree. '
          'Refusing to delete files that could not be recovered.';
    }

    final status = Process.runSync(
      'git',
      <String>['status', '--porcelain'],
      workingDirectory: config.projectRoot,
    );
    if (status.exitCode != 0) {
      return 'Could not read git status. Refusing to delete.';
    }
    if (status.stdout.toString().trim().isNotEmpty) {
      return 'The working tree has uncommitted changes. Commit or stash them '
          'first so the deletion is reviewable on its own.';
    }
    return null;
  }

  bool _confirm() {
    _out.writeln();
    _out.write('Delete these files permanently? Type "yes" to continue: ');
    final answer = _readLine()?.trim().toLowerCase();
    return answer == 'yes';
  }

  DeleteOutcome _abort(String reason) {
    _out.writeln();
    _out.writeln(reason);
    return DeleteOutcome(
      deleted: const <String>[],
      freedBytes: 0,
      pubspecEntriesRemoved: const <String>[],
      directoriesRemoved: const <String>[],
      abortReason: reason,
    );
  }

  /// Removes directories emptied by the deletion, and the pubspec entries that
  /// pointed at them — a stale `assets/legacy/` entry is a build error.
  ({List<String> entries, List<String> directories}) _cleanUpEmptyDirectories(
    AuditResult result,
  ) {
    final removedEntries = <String>[];
    final removedDirectories = <String>[];

    for (final AssetDeclaration declaration in result.context.declarations) {
      if (!declaration.isDirectory) continue;

      final absolute =
          p.normalize(p.join(config.projectRoot, declaration.directoryPath));
      final directory = Directory(absolute);
      if (!directory.existsSync()) continue;

      final hasFiles = directory
          .listSync(recursive: true, followLinks: false)
          .any((FileSystemEntity e) =>
              e is File && !p.basename(e.path).startsWith('.'));
      if (hasFiles) continue;

      if (_removePubspecEntry(declaration)) {
        removedEntries
            .add('${declaration.origin.file}: ${declaration.rawEntry}');
      }

      try {
        directory.deleteSync(recursive: true);
        removedDirectories.add(declaration.directoryPath);
      } on FileSystemException {
        // Leaving an empty directory behind is harmless.
      }
    }

    return (entries: removedEntries, directories: removedDirectories);
  }

  /// Line-based edit so comments and formatting elsewhere in the pubspec
  /// survive. Only touches a line that still looks like the entry we parsed.
  bool _removePubspecEntry(AssetDeclaration declaration) {
    final line = declaration.origin.line;
    if (line == null) return false;

    final file = File(p.join(config.projectRoot, declaration.origin.file));
    if (!file.existsSync()) return false;

    final lines = file.readAsLinesSync();
    final index = line - 1;
    if (index < 0 || index >= lines.length) return false;

    final trimmed = lines[index].trim();
    if (!trimmed.startsWith('-') || !trimmed.contains(declaration.rawEntry)) {
      _out.writeln('  left ${declaration.origin.file}:$line alone — it no '
          'longer looks like `- ${declaration.rawEntry}`.');
      return false;
    }

    lines.removeAt(index);
    file.writeAsStringSync('${lines.join('\n')}\n');
    return true;
  }
}
