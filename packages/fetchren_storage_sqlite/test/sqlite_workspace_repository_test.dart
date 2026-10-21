import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_core_testing/fetchren_core_testing.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  final tree = TreeBuilder();

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fetchren_sqlite');
    path = '${dir.path}/workspace.sqlite';
  });

  tearDown(() => dir.delete(recursive: true));

  Future<void> seed(SqliteWorkspaceRepository repo) =>
      repo.transaction((tx) async {
        final w = tree.workspace(id: 'w');
        final c = tree.collection(w, id: 'c');
        await tx.put(w);
        await tx.put(c);
      });

  group('schema', () {
    test('a new database is created at the latest version', () {
      final db = openWorkspaceDatabase(path);
      addTearDown(db.close);
      expect(db.userVersion, latestSchemaVersion);
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name']);
      expect(tables, containsAll(['nodes', 'request_templates', 'app_meta']));
      expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
    });

    test('upgrades an older database and keeps its data', () async {
      final repo = SqliteWorkspaceRepository.open(path);
      await seed(repo);
      await repo.close();

      final upgraded = openWorkspaceDatabase(
        path,
        migrations: [
          ...workspaceMigrations,
          SchemaMigration(
            latestSchemaVersion + 1,
            (db) => db.execute('ALTER TABLE nodes ADD COLUMN note TEXT'),
          ),
        ],
      );
      addTearDown(upgraded.close);
      expect(upgraded.userVersion, latestSchemaVersion + 1);
      expect(upgraded.select('SELECT id FROM nodes').length, 2);
      expect(upgraded.select('SELECT note FROM nodes').first['note'], isNull);
    });

    test(
      'a failing migration rolls back and leaves the version unchanged',
      () async {
        (await _openAndClose(path));
        expect(
          () => openWorkspaceDatabase(
            path,
            migrations: [
              ...workspaceMigrations,
              SchemaMigration(latestSchemaVersion + 1, (db) {
                db.execute('CREATE TABLE half_done (x INTEGER)');
                throw StateError('boom');
              }),
            ],
          ),
          throwsStateError,
        );
        final db = sqlite3.open(path);
        addTearDown(db.close);
        expect(db.userVersion, latestSchemaVersion);
        expect(
          db.select("SELECT 1 FROM sqlite_master WHERE name = 'half_done'"),
          isEmpty,
        );
      },
    );

    test('refuses a newer schema without modifying the file', () async {
      await _openAndClose(path);
      final db = sqlite3.open(path)..userVersion = latestSchemaVersion + 5;
      db.close();
      final before = await File(path).readAsBytes();

      expect(
        () => SqliteWorkspaceRepository.open(path),
        throwsA(
          isA<UnsupportedSchemaVersionException>()
              .having((e) => e.found, 'found', latestSchemaVersion + 5)
              .having((e) => e.toString(), 'message', contains('newer')),
        ),
      );
      expect(await File(path).readAsBytes(), before);
    });

    test('refuses a non-database file without modifying it', () async {
      await File(path).writeAsString('this is not sqlite');
      expect(
        () => SqliteWorkspaceRepository.open(path),
        throwsA(isA<SqliteException>()),
      );
      expect(await File(path).readAsString(), 'this is not sqlite');
    });

    test('child and workspace queries use the indexes', () {
      final db = openWorkspaceDatabase(path);
      addTearDown(db.close);
      String plan(String sql, [List<Object?> args = const []]) => db
          .select('EXPLAIN QUERY PLAN $sql', args)
          .map((r) => r['detail'])
          .join(' | ');
      expect(
        plan(
          'SELECT id FROM nodes WHERE parent_id = ? AND deleted_at IS NULL '
          'ORDER BY sort_key, id',
          ['c'],
        ),
        allOf(contains('nodes_children'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        plan(
          "SELECT id FROM nodes WHERE kind = 'workspace' ORDER BY sort_key, id",
        ),
        allOf(contains('nodes_workspaces'), isNot(contains('TEMP B-TREE'))),
      );
    });
  });

  group('durability and storage', () {
    test('records survive closing and reopening', () async {
      final repo = SqliteWorkspaceRepository.open(path);
      await seed(repo);
      final c = (await repo.get('c'))! as Collection;
      final request = tree.request(c, id: 'r', url: 'https://kept.test');
      await repo.transaction((tx) => tx.put(request));
      await repo.close();

      final reopened = SqliteWorkspaceRepository.open(path);
      addTearDown(reopened.close);
      final stored = (await reopened.get('r'))! as RequestItem;
      expect(stored.meta, request.meta);
      expect(stored.template.url, 'https://kept.test');
    });

    test('timestamps keep microsecond precision in UTC', () async {
      final repo = SqliteWorkspaceRepository.open(path);
      addTearDown(repo.close);
      final precise = DateTime.utc(2026, 10, 21, 1, 2, 3, 456, 789);
      final w = Workspace(
        meta: EntityMeta.create(now: precise, sortKey: 'i', id: 'w'),
        name: 'W',
      );
      await repo.transaction((tx) => tx.put(w));
      final stored = (await repo.get('w'))!;
      expect(stored.meta.createdAt, precise);
      expect(stored.meta.createdAt.isUtc, isTrue);
    });

    test('sensitive header values never reach the database file', () async {
      final repo = SqliteWorkspaceRepository.open(path);
      await seed(repo);
      final c = (await repo.get('c'))! as Collection;
      final request = RequestItem(
        meta: EntityMeta.create(now: t0, sortKey: 'i', id: 'r'),
        workspaceId: 'w',
        collectionId: 'c',
        name: 'R',
        template: RequestTemplate(
          method: HttpMethod.get,
          url: 'https://a.test',
          headers: const [
            HeaderEntry(id: '1', name: 'Authorization', value: 'Bearer S3CRET'),
            HeaderEntry(id: '2', name: 'Cookie', value: 'sid=S3CRET'),
            HeaderEntry(id: '3', name: 'Accept', value: 'text/plain'),
          ],
        ),
      );
      expect(c.id, 'c');
      await repo.transaction((tx) => tx.put(request));
      final stored = (await repo.get('r'))! as RequestItem;
      expect(stored.template.headers.map((h) => h.value), [
        '',
        '',
        'text/plain',
      ]);
      await repo.close();

      for (final file in dir.listSync().whereType<File>()) {
        final bytes = await file.readAsBytes();
        expect(
          String.fromCharCodes(bytes),
          isNot(contains('S3CRET')),
          reason: file.path,
        );
      }
    });

    test('operations after close throw', () async {
      final repo = SqliteWorkspaceRepository.open(path);
      await repo.close();
      await expectLater(repo.get('x'), throwsStateError);
      expect(() => repo.transaction((tx) async {}), throwsStateError);
    });
  });

  group('two repositories on one file (two app instances)', () {
    late SqliteWorkspaceRepository a;
    late SqliteWorkspaceRepository b;

    setUp(() async {
      a = SqliteWorkspaceRepository.open(path);
      b = SqliteWorkspaceRepository.open(path);
      await seed(a);
    });

    tearDown(() async {
      await a.close();
      await b.close();
    });

    test('committed writes from one are visible to the other', () async {
      final c = (await b.get('c'))! as Collection;
      await b.transaction((tx) => tx.put(tree.request(c, id: 'r')));
      expect(await a.get('r'), isNotNull);
    });

    test('uncommitted writes are invisible to the other', () async {
      final c = (await a.get('c'))! as Collection;
      await a.transaction((tx) async {
        await tx.put(tree.request(c, id: 'r'));
        expect(await b.get('r'), isNull);
      });
      expect(await b.get('r'), isNotNull);
    });

    test('a stale write from the other instance is rejected', () async {
      final c = (await a.get('c'))! as Collection;
      final r = tree.request(c, id: 'r');
      await a.transaction((tx) => tx.put(r));
      final seenByA = (await a.get('r'))! as RequestItem;
      final seenByB = (await b.get('r'))! as RequestItem;

      await b.transaction(
        (tx) =>
            tx.put(seenByB.copyWith(meta: seenByB.meta.next(t0), name: 'B')),
      );
      await expectLater(
        a.transaction(
          (tx) =>
              tx.put(seenByA.copyWith(meta: seenByA.meta.next(t0), name: 'A')),
        ),
        throwsA(isA<StaleWriteException>()),
      );
      expect((await a.get('r'))!.name, 'B');
    });

    test(
      'interleaved read-modify-write transactions lose no updates',
      () async {
        final c = (await a.get('c'))! as Collection;
        await a.transaction((tx) => tx.put(tree.request(c, id: 'r')));
        Future<void> bump(SqliteWorkspaceRepository repo) =>
            repo.transaction((tx) async {
              final current = (await tx.get('r'))! as RequestItem;
              await Future<void>.delayed(Duration.zero);
              await tx.put(current.copyWith(meta: current.meta.next(t0)));
            });
        await Future.wait([
          for (var i = 0; i < 20; i++) bump(i.isEven ? a : b),
        ]);
        expect((await b.get('r'))!.meta.version, 21);
      },
    );

    test('a long write in one instance does not fail the other', () async {
      final c = (await a.get('c'))! as Collection;
      final started = DateTime.now();
      final slow = a.transaction((tx) async {
        await tx.put(tree.request(c, id: 'slow'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await b.transaction((tx) => tx.put(tree.request(c, id: 'fast')));
      await slow;
      expect(
        DateTime.now().difference(started),
        greaterThanOrEqualTo(const Duration(milliseconds: 300)),
      );
      expect(await a.get('fast'), isNotNull);
    });
  });
}

Future<void> _openAndClose(String path) async {
  final repo = SqliteWorkspaceRepository.open(path);
  await repo.close();
}
