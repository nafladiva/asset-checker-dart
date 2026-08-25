import '../models/finding.dart';
import '../models/project_context.dart';

/// Every audit implements this. The runner discovers checks from a list and
/// filters by [id], so adding a check means adding one file plus one list
/// entry — no changes to the runner's logic.
abstract class Check {
  /// Stable identifier matching a `--check` value.
  String get id;

  /// Human-readable section heading used by the reporters.
  String get name;

  Future<List<Finding>> run(ProjectContext ctx);
}

/// The `--check` values the CLI accepts.
abstract final class CheckId {
  static const all = 'all';
  static const unused = 'unused';
  static const dupes = 'dupes';
  static const similar = 'similar';
  static const missing = 'missing';
  static const hygiene = 'hygiene';

  static const values = <String>[all, unused, dupes, similar, missing, hygiene];
}
