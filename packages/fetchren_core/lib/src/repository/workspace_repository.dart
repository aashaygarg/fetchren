import '../domain/workspace_entities.dart';

/// Read access to workspace records.
abstract interface class WorkspaceReader {
  /// The entity with [id], including tombstoned entities, or null.
  Future<WorkspaceEntity?> get(String id);

  /// All workspaces, ordered by sort key then ID.
  Future<List<Workspace>> workspaces({bool includeDeleted = false});

  /// Direct children of [parentId], ordered by sort key then ID.
  ///
  /// Children of a workspace are collections; children of a collection or
  /// folder are folders and requests, interleaved by sort key.
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
  });
}

/// Write access, available only inside [WorkspaceRepository.transaction].
abstract interface class WorkspaceWriter implements WorkspaceReader {
  /// Inserts a new entity or replaces an existing one.
  ///
  /// - Insert: `meta.version` must be 1.
  /// - Update: `meta.version` must be exactly the stored version + 1, the
  ///   type, `createdAt`, workspace, and collection must be unchanged.
  /// - The parent must exist, be live, and belong to the same workspace and
  ///   collection; folders may not become their own ancestor.
  /// - Tombstones cannot be written here; use [softDelete]. Writing a live
  ///   revision of a tombstoned entity restores it (descendants stay deleted).
  ///
  /// Throws [StaleWriteException] or [WorkspaceIntegrityException].
  Future<void> put(WorkspaceEntity entity);

  /// Tombstones [id] and all of its live descendants at [at].
  ///
  /// Returns the number of entities tombstoned (0 if already deleted).
  /// Throws [EntityNotFoundException] if [id] does not exist.
  Future<int> softDelete(String id, DateTime at);
}

/// Record-level storage for workspaces, collections, folders, and requests.
abstract interface class WorkspaceRepository implements WorkspaceReader {
  /// Runs [action] atomically: either every write commits or none does.
  ///
  /// Transactions are serialized. Reads inside [action] see its own writes.
  /// If [action] throws, nothing is committed and the error is rethrown.
  /// Nested transactions and use of the writer after [action] completes
  /// throw [StateError].
  Future<T> transaction<T>(Future<T> Function(WorkspaceWriter tx) action);
}

sealed class WorkspaceRepositoryException implements Exception {
  const WorkspaceRepositoryException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The write was based on an outdated version of the entity.
final class StaleWriteException extends WorkspaceRepositoryException {
  const StaleWriteException(super.message);
}

/// The write would break a structural rule of the workspace tree.
final class WorkspaceIntegrityException extends WorkspaceRepositoryException {
  const WorkspaceIntegrityException(super.message);
}

final class EntityNotFoundException extends WorkspaceRepositoryException {
  const EntityNotFoundException(super.message);
}
