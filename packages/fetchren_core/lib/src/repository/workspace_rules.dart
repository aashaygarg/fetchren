import '../domain/workspace_entities.dart';
import 'workspace_repository.dart';

typedef EntityLookup = Future<WorkspaceEntity?> Function(String id);
typedef ChildrenLookup = Future<List<WorkspaceEntity>> Function(
  String parentId,
);

/// Validates a [WorkspaceWriter.put] against the current state.
///
/// Shared by every repository implementation so the rules cannot drift.
/// Throws [StaleWriteException] or [WorkspaceIntegrityException].
Future<void> checkPut(WorkspaceEntity entity, EntityLookup lookup) async {
  final existing = await lookup(entity.id);
  _checkVersion(entity, existing);
  switch (entity) {
    case Workspace():
      return;
    case Collection(:final workspaceId):
      await _requireLiveParent<Workspace>(entity, workspaceId, lookup);
    case Folder(:final collectionId, :final parentFolderId):
      await _requireCollection(entity, collectionId, lookup);
      if (parentFolderId != null) {
        await _requireFolderInCollection(
          entity,
          parentFolderId,
          collectionId,
          lookup,
        );
        await _rejectCycle(entity.id, parentFolderId, lookup);
      }
    case RequestItem(:final collectionId, :final folderId):
      await _requireCollection(entity, collectionId, lookup);
      if (folderId != null) {
        await _requireFolderInCollection(
          entity,
          folderId,
          collectionId,
          lookup,
        );
      }
  }
}

/// Tombstone revisions for [root] and all of its live descendants.
///
/// Returns an empty list if [root] is already deleted.
Future<List<WorkspaceEntity>> tombstonesFor(
  WorkspaceEntity root,
  DateTime at,
  ChildrenLookup liveChildren,
) async {
  if (root.meta.isDeleted) return const [];
  final result = <WorkspaceEntity>[];
  final pending = [root];
  while (pending.isNotEmpty) {
    final entity = pending.removeLast();
    result.add(entity.withMeta(entity.meta.deleted(at)));
    pending.addAll(await liveChildren(entity.id));
  }
  return result;
}

void _checkVersion(WorkspaceEntity entity, WorkspaceEntity? existing) {
  if (entity.meta.isDeleted) {
    throw const WorkspaceIntegrityException(
      'Use softDelete to delete entities',
    );
  }
  if (existing == null) {
    if (entity.meta.version != 1) {
      throw StaleWriteException(
        '${entity.id} does not exist; new entities start at version 1',
      );
    }
    return;
  }
  if (entity.meta.version != existing.meta.version + 1) {
    throw StaleWriteException(
      '${entity.id} is at version ${existing.meta.version}; '
      'got ${entity.meta.version}',
    );
  }
  if (existing.runtimeType != entity.runtimeType) {
    throw WorkspaceIntegrityException('${entity.id} cannot change type');
  }
  if (existing.meta.createdAt != entity.meta.createdAt) {
    throw WorkspaceIntegrityException('${entity.id}: createdAt is immutable');
  }
  if (existing.workspaceId != entity.workspaceId) {
    throw WorkspaceIntegrityException(
      '${entity.id} cannot move between workspaces',
    );
  }
  if (_collectionOf(existing) != _collectionOf(entity)) {
    throw WorkspaceIntegrityException(
      '${entity.id} cannot move between collections',
    );
  }
}

Future<P> _requireLiveParent<P extends WorkspaceEntity>(
  WorkspaceEntity entity,
  String parentId,
  EntityLookup lookup,
) async {
  final parent = await lookup(parentId);
  if (parent is! P) {
    throw WorkspaceIntegrityException(
      '${entity.id}: parent $parentId is not an existing $P',
    );
  }
  if (parent.meta.isDeleted) {
    throw WorkspaceIntegrityException(
      '${entity.id}: parent $parentId is deleted',
    );
  }
  return parent;
}

Future<void> _requireCollection(
  WorkspaceEntity entity,
  String collectionId,
  EntityLookup lookup,
) async {
  final collection = await _requireLiveParent<Collection>(
    entity,
    collectionId,
    lookup,
  );
  if (collection.workspaceId != entity.workspaceId) {
    throw WorkspaceIntegrityException(
      '${entity.id}: collection $collectionId is in another workspace',
    );
  }
}

Future<void> _requireFolderInCollection(
  WorkspaceEntity entity,
  String folderId,
  String collectionId,
  EntityLookup lookup,
) async {
  final folder = await _requireLiveParent<Folder>(entity, folderId, lookup);
  if (folder.collectionId != collectionId) {
    throw WorkspaceIntegrityException(
      '${entity.id}: folder $folderId is in another collection',
    );
  }
}

Future<void> _rejectCycle(
  String folderId,
  String parentFolderId,
  EntityLookup lookup,
) async {
  String? current = parentFolderId;
  while (current != null) {
    if (current == folderId) {
      throw WorkspaceIntegrityException(
        '$folderId cannot be moved inside itself',
      );
    }
    current = (await lookup(current) as Folder?)?.parentFolderId;
  }
}

String? _collectionOf(WorkspaceEntity entity) => switch (entity) {
  Workspace() => null,
  Collection() => entity.id,
  Folder(:final collectionId) => collectionId,
  RequestItem(:final collectionId) => collectionId,
};
