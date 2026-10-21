import 'dart:async';
import 'dart:convert';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:sqlite3/sqlite3.dart';

import 'database.dart';

/// [WorkspaceRepository] backed by a SQLite file.
///
/// Uses two connections: [_writer] runs transactions (`BEGIN IMMEDIATE`, so
/// other processes are locked out of writing), [_reader] serves reads outside
/// transactions and, thanks to WAL, only ever sees committed data.
class SqliteWorkspaceRepository implements WorkspaceRepository {
  SqliteWorkspaceRepository._(this._writer, this._reader);

  /// Opens or creates the database at [path], applying schema migrations.
  ///
  /// Throws [UnsupportedSchemaVersionException] or [SqliteException] without
  /// modifying the file.
  factory SqliteWorkspaceRepository.open(String path) {
    final writer = openWorkspaceDatabase(path);
    try {
      final reader = sqlite3.open(path);
      // WAL readers only wait during rare recovery or checkpoint work.
      configureConnection(reader, busyTimeout: const Duration(seconds: 1));
      return SqliteWorkspaceRepository._(writer, reader);
    } catch (_) {
      writer.close();
      rethrow;
    }
  }

  /// How long a transaction waits for another process's write lock.
  static const Duration lockTimeout = Duration(seconds: 5);

  final Database _writer;
  final Database _reader;
  Future<void> _queue = Future.value();
  final Object _zoneKey = Object();
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Repository is closed');
  }

  @override
  Future<WorkspaceEntity?> get(String id) async {
    _checkOpen();
    return _get(_reader, id);
  }

  @override
  Future<List<Workspace>> workspaces({bool includeDeleted = false}) async {
    _checkOpen();
    return _workspaces(_reader, includeDeleted);
  }

  @override
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
    int? limit,
  }) async {
    _checkOpen();
    return _children(_reader, parentId, includeDeleted, limit);
  }

  @override
  Future<List<RequestSummary>> requestSummaries(
    String parentId, {
    required int limit,
    RequestSummary? after,
  }) async {
    _checkOpen();
    return _summaries(_reader, parentId, limit, after);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(WorkspaceWriter tx) action) =>
      sqliteTransaction(action);

  /// Like [transaction], with access to the `app_meta` table.
  Future<T> sqliteTransaction<T>(
    Future<T> Function(SqliteWorkspaceWriter tx) action,
  ) {
    _checkOpen();
    if (Zone.current[_zoneKey] != null) {
      throw StateError('Nested transactions are not supported');
    }
    final result = _queue.then((_) async {
      await _beginImmediate();
      final tx = SqliteWorkspaceWriter._(_writer);
      try {
        final value = await runZoned(
          () => action(tx),
          zoneValues: {_zoneKey: true},
        );
        _writer.execute('COMMIT');
        return value;
      } catch (_) {
        if (!_writer.autocommit) _writer.execute('ROLLBACK');
        rethrow;
      } finally {
        tx._closed = true;
      }
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Reads a committed `app_meta` value.
  Future<String?> readMeta(String key) async {
    _checkOpen();
    return _readMeta(_reader, key);
  }

  // Retries asynchronously so a lock held by another process never blocks
  // this isolate (and the UI running on it).
  Future<void> _beginImmediate() async {
    final deadline = DateTime.now().add(lockTimeout);
    var delay = const Duration(milliseconds: 5);
    while (true) {
      try {
        _writer.execute('BEGIN IMMEDIATE');
        return;
      } on SqliteException catch (e) {
        if (e.resultCode != SqlError.SQLITE_BUSY ||
            DateTime.now().isAfter(deadline)) {
          rethrow;
        }
      }
      await Future<void>.delayed(delay);
      if (delay < const Duration(milliseconds: 100)) delay *= 2;
    }
  }

  /// Waits for queued transactions, then closes both connections.
  Future<void> close() async {
    if (_closed) return;
    await _queue;
    _closed = true;
    _reader.close();
    _writer.close();
  }
}

/// Transaction handle for [SqliteWorkspaceRepository].
class SqliteWorkspaceWriter implements WorkspaceWriter {
  SqliteWorkspaceWriter._(this._db);

  final Database _db;
  bool _closed = false;

  void _checkOpen() {
    if (_closed) throw StateError('Transaction already completed');
  }

  @override
  Future<WorkspaceEntity?> get(String id) async {
    _checkOpen();
    return _get(_db, id);
  }

  @override
  Future<List<Workspace>> workspaces({bool includeDeleted = false}) async {
    _checkOpen();
    return _workspaces(_db, includeDeleted);
  }

  @override
  Future<List<WorkspaceEntity>> children(
    String parentId, {
    bool includeDeleted = false,
    int? limit,
  }) async {
    _checkOpen();
    return _children(_db, parentId, includeDeleted, limit);
  }

  @override
  Future<List<RequestSummary>> requestSummaries(
    String parentId, {
    required int limit,
    RequestSummary? after,
  }) async {
    _checkOpen();
    return _summaries(_db, parentId, limit, after);
  }

  @override
  Future<void> put(WorkspaceEntity entity) async {
    _checkOpen();
    await checkPut(entity, (id) async => _get(_db, id));
    _upsert(_db, entity);
  }

  @override
  Future<int> softDelete(String id, DateTime at) async {
    _checkOpen();
    final root = _get(_db, id);
    if (root == null) throw EntityNotFoundException('$id does not exist');
    final tombstones = await tombstonesFor(
      root,
      at,
      (parentId) async => _children(_db, parentId, false, null),
    );
    for (final entity in tombstones) {
      _upsert(_db, entity);
    }
    return tombstones.length;
  }

  Future<String?> readMeta(String key) async {
    _checkOpen();
    return _readMeta(_db, key);
  }

  Future<void> writeMeta(String key, String value) async {
    _checkOpen();
    _db.execute(
      'INSERT INTO app_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }
}

const String _select = '''
  SELECT n.id, n.kind, n.workspace_id, n.collection_id, n.parent_id, n.name,
         n.sort_key, n.version, n.created_at, n.updated_at, n.deleted_at,
         t.method, t.url, t.headers_json, t.body
  FROM nodes n LEFT JOIN request_templates t ON t.request_id = n.id
''';

WorkspaceEntity? _get(Database db, String id) {
  final rows = db.select('$_select WHERE n.id = ?', [id]);
  return rows.isEmpty ? null : _fromRow(rows.single);
}

List<Workspace> _workspaces(Database db, bool includeDeleted) => [
  for (final row in db.select(
    "$_select WHERE n.kind = 'workspace'"
    '${includeDeleted ? '' : ' AND n.deleted_at IS NULL'}'
    ' ORDER BY n.sort_key, n.id',
  ))
    _fromRow(row) as Workspace,
];

List<WorkspaceEntity> _children(
  Database db,
  String parentId,
  bool includeDeleted,
  int? limit,
) {
  checkLimit(limit);
  return [
    for (final row in db.select(
      '$_select WHERE n.parent_id = ?'
      '${includeDeleted ? '' : ' AND n.deleted_at IS NULL'}'
      ' ORDER BY n.sort_key, n.id'
      '${limit == null ? '' : ' LIMIT ?'}',
      [parentId, ?limit],
    ))
      _fromRow(row),
  ];
}

List<RequestSummary> _summaries(
  Database db,
  String parentId,
  int limit,
  RequestSummary? after,
) {
  checkLimit(limit);
  final updated = after?.updatedAt.microsecondsSinceEpoch;
  return [
    for (final row in db.select(
      '''
      SELECT n.id, n.name, n.updated_at, t.method
      FROM nodes n JOIN request_templates t ON t.request_id = n.id
      WHERE n.parent_id = ? AND n.kind = 'request' AND n.deleted_at IS NULL
      ${after == null ? '' : 'AND (n.updated_at < ? OR (n.updated_at = ? AND n.id > ?))'}
      ORDER BY n.updated_at DESC, n.id
      LIMIT ?
      ''',
      [
        parentId,
        if (after != null) ...[updated, updated, after.id],
        limit,
      ],
    ))
      RequestSummary(
        id: row['id'] as String,
        name: row['name'] as String,
        method: HttpMethod.fromWireName(row['method'] as String),
        updatedAt: _time(row['updated_at'] as int),
      ),
  ];
}

String? _readMeta(Database db, String key) {
  final rows = db.select('SELECT value FROM app_meta WHERE key = ?', [key]);
  return rows.isEmpty ? null : rows.single['value'] as String;
}

WorkspaceEntity _fromRow(Row row) {
  final meta = EntityMeta(
    id: row['id'] as String,
    createdAt: _time(row['created_at'] as int),
    updatedAt: _time(row['updated_at'] as int),
    version: row['version'] as int,
    sortKey: row['sort_key'] as String,
    deletedAt: switch (row['deleted_at']) {
      final int micros => _time(micros),
      _ => null,
    },
  );
  final name = row['name'] as String;
  final workspaceId = row['workspace_id'] as String;
  final collectionId = row['collection_id'] as String?;
  final parentId = row['parent_id'] as String?;
  final folderId = parentId == collectionId ? null : parentId;
  return switch (row['kind']) {
    'workspace' => Workspace(meta: meta, name: name),
    'collection' => Collection(
      meta: meta,
      workspaceId: workspaceId,
      name: name,
    ),
    'folder' => Folder(
      meta: meta,
      workspaceId: workspaceId,
      collectionId: collectionId!,
      parentFolderId: folderId,
      name: name,
    ),
    'request' => RequestItem(
      meta: meta,
      workspaceId: workspaceId,
      collectionId: collectionId!,
      folderId: folderId,
      name: name,
      template: RequestTemplate(
        method: HttpMethod.fromWireName(row['method'] as String),
        url: row['url'] as String,
        headers: [
          for (final h in jsonDecode(row['headers_json'] as String) as List)
            HeaderEntry.fromJson(h as Map<String, Object?>),
        ],
        body: row['body'] as String,
      ),
    ),
    final kind => throw FormatException('Unknown node kind: $kind'),
  };
}

void _upsert(Database db, WorkspaceEntity e) {
  final (kind, collectionId) = switch (e) {
    Workspace() => ('workspace', null),
    Collection() => ('collection', null),
    Folder(:final collectionId) => ('folder', collectionId),
    RequestItem(:final collectionId) => ('request', collectionId),
  };
  db.execute(
    '''
    INSERT INTO nodes (id, kind, workspace_id, collection_id, parent_id, name,
                       sort_key, version, created_at, updated_at, deleted_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(id) DO UPDATE SET
      kind = excluded.kind, workspace_id = excluded.workspace_id,
      collection_id = excluded.collection_id, parent_id = excluded.parent_id,
      name = excluded.name, sort_key = excluded.sort_key,
      version = excluded.version, created_at = excluded.created_at,
      updated_at = excluded.updated_at, deleted_at = excluded.deleted_at
    ''',
    [
      e.id,
      kind,
      e.workspaceId,
      collectionId,
      e.parentId,
      e.name,
      e.meta.sortKey,
      e.meta.version,
      e.meta.createdAt.microsecondsSinceEpoch,
      e.meta.updatedAt.microsecondsSinceEpoch,
      e.meta.deletedAt?.microsecondsSinceEpoch,
    ],
  );
  if (e is RequestItem) {
    // Credentials are never written to disk until a credential store exists.
    final t = e.template.redactedForStorage();
    db.execute(
      '''
      INSERT INTO request_templates (request_id, method, url, headers_json, body)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(request_id) DO UPDATE SET
        method = excluded.method, url = excluded.url,
        headers_json = excluded.headers_json, body = excluded.body
      ''',
      [
        e.id,
        t.method.wireName,
        t.url,
        jsonEncode([for (final h in t.headers) h.toJson()]),
        t.body,
      ],
    );
  }
}

DateTime _time(int micros) =>
    DateTime.fromMicrosecondsSinceEpoch(micros, isUtc: true);
