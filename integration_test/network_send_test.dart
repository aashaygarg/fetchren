// Live regression test for the 005B "network-send stall": sends through the
// real app UI to a controlled loopback server. Uses a temporary SQLite
// workspace, never the app's real data directory.
import 'dart:io';

import 'package:fetchren/src/app.dart';
import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:fetchren_storage_sqlite/fetchren_storage_sqlite.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';

import 'support/live_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late Directory dir;
  late LocalWorkspace local;
  var hits = 0;

  Future<WorkbenchController> launch(WidgetTester tester) async {
    await tester.runAsync(() async {
      hits = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        hits++;
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"ok":true}');
        await request.response.close();
      });
      dir = await Directory.systemTemp.createTemp('fetchren_net');
      local = await openLocalWorkspace(dir.path);
    });
    final controller = WorkbenchController(
      executor: RequestExecutor(http.Client()),
      repository: local.repository,
      collection: local.collection,
    );
    await tester.runAsync(controller.load);
    runApp(FetchRenApp(controller: controller));
    await settleLive(tester);
    addTearDown(
      () => tester.runAsync(() async {
        await server.close(force: true);
        await local.close();
        await dir.delete(recursive: true);
      }),
    );
    return controller;
  }

  Future<void> sendTo(
    WidgetTester tester,
    WorkbenchController controller,
    String path,
  ) async {
    final field = tester.widget<TextField>(find.byKey(const Key('url-field')));
    field.controller!.text = 'http://127.0.0.1:${server.port}$path';
    field.onChanged!(field.controller!.text);
    await pumpLive(tester);
    await tester.tap(find.byKey(const Key('send-button')));
    await pumpLive(tester);
  }

  testWidgets('send completes and the response is rendered', (tester) async {
    final controller = await launch(tester);
    await sendTo(tester, controller, '/fast');
    await waitFor(
      tester,
      () => !controller.isSending,
      description: 'the request to finish',
    );
    expect(hits, 1);
    expect((controller.outcome! as ApiResponse).statusCode, 200);
    await settleLive(tester);
    expect(find.text('200 OK'), findsOneWidget);
  });

  testWidgets('the UI keeps rendering frames while a request is in flight', (
    tester,
  ) async {
    final controller = await launch(tester);
    await sendTo(tester, controller, '/slow');
    expect(controller.isSending, isTrue);
    for (var i = 0; i < 10; i++) {
      await pumpLive(tester);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    }
    expect(find.byKey(const Key('response-loading')), findsOneWidget);
    await waitFor(
      tester,
      () => !controller.isSending,
      description: 'the slow request to finish',
    );
    await settleLive(tester);
    expect(find.text('200 OK'), findsOneWidget);
  });

  testWidgets('settleLive reports a running spinner instead of hanging', (
    tester,
  ) async {
    final controller = await launch(tester);
    await sendTo(tester, controller, '/slow');
    final started = DateTime.now();
    Object? failure;
    try {
      await settleLive(tester, timeout: const Duration(milliseconds: 500));
    } on TestFailure catch (e) {
      failure = e;
    }
    expect(failure, isA<TestFailure>());
    expect(
      DateTime.now().difference(started),
      lessThan(const Duration(seconds: 3)),
    );
    await waitFor(
      tester,
      () => !controller.isSending,
      description: 'the slow request to finish',
    );
  });
}
