import 'package:flutter_test/flutter_test.dart';

/// Pumps until no frame is scheduled, using real time.
///
/// Unlike `pumpAndSettle`, fails within seconds when the OS stops delivering
/// frames (display asleep, screen locked, session suspended) instead of
/// waiting out the 10-minute default timeout.
Future<void> settleLive(
  WidgetTester tester, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    await pumpLive(tester);
    if (!tester.binding.hasScheduledFrame) return;
    if (DateTime.now().isAfter(deadline)) {
      fail(
        'UI did not settle within $timeout; an animation (for example the '
        'loading spinner of an in-flight request) is still running.',
      );
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
}

/// One frame, failing fast if the OS does not deliver it.
Future<void> pumpLive(WidgetTester tester) async {
  var delivered = false;
  final frame = tester.pump().then((_) => delivered = true);
  await tester.runAsync(
    () => frame.timeout(const Duration(seconds: 5), onTimeout: () => false),
  );
  if (!delivered) {
    fail(
      'No frame was delivered within 5 s. Live integration tests need an '
      'awake, unlocked macOS session with the display on.',
    );
  }
}

/// Waits in real time (without pumping) until [condition] holds.
Future<void> waitFor(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
  required String description,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Timed out after $timeout waiting for $description');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
}
