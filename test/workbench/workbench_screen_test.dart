import 'dart:async';

import 'package:fetchren/src/app.dart';
import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren_core/fetchren_core.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../support/fakes.dart';

void main() {
  late FakeWorkspaceRepository store;

  // The repository is created inside the test so its futures belong to the
  // fake-async zone that pumpAndSettle drives.
  Future<WorkbenchController> pumpWorkbench(
    WidgetTester tester, {
    http.Client? client,
    bool failSaves = false,
    List<RequestItem Function(Collection)> seed = const [],
  }) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    store = await FakeWorkspaceRepository.create(seed);
    store.failSaves = failSaves;
    final controller = WorkbenchController(
      executor: RequestExecutor(
        client ?? MockClient((_) async => http.Response('', 200)),
      ),
      repository: store,
      collection: store.collection,
    );
    await controller.load();
    await tester.pumpWidget(FetchRenApp(controller: controller));
    return controller;
  }

  Future<void> enterUrlAndSend(WidgetTester tester, String url) async {
    await tester.enterText(find.byKey(const Key('url-field')), url);
    await tester.tap(find.byKey(const Key('send-button')));
  }

  testWidgets('shows empty states initially', (tester) async {
    await pumpWorkbench(tester);
    expect(find.byKey(const Key('response-empty')), findsOneWidget);
    expect(find.text('No saved requests'), findsOneWidget);
  });

  // Regression: opening a request as the first action after launch left the
  // URL field empty (found by the macOS integration test).
  testWidgets(
    'opening a saved request first thing after launch fills the URL',
    (tester) async {
      await pumpWorkbench(
        tester,
        seed: [(c) => makeItem(c, id: 'a', url: 'https://first-open.test')],
      );
      await tester.tap(
        find.widgetWithText(ListTile, 'https://first-open.test'),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('url-field')))
            .controller!
            .text,
        'https://first-open.test',
      );
    },
  );

  testWidgets('shows loading state, then pretty JSON response', (tester) async {
    final pending = Completer<http.Response>();
    await pumpWorkbench(tester, client: MockClient((_) => pending.future));

    await enterUrlAndSend(tester, 'https://api.example.test/items');
    await tester.pump();
    expect(find.byKey(const Key('response-loading')), findsOneWidget);
    final sendButton = tester.widget<ButtonStyleButton>(
      find.byKey(const Key('send-button')),
    );
    expect(sendButton.onPressed, isNull, reason: 'send disabled while busy');

    pending.complete(
      http.Response(
        '{"id":1}',
        200,
        reasonPhrase: 'OK',
        headers: {'content-type': 'application/json'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('response-loading')), findsNothing);
    expect(find.text('200 OK'), findsOneWidget);
    expect(find.text('{\n  "id": 1\n}'), findsOneWidget);

    await tester.tap(find.text('Raw'));
    await tester.pumpAndSettle();
    expect(find.text('{"id":1}'), findsOneWidget);

    await tester.tap(find.text('Headers (1)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('application/json'), findsOneWidget);
  });

  testWidgets('shows non-2xx responses with their status', (tester) async {
    await pumpWorkbench(
      tester,
      client: MockClient(
        (_) async => http.Response('missing', 404, reasonPhrase: 'Not Found'),
      ),
    );
    await enterUrlAndSend(tester, 'https://api.example.test/nope');
    await tester.pumpAndSettle();
    expect(find.text('404 Not Found'), findsOneWidget);
    expect(find.text('missing'), findsOneWidget);
  });

  testWidgets('shows an error state for invalid URLs', (tester) async {
    await pumpWorkbench(tester);
    await enterUrlAndSend(tester, 'example.test');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('response-error')), findsOneWidget);
    expect(find.text('Invalid URL'), findsOneWidget);
  });

  testWidgets('shows an error state for network failures', (tester) async {
    await pumpWorkbench(
      tester,
      client: MockClient(
        (request) async => throw http.ClientException('offline', request.url),
      ),
    );
    await enterUrlAndSend(tester, 'https://api.example.test');
    await tester.pumpAndSettle();
    expect(find.text('Network error'), findsOneWidget);
    expect(find.text('offline'), findsOneWidget);
  });

  testWidgets('offers a body editor only for methods that allow a body', (
    tester,
  ) async {
    final controller = await pumpWorkbench(tester);
    await tester.tap(find.text('Body'));
    await tester.pumpAndSettle();
    expect(find.text('GET requests are sent without a body.'), findsOneWidget);
    expect(find.byKey(const Key('body-field')), findsNothing);

    controller.setMethod(HttpMethod.post);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('body-field')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('body-field')), '{"a":1}');
    expect(controller.body, '{"a":1}');
  });

  testWidgets('edits header rows', (tester) async {
    final controller = await pumpWorkbench(tester);
    await tester.tap(find.byKey(const Key('add-header-button')));
    await tester.pump();
    final nameFields = find.widgetWithText(TextField, 'Name');
    expect(nameFields, findsNWidgets(2));
    await tester.enterText(nameFields.first, 'Accept');
    await tester.enterText(
      find.widgetWithText(TextField, 'Value').first,
      'text/plain',
    );
    expect(controller.headers.first.name, 'Accept');
    expect(controller.headers.first.value, 'text/plain');
  });

  testWidgets('saves, lists, and reopens a request', (tester) async {
    await pumpWorkbench(tester);
    await tester.enterText(
      find.byKey(const Key('url-field')),
      'https://api.example.test/saved',
    );
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();

    expect(
      (await store.stored()).single.template.url,
      'https://api.example.test/saved',
    );
    final listEntry = find.widgetWithText(
      ListTile,
      'https://api.example.test/saved',
    );
    expect(listEntry, findsOneWidget);

    await tester.tap(find.byKey(const Key('new-request-button')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('url-field')))
          .controller!
          .text,
      isEmpty,
    );

    await tester.tap(listEntry);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('url-field')))
          .controller!
          .text,
      'https://api.example.test/saved',
    );
  });

  testWidgets('settings dialog validates and applies limits', (tester) async {
    final controller = await pumpWorkbench(tester);
    await tester.tap(find.byTooltip('Request settings'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('timeout-field')), '0');
    await tester.tap(find.byKey(const Key('settings-apply')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number from 1 to 600'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('timeout-field')), '5');
    await tester.enterText(find.byKey(const Key('max-size-field')), '2');
    await tester.tap(find.byKey(const Key('settings-apply')));
    await tester.pumpAndSettle();
    expect(controller.timeout, const Duration(seconds: 5));
    expect(controller.maxResponseBytes, 2 * 1024 * 1024);
  });

  testWidgets('shows a storage message when saving fails', (tester) async {
    await pumpWorkbench(tester, failSaves: true);
    await tester.tap(find.byKey(const Key('save-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('storage-message')), findsOneWidget);
  });
}
