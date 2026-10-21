import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';

import 'sqlite_workspace_repository.dart';

/// `app_meta` key holding the [LegacyMigrationMarker] as JSON.
const String legacyMigrationMarkerKey = 'migration.legacy_v1';

/// Name of the schema-v1 file inside the app data directory.
const String legacyV1FileName = 'requests.json';

enum LegacyMigrationState { inProgress, completed, failed, skipped }

/// Durable record of the schema-v1 migration, stored in the database.
class LegacyMigrationMarker {
  const LegacyMigrationMarker({
    required this.state,
    required this.attempts,
    required this.updatedAt,
    required this.source,
    this.imported = 0,
    this.warnings = const [],
    this.errors = const [],
    this.archivedTo,
  });

  factory LegacyMigrationMarker.fromJson(Map<String, Object?> json) =>
      LegacyMigrationMarker(
        state: LegacyMigrationState.values.byName(json['state']! as String),
        attempts: json['attempts']! as int,
        updatedAt: DateTime.parse(json['updatedAt']! as String),
        source: json['source']! as String,
        imported: json['imported'] as int? ?? 0,
        warnings: [...?(json['warnings'] as List?)?.cast<String>()],
        errors: [...?(json['errors'] as List?)?.cast<String>()],
        archivedTo: json['archivedTo'] as String?,
      );

  final LegacyMigrationState state;
  final int attempts;
  final DateTime updatedAt;
  final String source;
  final int imported;
  final List<String> warnings;
  final List<String> errors;
  final String? archivedTo;

  Map<String, Object?> toJson() => {
    'state': state.name,
    'attempts': attempts,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'source': source,
    'imported': imported,
    'warnings': warnings,
    'errors': errors,
    'archivedTo': archivedTo,
  };
}

/// What happened during this startup.
enum LegacyMigrationOutcome {
  /// No schema-v1 file and no earlier attempt.
  notNeeded,

  /// Records are in the database (now or on an earlier startup).
  completed,

  /// Nothing was imported; the original file is untouched.
  failed,

  /// An earlier attempt failed and the original file has since been removed.
  skipped,
}

class LegacyMigrationResult {
  const LegacyMigrationResult(
    this.outcome, {
    this.marker,
    this.importedNow = false,
  });

  final LegacyMigrationOutcome outcome;
  final LegacyMigrationMarker? marker;

  /// True only on the startup that actually imported the records.
  final bool importedNow;

  /// Repairs made during an import that happened on this startup.
  List<String> get warnings => marker?.warnings ?? const [];
  List<String> get errors => marker?.errors ?? const [];
}

/// Stages at which tests can simulate a crash.
enum MigrationStage {
  markerRead,
  markedInProgress,
  recordsWrittenBeforeCommit,
  committed,
}

/// Imports the schema-v1 `requests.json` into [target], at most once.
///
/// Sequence (each step is durable before the next starts):
/// 1. marker → `inProgress`
/// 2. one transaction: write records, verify them, marker → `completed`
/// 3. rename the source to `requests.v1-migrated-<time>.json` (never deleted)
///
/// Interrupting at any point is safe: before step 2 commits nothing is
/// imported and the next startup retries; after it commits the marker
/// prevents a second import and only the rename is retried. Invalid input
/// marks the migration `failed` and leaves the source untouched; every later
/// startup retries, so fixing or removing the file recovers.
Future<LegacyMigrationResult> migrateLegacyV1({
  required SqliteWorkspaceRepository repository,
  required String legacyPath,
  required Collection target,
  required DateTime Function() clock,
  FutureOr<void> Function(MigrationStage stage)? onStage,
}) async {
  final source = File(legacyPath);
  final previous = await _readMarker(repository);
  await onStage?.call(MigrationStage.markerRead);
  if (previous?.state == LegacyMigrationState.completed) {
    return _completed(repository, source, clock);
  }

  if (!await source.exists()) {
    // Another instance may have completed and renamed the file since our
    // first read; the marker is committed before the rename, so re-read it.
    final current = await _readMarker(repository);
    if (current?.state == LegacyMigrationState.completed) {
      return _completed(repository, source, clock);
    }
    if (current == null) {
      return const LegacyMigrationResult(LegacyMigrationOutcome.notNeeded);
    }
    final marker = await _transition(
      repository,
      (latest) => _next(latest ?? current, LegacyMigrationState.skipped, clock),
    );
    if (marker.state == LegacyMigrationState.completed) {
      return _completed(repository, source, clock);
    }
    return LegacyMigrationResult(
      LegacyMigrationOutcome.skipped,
      marker: marker,
    );
  }

  final attempt = await _transition(
    repository,
    (current) => LegacyMigrationMarker(
      state: LegacyMigrationState.inProgress,
      attempts: (current?.attempts ?? 0) + 1,
      updatedAt: clock(),
      source: legacyPath,
    ),
  );
  if (attempt.state == LegacyMigrationState.completed) {
    return _completed(repository, source, clock);
  }
  await onStage?.call(MigrationStage.markedInProgress);

  Future<LegacyMigrationResult> fail(List<String> errors) async {
    final marker = await _transition(
      repository,
      (_) => LegacyMigrationMarker(
        state: LegacyMigrationState.failed,
        attempts: attempt.attempts,
        updatedAt: clock(),
        source: legacyPath,
        errors: errors,
      ),
    );
    // Another instance may have completed the import in the meantime.
    if (marker.state == LegacyMigrationState.completed) {
      return _completed(repository, source, clock);
    }
    return LegacyMigrationResult(LegacyMigrationOutcome.failed, marker: marker);
  }

  final LegacyV1ParseResult parsed;
  try {
    parsed = parseLegacyV1(await source.readAsString());
  } on FileSystemException catch (e) {
    return fail(['Could not read file: ${e.message}']);
  }
  if (!parsed.isValid) return fail(parsed.errors);

  var importedHere = false;
  try {
    await repository.sqliteTransaction((tx) async {
      // Another app instance may have finished while we waited for the lock.
      if ((await _readMarkerIn(tx))?.state == LegacyMigrationState.completed) {
        return;
      }
      final siblings = await tx.children(target.id, includeDeleted: true);
      final plan = planLegacyV1Migration(
        parsed.requests,
        target: target,
        afterSortKey: siblings.isEmpty ? null : siblings.last.meta.sortKey,
      );
      await writeLegacyV1Plan(tx, plan);
      await onStage?.call(MigrationStage.recordsWrittenBeforeCommit);
      await _verify(tx, plan);
      final done = LegacyMigrationMarker(
        state: LegacyMigrationState.completed,
        attempts: attempt.attempts,
        updatedAt: clock(),
        source: legacyPath,
        imported: plan.requests.length,
        warnings: plan.warnings,
      );
      await tx.writeMeta(legacyMigrationMarkerKey, jsonEncode(done.toJson()));
      importedHere = true;
    });
  } on WorkspaceRepositoryException catch (e) {
    return fail([e.message]);
  } on FormatException catch (e) {
    return fail([e.message]);
  }
  await onStage?.call(MigrationStage.committed);
  return _completed(repository, source, clock, importedNow: importedHere);
}

Future<LegacyMigrationResult> _completed(
  SqliteWorkspaceRepository repository,
  File source,
  DateTime Function() clock, {
  bool importedNow = false,
}) async {
  if (await source.exists()) await _archive(repository, source, clock);
  return LegacyMigrationResult(
    LegacyMigrationOutcome.completed,
    marker: await _readMarker(repository),
    importedNow: importedNow,
  );
}

/// Replaces the marker in one transaction unless it is already `completed`,
/// which is final. Returns the marker now stored.
Future<LegacyMigrationMarker> _transition(
  SqliteWorkspaceRepository repository,
  LegacyMigrationMarker Function(LegacyMigrationMarker? current) next,
) => repository.sqliteTransaction((tx) async {
  final current = await _readMarkerIn(tx);
  if (current?.state == LegacyMigrationState.completed) return current!;
  final marker = next(current);
  await tx.writeMeta(legacyMigrationMarkerKey, jsonEncode(marker.toJson()));
  return marker;
});

Future<void> _verify(
  SqliteWorkspaceWriter tx,
  LegacyV1MigrationPlan plan,
) async {
  for (final expected in plan.requests) {
    final stored = await tx.get(expected.id);
    if (stored is! RequestItem ||
        stored.meta != expected.meta ||
        stored.name != expected.name ||
        stored.collectionId != expected.collectionId ||
        stored.template != expected.template.redactedForStorage()) {
      throw FormatException('Verification failed for ${expected.id}');
    }
  }
}

// Renames rather than deletes, so the original stays recoverable.
Future<void> _archive(
  SqliteWorkspaceRepository repository,
  File source,
  DateTime Function() clock,
) async {
  final stamp = clock().toUtc().toIso8601String().replaceAll(':', '-');
  final target = File('${source.parent.path}/requests.v1-migrated-$stamp.json');
  try {
    await source.rename(target.path);
  } on FileSystemException {
    // Retried on the next startup; the completed marker prevents re-import.
    return;
  }
  await repository.sqliteTransaction((tx) async {
    final marker = await _readMarkerIn(tx);
    if (marker == null) return;
    await tx.writeMeta(
      legacyMigrationMarkerKey,
      jsonEncode({...marker.toJson(), 'archivedTo': target.path}),
    );
  });
}

LegacyMigrationMarker _next(
  LegacyMigrationMarker previous,
  LegacyMigrationState state,
  DateTime Function() clock,
) => LegacyMigrationMarker(
  state: state,
  attempts: previous.attempts,
  updatedAt: clock(),
  source: previous.source,
  errors: previous.errors,
);

Future<LegacyMigrationMarker?> _readMarker(
  SqliteWorkspaceRepository repository,
) async => _decode(await repository.readMeta(legacyMigrationMarkerKey));

Future<LegacyMigrationMarker?> _readMarkerIn(SqliteWorkspaceWriter tx) async =>
    _decode(await tx.readMeta(legacyMigrationMarkerKey));

LegacyMigrationMarker? _decode(String? json) => json == null
    ? null
    : LegacyMigrationMarker.fromJson(jsonDecode(json) as Map<String, Object?>);
