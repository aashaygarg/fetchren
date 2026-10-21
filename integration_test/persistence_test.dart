// Drives the real app (real main(), real sandbox container, real SQLite) in
// three separate launches. Run one phase per launch:
//   flutter test integration_test/persistence_test.dart -d macos \
//     --dart-define=PHASE=1   (then 2, then 3)
// Phase 1 expects a schema-v1 requests.json seeded with legacy-1/legacy-2.
// Text is set via each field's controller + onChanged (see type()).

import 'package:fetchren/main.dart' as app;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/live_harness.dart';

const String phase = String.fromEnvironment('PHASE');
const String createdUrl = 'https://phase1.example.test/created';
const String modifiedUrl = 'https://phase2.example.test/modified';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Finder savedTile(String name) => find.widgetWithText(ListTile, name);

  String urlText(WidgetTester tester) => tester
      .widget<TextField>(find.byKey(const Key('url-field')))
      .controller!
      .text;

  // Lets real (not fake) time pass so platform callbacks, I/O, and focus
  // changes complete before the next step.
  Future<void> settle(WidgetTester tester, [int ms = 300]) async {
    await tester.runAsync(
      () => Future<void>.delayed(Duration(milliseconds: ms)),
    );
    await settleLive(tester);
  }

  // Sets the text and fires onChanged, the same path a keystroke takes.
  // Real keyboard input is not used: macOS may refuse to make the test window
  // active ("Failed to foreground app"), which makes key events unreliable.
  Future<void> type(WidgetTester tester, Finder field, String text) async {
    final textField = tester.widget<TextField>(field);
    textField.controller!.text = text;
    textField.onChanged!(text);
    await settle(tester, 50);
    expect(
      tester.widget<TextField>(field).controller!.text,
      text,
      reason: 'text entry did not reach $field',
    );
  }

  testWidgets('phase $phase', (tester) async {
    tester.view
      ..physicalSize = const Size(1400, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await app.main();
    await settle(tester);
    expect(find.byKey(const Key('storage-message')), findsNothing);

    switch (phase) {
      case '1':
        expect(savedTile('https://legacy-1.test'), findsOneWidget);
        expect(savedTile('https://legacy-2.test'), findsOneWidget);
        expect(find.byType(ListTile), findsNWidgets(2));

        await tester.tap(find.byKey(const Key('new-request-button')));
        await settle(tester);
        await tester.tap(find.byKey(const Key('method-dropdown')));
        await settle(tester);
        await tester.tap(find.text('POST').last);
        await settle(tester);
        await type(tester, find.byKey(const Key('url-field')), createdUrl);
        await type(
          tester,
          find.widgetWithText(TextField, 'Name').first,
          'X-Phase',
        );
        await type(
          tester,
          find.widgetWithText(TextField, 'Value').first,
          'one',
        );
        await tester.tap(find.byKey(const Key('add-header-button')));
        await settle(tester);
        await type(
          tester,
          find.widgetWithText(TextField, 'Name').last,
          'Authorization',
        );
        await type(
          tester,
          find.widgetWithText(TextField, 'Value').last,
          'Bearer PHASE1-SECRET',
        );
        await tester.tap(find.text('Body'));
        await settle(tester);
        await type(tester, find.byKey(const Key('body-field')), '{"a":1}');
        expect(urlText(tester), createdUrl, reason: 'URL intact before save');
        await tester.tap(find.byKey(const Key('save-button')));
        await settle(tester);

        expect(savedTile(createdUrl), findsOneWidget);
        expect(find.byType(ListTile), findsNWidgets(3));
        expect(find.byKey(const Key('storage-message')), findsNothing);

      case '2':
        expect(savedTile(createdUrl), findsOneWidget);
        expect(savedTile('https://legacy-1.test'), findsOneWidget);
        expect(savedTile('https://legacy-2.test'), findsOneWidget);
        expect(
          find.byType(ListTile),
          findsNWidgets(3),
          reason: 'no duplicates',
        );

        await tester.tap(savedTile(createdUrl));
        await settle(tester);
        expect(
          tester.widget<ListTile>(savedTile(createdUrl)).selected,
          isTrue,
          reason: 'tap reached the saved request',
        );
        expect(urlText(tester), createdUrl);
        expect(find.widgetWithText(TextField, 'X-Phase'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'one'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Authorization'), findsOneWidget);
        expect(
          find.widgetWithText(TextField, 'Bearer PHASE1-SECRET'),
          findsNothing,
          reason: 'credential value is not persisted',
        );
        await tester.tap(find.text('Body'));
        await settle(tester);
        expect(find.widgetWithText(TextField, '{"a":1}'), findsOneWidget);

        await type(tester, find.byKey(const Key('url-field')), modifiedUrl);
        await tester.tap(find.byKey(const Key('save-button')));
        await settle(tester);
        expect(savedTile(modifiedUrl), findsOneWidget);
        expect(savedTile(createdUrl), findsNothing);

        await tester.tap(
          find.descendant(
            of: savedTile('https://legacy-2.test'),
            matching: find.byTooltip('Delete'),
          ),
        );
        await settle(tester);
        expect(savedTile('https://legacy-2.test'), findsNothing);
        expect(find.byType(ListTile), findsNWidgets(2));
        expect(find.byKey(const Key('storage-message')), findsNothing);

      case '3':
        expect(savedTile(modifiedUrl), findsOneWidget);
        expect(savedTile(createdUrl), findsNothing);
        expect(savedTile('https://legacy-2.test'), findsNothing);
        expect(savedTile('https://legacy-1.test'), findsOneWidget);
        expect(find.byType(ListTile), findsNWidgets(2));
        await tester.tap(savedTile(modifiedUrl));
        await settle(tester);
        expect(urlText(tester), modifiedUrl);
        expect(find.widgetWithText(TextField, 'X-Phase'), findsOneWidget);
        await tester.tap(find.text('Body'));
        await settle(tester);
        expect(find.widgetWithText(TextField, '{"a":1}'), findsOneWidget);

      default:
        fail('Pass --dart-define=PHASE=1, 2, or 3');
    }
  });
}
