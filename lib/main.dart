import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/http/request_executor.dart';
import 'src/workbench/workbench_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final local = await openLocalWorkspace(supportDir.path);
  final controller = WorkbenchController(
    executor: RequestExecutor(http.Client()),
    repository: local.repository,
    collection: local.collection,
    persistenceAvailable: local.isPersistent,
    startupMessage: startupMessage(local),
  );
  await controller.load();
  runApp(FetchRenApp(controller: controller));
}

/// User-facing summary of storage problems found while opening, if any.
String? startupMessage(LocalWorkspace local) {
  if (local.openError != null) {
    return '${local.openError} Saving is disabled for this session.';
  }
  final migration = local.migration;
  switch (migration.outcome) {
    case LegacyMigrationOutcome.failed:
      final errors = migration.errors;
      return 'Saved requests from the previous version could not be imported '
          '(${errors.length} problem${errors.length == 1 ? '' : 's'}; first: '
          '${errors.first}). The original file is unchanged at '
          '${migration.marker!.source}.';
    case LegacyMigrationOutcome.completed
        when migration.importedNow && migration.warnings.isNotEmpty:
      return 'Imported saved requests from the previous version. '
          '${migration.warnings.length} value(s) were repaired automatically.';
    default:
      return null;
  }
}
