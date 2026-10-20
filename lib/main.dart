import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'src/app.dart';
import 'src/http/request_executor.dart';
import 'src/storage/request_store.dart';
import 'src/workbench/workbench_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final supportDir = await getApplicationSupportDirectory();
  final controller = WorkbenchController(
    executor: RequestExecutor(http.Client()),
    store: FileRequestStore(
      File.fromUri(supportDir.uri.resolve('requests.json')),
    ),
  );
  await controller.load();
  runApp(FetchRenApp(controller: controller));
}
