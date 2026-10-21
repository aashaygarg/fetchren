import 'dart:async';
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';
import 'legacy_v1_migrator.dart';
import 'sqlite_workspace_repository.dart';

/// File name of the workspace database inside the app data directory.
const String workspaceDatabaseFileName = 'workspace.sqlite';

/// The repository and default location the app works with.
class LocalWorkspace {
  LocalWorkspace._({
    required this.repository,
    required this.collection,
    required this.isPersistent,
    required this.migration,
    this.openError,
    this._close,
  });

  final WorkspaceRepository repository;

  /// Collection whose requests the current UI lists.
  final Collection collection;

  /// False when the database could not be opened; changes are kept in memory
  /// only and the database file is left untouched.
  final bool isPersistent;
  final LegacyMigrationResult migration;

  /// Why the database could not be opened, for display.
  final String? openError;
  final Future<void> Function()? _close;

  Future<void> close() async => _close?.call();
}

/// Opens `workspace.sqlite` in [directory] and imports `requests.json` once.
///
/// Never throws for storage problems: a database that cannot be opened (for
/// example, created by a newer FetchRen, or not a database) yields an
/// in-memory, non-persistent workspace and leaves the file untouched.
Future<LocalWorkspace> openLocalWorkspace(
  String directory, {
  DateTime Function() clock = DateTime.now,
  FutureOr<void> Function(MigrationStage stage)? onMigrationStage,
}) async {
  await Directory(directory).create(recursive: true);
  final SqliteWorkspaceRepository repository;
  try {
    repository = SqliteWorkspaceRepository.open(
      '$directory/$workspaceDatabaseFileName',
    );
  } on UnsupportedSchemaVersionException catch (e) {
    return _inMemory(clock, e.toString());
  } on SqliteException catch (e) {
    return _inMemory(
      clock,
      'The saved-requests database could not be opened (${e.message}). '
      'It has not been modified.',
    );
  }

  try {
    final collection = await ensureDefaultCollection(repository, now: clock());
    final migration = await migrateLegacyV1(
      repository: repository,
      legacyPath: '$directory/$legacyV1FileName',
      target: collection,
      clock: clock,
      onStage: onMigrationStage,
    );
    return LocalWorkspace._(
      repository: repository,
      collection: collection,
      isPersistent: true,
      migration: migration,
      close: repository.close,
    );
  } catch (_) {
    await repository.close();
    rethrow;
  }
}

Future<LocalWorkspace> _inMemory(
  DateTime Function() clock,
  String error,
) async {
  final repository = InMemoryWorkspaceRepository();
  return LocalWorkspace._(
    repository: repository,
    collection: await ensureDefaultCollection(repository, now: clock()),
    isPersistent: false,
    migration: const LegacyMigrationResult(LegacyMigrationOutcome.notNeeded),
    openError: error,
  );
}
