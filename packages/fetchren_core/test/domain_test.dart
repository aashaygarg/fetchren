import 'package:fetchren_core/fetchren_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

void main() {
  group('EntityMeta', () {
    test('create starts at version 1 with equal UTC timestamps', () {
      final local = DateTime(2026, 10, 21, 9);
      final meta = EntityMeta.create(now: local, sortKey: 'i');
      expect(meta.version, 1);
      expect(meta.createdAt, meta.updatedAt);
      expect(meta.createdAt.isUtc, isTrue);
      expect(meta.isDeleted, isFalse);
      expect(meta.id, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('create preserves a supplied ID', () {
      expect(
        EntityMeta.create(now: t0, sortKey: 'i', id: 'legacy').id,
        'legacy',
      );
    });

    test('next bumps version and updatedAt, keeps identity', () {
      final meta = EntityMeta.create(now: t0, sortKey: 'i', id: 'x');
      final later = t0.add(const Duration(minutes: 1));
      final next = meta.next(later, sortKey: 'r');
      expect(next.id, 'x');
      expect(next.version, 2);
      expect(next.createdAt, t0);
      expect(next.updatedAt, later);
      expect(next.sortKey, 'r');
    });

    test('updatedAt never moves backwards under clock skew', () {
      final meta = EntityMeta.create(now: t0, sortKey: 'i');
      final earlier = t0.subtract(const Duration(hours: 1));
      expect(meta.next(earlier).updatedAt, t0);
      expect(meta.deleted(earlier).deletedAt, t0);
    });

    test('deleted produces a tombstone revision', () {
      final meta = EntityMeta.create(now: t0, sortKey: 'i');
      final at = t0.add(const Duration(days: 1));
      final tombstone = meta.deleted(at);
      expect(tombstone.isDeleted, isTrue);
      expect(tombstone.deletedAt, at);
      expect(tombstone.updatedAt, at);
      expect(tombstone.version, 2);
    });

    test('rejects invalid values', () {
      expect(
        () => EntityMeta.create(now: t0, sortKey: 'i', id: ''),
        throwsArgumentError,
      );
      expect(
        () => EntityMeta.create(now: t0, sortKey: 'a0'),
        throwsArgumentError,
      );
      expect(
        () => EntityMeta(
          id: 'x',
          createdAt: t0,
          updatedAt: t0,
          version: 0,
          sortKey: 'i',
        ),
        throwsArgumentError,
      );
      expect(
        () => EntityMeta(
          id: 'x',
          createdAt: t0,
          updatedAt: t0.subtract(const Duration(seconds: 1)),
          version: 1,
          sortKey: 'i',
        ),
        throwsArgumentError,
      );
    });

    test('value equality', () {
      final a = EntityMeta.create(now: t0, sortKey: 'i', id: 'x');
      final b = EntityMeta.create(now: t0, sortKey: 'i', id: 'x');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(a.next(t0)));
    });
  });

  group('entities', () {
    final tree = TreeBuilder();
    final workspace = tree.workspace(id: 'w');
    final collection = tree.collection(workspace, id: 'c');
    final folder = tree.folder(collection, id: 'f');
    final nested = tree.folder(collection, parent: folder, id: 'f2');

    test('parent and workspace relationships', () {
      expect(workspace.parentId, isNull);
      expect(workspace.workspaceId, 'w');
      expect(collection.parentId, 'w');
      expect(folder.parentId, 'c');
      expect(nested.parentId, 'f');
      expect(nested.collectionId, 'c');
      expect(tree.request(collection).parentId, 'c');
      expect(tree.request(collection, folder: nested).parentId, 'f2');
      expect(tree.request(collection).workspaceId, 'w');
    });

    test('names must not be blank', () {
      expect(() => tree.workspace(name: '  '), throwsArgumentError);
      expect(() => tree.request(collection, name: ''), throwsArgumentError);
    });

    test('copyWith can move a request to the collection root', () {
      final inFolder = tree.request(collection, folder: folder);
      final moved = inFolder.copyWith(
        meta: inFolder.meta.next(t0),
        folderId: () => null,
      );
      expect(moved.folderId, isNull);
      expect(moved.parentId, 'c');
      expect(inFolder.copyWith(meta: inFolder.meta.next(t0)).folderId, 'f');
    });

    test('withMeta keeps all other fields', () {
      final request = tree.request(collection, folder: folder, name: 'Get');
      final tombstone = request.withMeta(request.meta.deleted(t0));
      expect(tombstone.meta.isDeleted, isTrue);
      expect(tombstone.name, 'Get');
      expect(tombstone.folderId, 'f');
      expect(tombstone.template, request.template);
    });
  });

  group('templates and resolved requests', () {
    final template = RequestTemplate(
      method: HttpMethod.post,
      url: 'https://api.example.test/{{path}}',
      headers: const [HeaderEntry(id: 'h', name: 'Accept', value: '*/*')],
      body: '{"a":1}',
    );

    test('literal resolver copies values verbatim', () {
      final resolved = const LiteralRequestResolver().resolve(template);
      expect(resolved.method, HttpMethod.post);
      expect(resolved.url, 'https://api.example.test/{{path}}');
      expect(resolved.headers, template.headers);
      expect(resolved.body, '{"a":1}');
    });

    test('templates have value equality and are immutable', () {
      expect(template, template.copyWith());
      expect(template, isNot(template.copyWith(body: '')));
      expect(
        () => template.headers.add(const HeaderEntry(id: 'x')),
        throwsUnsupportedError,
      );
    });
  });
}
