import 'dart:async';

import '../domain/workspace_entities.dart';
import 'workspace_repository.dart';
import 'workspace_rules.dart';

/// Reference [WorkspaceRepository] kept in memory.
///
/// Defines the expected behavior for persistent implementations and serves
/// as a fake in tests. Not durable.
class InMemoryWorkspaceRepository implements WorkspaceRepository {
  Map<String, WorkspaceEntity> _committed = {};
  Future<void> _queue = Future.value();
  final Object _zoneKey = Object();

  @override
  Future<WorkspaceEntity?> get(String id) async => _committed[id];

  @override
  Future<List<Workspace>> workspaces({bool includeDeleted = false}) async =>
      _workspaces(_committed, includeDeleted);

  @override
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
    int? limit,
  }) async => _children(_committed, parentId, includeDeleted, limit);

  @override
  Future<List<RequestSummary>> requestSummaries(
    String parentId, {
    required int limit,
    RequestSummary? after,
  }) async => _summaries(_committed, parentId, limit, after);

  @override
  Future<T> transaction<T>(Future<T> Function(WorkspaceWriter tx) action) {
    if (Zone.current[_zoneKey] != null) {
      throw StateError('Nested transactions are not supported');
    }
    final result = _queue.then((_) async {
      final tx = _InMemoryWriter(Map.of(_committed));
      try {
        final value = await runZoned(
          () => action(tx),
          zoneValues: {_zoneKey: true},
        );
        _committed = tx._working;
        return value;
      } finally {
        tx._closed = true;
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

class _InMemoryWriter implements WorkspaceWriter {
  _InMemoryWriter(this._working);

  final Map<String, WorkspaceEntity> _working;
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Transaction already completed');
  }

  @override
  Future<WorkspaceEntity?> get(String id) async {
    _checkOpen();
    return _working[id];
  }

  @override
  Future<List<Workspace>> workspaces({bool includeDeleted = false}) async {
    _checkOpen();
    return _workspaces(_working, includeDeleted);
  }

  @override
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
    int? limit,
  }) async {
    _checkOpen();
    return _children(_working, parentId, includeDeleted, limit);
  }

  @override
  Future<List<RequestSummary>> requestSummaries(
    String parentId, {
    required int limit,
    RequestSummary? after,
  }) async {
    _checkOpen();
    return _summaries(_working, parentId, limit, after);
  }

  @override
  Future<void> put(WorkspaceEntity entity) async {
    _checkOpen();
    await checkPut(entity, (id) async => _working[id]);
    _working[entity.id] = entity;
  }

  @override
  Future<int> softDelete(String id, DateTime at) async {
    _checkOpen();
    final root = _working[id];
    if (root == null) throw EntityNotFoundException('$id does not exist');
    final tombstones = await tombstonesFor(
      root,
      at,
      (parentId) async => _children(_working, parentId, false, null),
    );
    for (final entity in tombstones) {
      _working[entity.id] = entity;
    }
    return tombstones.length;
  }
}

int _bySortKey(WorkspaceEntity a, WorkspaceEntity b) {
  final byKey = a.meta.sortKey.compareTo(b.meta.sortKey);
  return byKey != 0 ? byKey : a.id.compareTo(b.id);
}

List<Workspace> _workspaces(
  Map<String, WorkspaceEntity> entities,
  bool includeDeleted,
) => [
  for (final e in entities.values)
    if (e is Workspace && (includeDeleted || !e.meta.isDeleted)) e,
]..sort(_bySortKey);

List<WorkspaceEntity> _children(
  Map<String, WorkspaceEntity> entities,
  String parentId,
  bool includeDeleted,
  int? limit,
) {
  checkLimit(limit);
  final all = [
    for (final e in entities.values)
      if (e.parentId == parentId && (includeDeleted || !e.meta.isDeleted)) e,
  ]..sort(_bySortKey);
  return limit == null ? all : all.take(limit).toList();
}

List<RequestSummary> _summaries(
  Map<String, WorkspaceEntity> entities,
  String parentId,
  int limit,
  RequestSummary? after,
) {
  checkLimit(limit);
  final page = [
    for (final e in entities.values)
      if (e is RequestItem && e.parentId == parentId && !e.meta.isDeleted)
        if (RequestSummary.of(e) case final s
            when after == null || compareNewestFirst(after, s) < 0)
          s,
  ]..sort(compareNewestFirst);
  return page.take(limit).toList();
}
