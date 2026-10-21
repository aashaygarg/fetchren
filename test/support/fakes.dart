import 'dart:async';
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';

final DateTime fixedTime = DateTime.utc(2026, 10, 21, 12);

ResolvedRequest makeResolved({
  HttpMethod method = HttpMethod.get,
  String url = 'https://api.example.test/items',
  List<HeaderEntry> headers = const [],
  String body = '',
}) => ResolvedRequest(method: method, url: url, headers: headers, body: body);

/// A saved request in [collection].
RequestItem makeItem(
  Collection collection, {
  String id = 'req-1',
  HttpMethod method = HttpMethod.get,
  String url = 'https://api.example.test/items',
  List<HeaderEntry> headers = const [],
  String body = '',
  DateTime? updatedAt,
  String sortKey = 'i',
}) => RequestItem(
  meta: EntityMeta(
    id: id,
    createdAt: updatedAt ?? fixedTime,
    updatedAt: updatedAt ?? fixedTime,
    version: 1,
    sortKey: sortKey,
  ),
  workspaceId: collection.workspaceId,
  collectionId: collection.id,
  name: url,
  template: RequestTemplate(
    method: method,
    url: url,
    headers: headers,
    body: body,
  ),
);

/// [InMemoryWorkspaceRepository] with failure switches and a commit counter.
class FakeWorkspaceRepository implements WorkspaceRepository {
  final InMemoryWorkspaceRepository _inner = InMemoryWorkspaceRepository();
  bool failLoads = false;
  bool failSaves = false;
  int commits = 0;
  int summaryReads = 0;

  /// When set, transactions wait for it before running.
  Completer<void>? holdSaves;

  late Collection collection;

  /// Creates the default workspace and collection, then resets [commits].
  static Future<FakeWorkspaceRepository> create([
    List<RequestItem Function(Collection)> seed = const [],
  ]) async {
    final repo = FakeWorkspaceRepository();
    repo.collection = await ensureDefaultCollection(
      repo._inner,
      now: fixedTime,
    );
    await repo._inner.transaction((tx) async {
      for (final make in seed) {
        await tx.put(make(repo.collection));
      }
    });
    return repo;
  }

  /// Live requests in [collection], as stored.
  Future<List<RequestItem>> stored() async => [
    for (final e in await _inner.children(collection.id))
      if (e is RequestItem) e,
  ];

  void _checkLoad() {
    if (failLoads) throw const FileSystemException('permission denied');
  }

  @override
  Future<WorkspaceEntity?> get(String id) async {
    _checkLoad();
    return _inner.get(id);
  }

  @override
  Future<List<Workspace>> workspaces({bool includeDeleted = false}) async {
    _checkLoad();
    return _inner.workspaces(includeDeleted: includeDeleted);
  }

  @override
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
    int? limit,
  }) async {
    _checkLoad();
    return _inner.children(
      parentId,
      includeDeleted: includeDeleted,
      limit: limit,
    );
  }

  @override
  Future<List<RequestSummary>> requestSummaries(
    String parentId, {
    required int limit,
    RequestSummary? after,
  }) async {
    _checkLoad();
    summaryReads++;
    return _inner.requestSummaries(parentId, limit: limit, after: after);
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(WorkspaceWriter tx) action,
  ) async {
    if (failSaves) throw Exception('disk full');
    await holdSaves?.future;
    final result = await _inner.transaction(action);
    commits++;
    return result;
  }
}
