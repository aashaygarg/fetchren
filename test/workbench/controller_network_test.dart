// The controller's send path with a real http.Client and a loopback server
// (no mock transport, no UI frames), so it also runs headless in CI.
import 'dart:io';

import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/http/request_outcome.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../support/fakes.dart';

void main() {
  late HttpServer server;
  late http.Client client;
  late WorkbenchController controller;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/slow') {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      request.response.write('ok');
      await request.response.close();
    });
    client = http.Client();
    final repo = await FakeWorkspaceRepository.create();
    controller = WorkbenchController(
      executor: RequestExecutor(client),
      repository: repo,
      collection: repo.collection,
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('a real send completes and clears the loading state', () async {
    controller.setUrl('http://127.0.0.1:${server.port}/fast');
    final sending = controller.send();
    expect(controller.isSending, isTrue);
    await sending.timeout(const Duration(seconds: 5));
    expect(controller.isSending, isFalse);
    expect((controller.outcome! as ApiResponse).statusCode, 200);
  });

  test('a stalled server ends in a timeout, not a stuck spinner', () async {
    controller
      ..updateSettings(timeout: const Duration(milliseconds: 300))
      ..setUrl('http://127.0.0.1:${server.port}/slow');
    await controller.send().timeout(const Duration(seconds: 5));
    expect(controller.isSending, isFalse);
    expect((controller.outcome! as RequestFailure).kind, FailureKind.timeout);
  });

  test('a refused connection ends in a network failure', () async {
    final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();
    controller.setUrl('http://127.0.0.1:$port/');
    await controller.send().timeout(const Duration(seconds: 5));
    expect(controller.isSending, isFalse);
    expect((controller.outcome! as RequestFailure).kind, FailureKind.network);
  });
}
