import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// A forward-only schema step. [version] is the `user_version` after it runs.
class SchemaMigration {
  const SchemaMigration(this.version, this.apply);

  final int version;
  final void Function(Database db) apply;
}

/// The database was written by a newer FetchRen; it is left untouched.
class UnsupportedSchemaVersionException implements Exception {
  const UnsupportedSchemaVersionException(this.found, this.supported);

  final int found;
  final int supported;

  @override
  String toString() =>
      'This data was created by a newer version of FetchRen (schema $found; '
      'this version supports up to $supported). Update FetchRen to open it.';
}

const List<SchemaMigration> workspaceMigrations = [
  SchemaMigration(1, _createV1),
  SchemaMigration(2, _addRequestListIndex),
];

int get latestSchemaVersion => workspaceMigrations.last.version;

// requestSummaries: live requests under a parent, newest first, read a page
// at a time without sorting the whole collection.
void _addRequestListIndex(Database db) {
  db.execute('''
    CREATE INDEX nodes_request_list
      ON nodes (parent_id, updated_at DESC, id)
      WHERE kind = 'request' AND deleted_at IS NULL
  ''');
}

void _createV1(Database db) {
  db.execute('''
    CREATE TABLE nodes (
      id            TEXT PRIMARY KEY,
      kind          TEXT NOT NULL
                    CHECK (kind IN ('workspace','collection','folder','request')),
      workspace_id  TEXT NOT NULL,
      collection_id TEXT,
      parent_id     TEXT REFERENCES nodes(id),
      name          TEXT NOT NULL,
      sort_key      TEXT NOT NULL,
      version       INTEGER NOT NULL CHECK (version >= 1),
      created_at    INTEGER NOT NULL,
      updated_at    INTEGER NOT NULL,
      deleted_at    INTEGER
    ) STRICT;
    -- children(parentId): WHERE parent_id = ? ORDER BY sort_key, id
    CREATE INDEX nodes_children ON nodes (parent_id, sort_key, id);
    -- workspaces(): WHERE kind = 'workspace' ORDER BY sort_key, id
    CREATE INDEX nodes_workspaces ON nodes (sort_key, id)
      WHERE kind = 'workspace';

    CREATE TABLE request_templates (
      request_id   TEXT PRIMARY KEY REFERENCES nodes(id),
      method       TEXT NOT NULL,
      url          TEXT NOT NULL,
      headers_json TEXT NOT NULL,
      body         TEXT NOT NULL
    ) STRICT;

    CREATE TABLE app_meta (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) STRICT;
  ''');
}

/// Opens (creating if needed) the database at [path] and applies migrations.
///
/// Throws [UnsupportedSchemaVersionException] for a newer schema, and
/// [SqliteException] if the file is not a usable database. In both cases the
/// file is not modified.
Database openWorkspaceDatabase(
  String path, {
  List<SchemaMigration> migrations = workspaceMigrations,
}) {
  final db = sqlite3.open(path);
  try {
    // Startup only: wait for another process that is creating or migrating
    // the same file. Must precede the WAL switch, which also takes a lock.
    configureConnection(db, busyTimeout: const Duration(seconds: 5));
    migrateSchema(db, migrations);
    db.execute('PRAGMA busy_timeout = 0');
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

void configureConnection(Database db, {required Duration busyTimeout}) {
  db.execute('PRAGMA busy_timeout = ${busyTimeout.inMilliseconds}');
  db.execute('PRAGMA foreign_keys = ON');
  // WAL lets readers see the last committed state while a write is open.
  // While another process is creating the same file, the switch can fail
  // with SQLITE_BUSY without consulting busy_timeout, so it is retried here
  // within the same limit.
  final deadline = DateTime.now().add(busyTimeout);
  while (true) {
    try {
      db.execute('PRAGMA journal_mode = WAL');
      break;
    } on SqliteException catch (e) {
      if (e.resultCode != SqlError.SQLITE_BUSY ||
          !DateTime.now().isBefore(deadline)) {
        rethrow;
      }
      sleep(const Duration(milliseconds: 10));
    }
  }
  db.execute('PRAGMA synchronous = FULL');
}

/// Applies each pending migration in its own transaction.
void migrateSchema(Database db, List<SchemaMigration> migrations) {
  final supported = migrations.isEmpty ? 0 : migrations.last.version;
  final current = db.userVersion;
  if (current > supported) {
    throw UnsupportedSchemaVersionException(current, supported);
  }
  for (final migration in migrations) {
    if (migration.version <= db.userVersion) continue;
    db.execute('BEGIN IMMEDIATE');
    try {
      // Another process may have migrated between our check and the lock.
      if (db.userVersion >= migration.version) {
        db.execute('COMMIT');
        continue;
      }
      migration.apply(db);
      db.userVersion = migration.version;
      db.execute('COMMIT');
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }
}
