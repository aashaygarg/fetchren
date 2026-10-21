import 'dart:io';

import 'package:fetchren_core_testing/fetchren_core_testing.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  final opened = <SqliteWorkspaceRepository>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('fetchren_sqlite_contract');
  });

  tearDown(() async {
    for (final repo in opened) {
      await repo.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });

  runWorkspaceRepositoryContract('SqliteWorkspaceRepository', () async {
    final repo = SqliteWorkspaceRepository.open('${dir.path}/contract.sqlite');
    opened.add(repo);
    return repo;
  });
}
