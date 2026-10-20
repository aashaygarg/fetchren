import 'package:fetchren/src/app.dart';
import 'package:fetchren/src/http/request_executor.dart';
import 'package:fetchren/src/workbench/workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/fakes.dart';

void main() {
  testWidgets('FetchRenApp renders the workbench', (tester) async {
    final controller = WorkbenchController(
      executor: RequestExecutor(
        MockClient((_) async => http.Response('', 200)),
      ),
      store: InMemoryRequestStore(),
    );
    await controller.load();
    await tester.pumpWidget(FetchRenApp(controller: controller));

    expect(find.text('FetchRen'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });
}
