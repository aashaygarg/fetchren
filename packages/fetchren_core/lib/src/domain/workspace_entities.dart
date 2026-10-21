import 'package:meta/meta.dart';

import 'entity_meta.dart';
import 'request_template.dart';

/// A record stored in a workspace.
///
/// Hierarchy: [Workspace] → [Collection] → [Folder] (nestable) → [RequestItem].
/// Requests may also sit directly in a collection. Folders and requests carry
/// their [Collection] ID so a collection can be queried without walking the
/// tree; the repository keeps it consistent with the parent folder.
@immutable
sealed class WorkspaceEntity {
  WorkspaceEntity(this.meta, String name) : name = _checkName(name);

  final EntityMeta meta;
  final String name;

  String get id => meta.id;

  /// The workspace this entity belongs to (its own ID for a [Workspace]).
  String get workspaceId;

  /// ID of the direct parent, or null for a [Workspace].
  String? get parentId;

  /// Same entity with replaced metadata. Used for versioning and tombstones.
  WorkspaceEntity withMeta(EntityMeta meta);
}

final class Workspace extends WorkspaceEntity {
  Workspace({required EntityMeta meta, required String name})
    : super(meta, name);

  @override
  String get workspaceId => id;

  @override
  String? get parentId => null;

  @override
  Workspace withMeta(EntityMeta meta) => Workspace(meta: meta, name: name);

  Workspace copyWith({required EntityMeta meta, String? name}) =>
      Workspace(meta: meta, name: name ?? this.name);
}

final class Collection extends WorkspaceEntity {
  Collection({
    required EntityMeta meta,
    required this.workspaceId,
    required String name,
  }) : super(meta, name);

  @override
  final String workspaceId;

  @override
  String get parentId => workspaceId;

  @override
  Collection withMeta(EntityMeta meta) =>
      Collection(meta: meta, workspaceId: workspaceId, name: name);

  Collection copyWith({required EntityMeta meta, String? name}) =>
      Collection(meta: meta, workspaceId: workspaceId, name: name ?? this.name);
}

final class Folder extends WorkspaceEntity {
  Folder({
    required EntityMeta meta,
    required this.workspaceId,
    required this.collectionId,
    this.parentFolderId,
    required String name,
  }) : super(meta, name);

  @override
  final String workspaceId;
  final String collectionId;

  /// Enclosing folder, or null when the folder is at the collection root.
  final String? parentFolderId;

  @override
  String get parentId => parentFolderId ?? collectionId;

  @override
  Folder withMeta(EntityMeta meta) => Folder(
    meta: meta,
    workspaceId: workspaceId,
    collectionId: collectionId,
    parentFolderId: parentFolderId,
    name: name,
  );

  /// Renames or re-parents within the same collection.
  Folder copyWith({
    required EntityMeta meta,
    String? name,
    String? Function()? parentFolderId,
  }) => Folder(
    meta: meta,
    workspaceId: workspaceId,
    collectionId: collectionId,
    parentFolderId: parentFolderId == null
        ? this.parentFolderId
        : parentFolderId(),
    name: name ?? this.name,
  );
}

/// A saved request: a [RequestTemplate] plus its place in the workspace.
final class RequestItem extends WorkspaceEntity {
  RequestItem({
    required EntityMeta meta,
    required this.workspaceId,
    required this.collectionId,
    this.folderId,
    required String name,
    required this.template,
  }) : super(meta, name);

  @override
  final String workspaceId;
  final String collectionId;

  /// Enclosing folder, or null when the request is at the collection root.
  final String? folderId;
  final RequestTemplate template;

  @override
  String get parentId => folderId ?? collectionId;

  @override
  RequestItem withMeta(EntityMeta meta) => RequestItem(
    meta: meta,
    workspaceId: workspaceId,
    collectionId: collectionId,
    folderId: folderId,
    name: name,
    template: template,
  );

  /// Edits or re-parents within the same collection.
  RequestItem copyWith({
    required EntityMeta meta,
    String? name,
    RequestTemplate? template,
    String? Function()? folderId,
  }) => RequestItem(
    meta: meta,
    workspaceId: workspaceId,
    collectionId: collectionId,
    folderId: folderId == null ? this.folderId : folderId(),
    name: name ?? this.name,
    template: template ?? this.template,
  );
}

String _checkName(String name) {
  if (name.trim().isEmpty) {
    throw ArgumentError.value(name, 'name', 'Must not be blank');
  }
  return name;
}
