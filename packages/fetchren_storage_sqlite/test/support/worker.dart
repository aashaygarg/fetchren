// Runs in a separate OS process so tests can observe real crashes and
// cross-process locking. Built with `dart build cli` by the tests.
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';

Future<void> main(List<String> args) async {
  switch (args) {
    case ['write', final dir, final prefix, final count]:
      final local = await openLocalWorkspace(dir);
      if (!local.isPersistent) {
        stderr.writeln('not persistent: ${local.openError}');
        exit(3);
      }
      final repo = local.repository;
      for (var i = 0; i < int.parse(count); i++) {
        await repo.transaction((tx) async {
          await tx.put(_request(local.collection, '$prefix-$i'));
          final shared = await tx.get('shared') as RequestItem?;
          await tx.put(
            shared == null
                ? _request(local.collection, 'shared')
                : shared.copyWith(meta: shared.meta.next(DateTime.now())),
          );
        });
      }
      await local.close();
      stdout.writeln('done');

    case ['open', final dir]:
      final local = await openLocalWorkspace(dir);
      stdout.writeln(local.migration.outcome.name);
      await local.close();

    case ['crash-mid-transaction', final dir]:
      final local = await openLocalWorkspace(dir);
      await local.repository.transaction((tx) async {
        await tx.put(_request(local.collection, 'never-committed'));
        exit(9);
      });

    case ['crash-migration', final dir, final stage]:
      await openLocalWorkspace(
        dir,
        onMigrationStage: (s) {
          if (s.name == stage) exit(9);
        },
      );
      stderr.writeln('stage $stage was never reached');
      exit(2);

    default:
      stderr.writeln('unknown arguments: $args');
      exit(64);
  }
}

RequestItem _request(Collection c, String id) => RequestItem(
  meta: EntityMeta.create(now: DateTime.now(), sortKey: 'i', id: id),
  workspaceId: c.workspaceId,
  collectionId: c.id,
  name: id,
  template: RequestTemplate(method: HttpMethod.get, url: 'https://$id.test'),
);
