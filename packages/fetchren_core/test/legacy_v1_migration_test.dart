import 'dart:convert';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  final tree = TreeBuilder();
  final workspace = tree.workspace(id: 'w');
  final target = tree.collection(workspace, id: 'c');

  group('parseLegacyV1', () {
    String doc(List<Object?> requests) =>
        jsonEncode({'version': 1, 'requests': requests});

    test('parses valid entries in file order', () {
      final result = parseLegacyV1(
        doc([legacyRequest(id: 'a').toJson(), legacyRequest(id: 'b').toJson()]),
      );
      expect(result.isValid, isTrue);
      expect(result.requests.map((r) => r.id), ['a', 'b']);
    });

    test('reports invalid JSON and wrong document shapes', () {
      for (final source in [
        '{not json',
        '[]',
        jsonEncode({'version': 2, 'requests': []}),
        jsonEncode({'version': 1, 'requests': 'x'}),
      ]) {
        final result = parseLegacyV1(source);
        expect(result.isValid, isFalse, reason: source);
        expect(result.requests, isEmpty);
      }
    });

    test('reports every malformed entry by index without dropping others', () {
      final result = parseLegacyV1(
        doc([
          legacyRequest(id: 'ok').toJson(),
          'not an object',
          {...legacyRequest(id: 'bad-method').toJson(), 'method': 'TRACE'},
          {...legacyRequest(id: 'no-url').toJson()}..remove('url'),
          {...legacyRequest().toJson(), 'id': '  '},
        ]),
      );
      expect(result.isValid, isFalse);
      expect(result.requests.map((r) => r.id), ['ok']);
      expect(result.errors, hasLength(4));
      expect(result.errors[0], startsWith('Entry 1'));
      expect(result.errors[1], startsWith('Entry 2'));
      expect(result.errors[2], startsWith('Entry 3'));
      expect(result.errors[3], 'Entry 4: blank ID');
    });

    test('reports duplicate IDs with both positions', () {
      final result = parseLegacyV1(
        doc([
          legacyRequest(id: 'dup').toJson(),
          legacyRequest(id: 'dup', url: 'https://other.test').toJson(),
        ]),
      );
      expect(result.isValid, isFalse);
      expect(result.errors.single, 'Entry 1: duplicate ID dup (also entry 0)');
    });
  });

  group('planLegacyV1Migration', () {
    test('preserves IDs, names, contents, and timestamps', () {
      final created = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final updated = DateTime.utc(2026, 2, 3, 4, 5, 6);
      final plan = planLegacyV1Migration([
        legacyRequest(
          id: 'abc',
          name: 'List items',
          method: HttpMethod.patch,
          url: 'https://api.example.test/x',
          headers: const [
            HeaderEntry(id: 'h1', name: 'Accept', value: 'application/json'),
            HeaderEntry(id: 'h2', name: 'Authorization', value: ''),
          ],
          body: '{"k":"v"}',
          createdAt: created,
          updatedAt: updated,
        ),
      ], target: target);

      final item = plan.requests.single;
      expect(item.id, 'abc');
      expect(item.name, 'List items');
      expect(item.meta.createdAt, created);
      expect(item.meta.updatedAt, updated);
      expect(item.meta.version, 1);
      expect(item.workspaceId, 'w');
      expect(item.collectionId, 'c');
      expect(item.folderId, isNull);
      expect(item.template.method, HttpMethod.patch);
      expect(item.template.url, 'https://api.example.test/x');
      expect(item.template.headers.map((h) => h.id), ['h1', 'h2']);
      expect(item.template.body, '{"k":"v"}');
      expect(plan.warnings, isEmpty);
    });

    test('keeps the v1 display order (most recently updated first)', () {
      final plan = planLegacyV1Migration([
        legacyRequest(id: 'old', updatedAt: DateTime.utc(2026, 1)),
        legacyRequest(id: 'new', updatedAt: DateTime.utc(2026, 3)),
        legacyRequest(id: 'b-tie', updatedAt: DateTime.utc(2026, 2)),
        legacyRequest(id: 'a-tie', updatedAt: DateTime.utc(2026, 2)),
      ], target: target);
      final byKey = [...plan.requests]
        ..sort((a, b) => a.meta.sortKey.compareTo(b.meta.sortKey));
      expect(byKey.map((r) => r.id), ['new', 'a-tie', 'b-tie', 'old']);
    });

    test('sort keys start after existing siblings', () {
      final plan = planLegacyV1Migration(
        [legacyRequest(id: 'a'), legacyRequest(id: 'b')],
        target: target,
        afterSortKey: 'r',
      );
      expect(
        plan.requests.every((r) => r.meta.sortKey.compareTo('r') > 0),
        isTrue,
      );
    });

    test('handles an empty v1 store', () {
      expect(planLegacyV1Migration(const [], target: target).requests, isEmpty);
    });

    test('aborts on duplicate IDs instead of dropping a record', () {
      expect(
        () => planLegacyV1Migration([
          legacyRequest(id: 'dup'),
          legacyRequest(id: 'dup', url: 'https://other.test'),
        ], target: target),
        throwsFormatException,
      );
    });

    test('repairs values the new model rejects and reports them', () {
      final plan = planLegacyV1Migration([
        legacyRequest(id: 'blank', name: '   '),
        legacyRequest(
          id: 'skewed',
          createdAt: DateTime.utc(2026, 5),
          updatedAt: DateTime.utc(2026, 4),
        ),
      ], target: target);
      final byId = {for (final r in plan.requests) r.id: r};
      expect(byId['blank']!.name, untitledRequestName);
      expect(byId['skewed']!.meta.updatedAt, DateTime.utc(2026, 5));
      expect(byId['skewed']!.meta.createdAt, DateTime.utc(2026, 5));
      expect(plan.warnings, hasLength(2));
      expect(
        plan.warnings.join('\n'),
        allOf(contains('blank'), contains('skewed')),
      );
    });
  });

  group('writeLegacyV1Plan', () {
    test('writes all items in one transaction', () async {
      final repo = InMemoryWorkspaceRepository();
      await repo.transaction((tx) async {
        await tx.put(workspace);
        await tx.put(target);
      });
      final plan = planLegacyV1Migration([
        legacyRequest(id: 'a', updatedAt: DateTime.utc(2026, 2)),
        legacyRequest(id: 'b', updatedAt: DateTime.utc(2026, 1)),
      ], target: target);
      await repo.transaction((tx) => writeLegacyV1Plan(tx, plan));
      expect((await repo.children('c')).map((e) => e.id), ['a', 'b']);
    });

    test('a second write of the same plan fails and changes nothing', () async {
      final repo = InMemoryWorkspaceRepository();
      await repo.transaction((tx) async {
        await tx.put(workspace);
        await tx.put(target);
      });
      final plan = planLegacyV1Migration([
        legacyRequest(id: 'a'),
      ], target: target);
      await repo.transaction((tx) => writeLegacyV1Plan(tx, plan));
      await expectLater(
        repo.transaction((tx) => writeLegacyV1Plan(tx, plan)),
        throwsA(isA<StaleWriteException>()),
      );
      expect(await repo.children('c'), hasLength(1));
    });
  });

  group('ensureDefaultCollection', () {
    test('creates the default workspace and collection once', () async {
      final repo = InMemoryWorkspaceRepository();
      final first = await ensureDefaultCollection(repo, now: t0);
      final second = await ensureDefaultCollection(repo, now: t0);
      expect(second.id, first.id);
      expect(first.name, defaultCollectionName);
      final workspaces = await repo.workspaces();
      expect(workspaces.single.name, defaultWorkspaceName);
      expect(workspaces.single.id, first.workspaceId);
    });

    test('concurrent calls agree on one collection', () async {
      final repo = InMemoryWorkspaceRepository();
      final results = await Future.wait([
        for (var i = 0; i < 5; i++) ensureDefaultCollection(repo, now: t0),
      ]);
      expect(results.map((c) => c.id).toSet(), hasLength(1));
      expect(await repo.workspaces(), hasLength(1));
    });

    test('reuses existing live entities and skips deleted ones', () async {
      final repo = InMemoryWorkspaceRepository();
      final c2 = tree.collection(workspace, id: 'c2', sortKey: 'r');
      await repo.transaction((tx) async {
        await tx.put(workspace);
        await tx.put(target);
        await tx.put(c2);
        await tx.softDelete('c', t0);
      });
      expect((await ensureDefaultCollection(repo, now: t0)).id, 'c2');
    });
  });

  test('RequestTemplate.redactedForStorage clears sensitive header values', () {
    final template = RequestTemplate(
      method: HttpMethod.get,
      url: 'https://a.test',
      headers: const [
        HeaderEntry(id: '1', name: 'authorization', value: 'Bearer x'),
        HeaderEntry(id: '2', name: 'X-API-Key', value: 'k'),
        HeaderEntry(id: '3', name: 'Accept', value: '*/*'),
      ],
      body: 'b',
    );
    final redacted = template.redactedForStorage();
    expect(redacted.headers.map((h) => h.value), ['', '', '*/*']);
    expect(redacted.headers.map((h) => h.name), [
      'authorization',
      'X-API-Key',
      'Accept',
    ]);
    expect(redacted.body, 'b');
    expect(template.headers.first.value, 'Bearer x');
  });
}
