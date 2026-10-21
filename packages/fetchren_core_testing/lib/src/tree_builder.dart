import 'package:fetchren_core/fetchren_core.dart';

/// Fixed timestamp used by shared fixtures.
final DateTime t0 = DateTime.utc(2026, 10, 21, 12);

/// Builds a small valid tree for repository tests.
class TreeBuilder {
  TreeBuilder({DateTime? now}) : now = now ?? t0;

  final DateTime now;

  Workspace workspace({String? id, String name = 'W', String? sortKey}) =>
      Workspace(meta: _meta(id, sortKey), name: name);

  Collection collection(
    Workspace workspace, {
    String? id,
    String name = 'C',
    String? sortKey,
  }) => Collection(
    meta: _meta(id, sortKey),
    workspaceId: workspace.id,
    name: name,
  );

  Folder folder(
    Collection collection, {
    Folder? parent,
    String? id,
    String name = 'F',
    String? sortKey,
  }) => Folder(
    meta: _meta(id, sortKey),
    workspaceId: collection.workspaceId,
    collectionId: collection.id,
    parentFolderId: parent?.id,
    name: name,
  );

  RequestItem request(
    Collection collection, {
    Folder? folder,
    String? id,
    String name = 'R',
    String? sortKey,
    String url = 'https://api.example.test',
  }) => RequestItem(
    meta: _meta(id, sortKey),
    workspaceId: collection.workspaceId,
    collectionId: collection.id,
    folderId: folder?.id,
    name: name,
    template: RequestTemplate(method: HttpMethod.get, url: url),
  );

  EntityMeta _meta(String? id, String? sortKey) =>
      EntityMeta.create(now: now, sortKey: sortKey ?? 'i', id: id);
}
