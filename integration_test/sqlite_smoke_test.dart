// On-device SQLite check: loads the bundled native library and round-trips
// a record through SqliteWorkspaceRepository. Uses a temporary directory only.
// Run on any device: flutter test integration_test/sqlite_smoke_test.dart -d <id>
import 'dart:io';

import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('SQLite loads and persists on this device', (tester) async {
    await tester.runAsync(() async {
      final base = await getTemporaryDirectory();
      final dir = await Directory('${base.path}/fetchren_smoke')
          .create(recursive: true);
      try {
        var local = await openLocalWorkspace(dir.path);
        expect(local.isPersistent, isTrue, reason: '${local.openError}');
        final c = local.collection;
        await local.repository.transaction(
          (tx) => tx.put(
            RequestItem(
              meta: EntityMeta.create(
                now: DateTime.now(),
                sortKey: 'i',
                id: 'smoke',
              ),
              workspaceId: c.workspaceId,
              collectionId: c.id,
              name: 'smoke',
              template: RequestTemplate(
                method: HttpMethod.get,
                url: 'https://smoke.test',
              ),
            ),
          ),
        );
        await local.close();

        local = await openLocalWorkspace(dir.path);
        final stored = await local.repository.get('smoke');
        await local.close();
        expect((stored! as RequestItem).template.url, 'https://smoke.test');
        // ignore: avoid_print
        print(
          'SQLITE_SMOKE ok on ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
