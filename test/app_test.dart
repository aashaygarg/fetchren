import 'package:fetchren/src/app.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('FetchRenApp renders the home screen', (tester) async {
    await tester.pumpWidget(const FetchRenApp());

    expect(find.text('FetchRen'), findsOneWidget);
    expect(find.text('Open-source, cross-platform API client'), findsOneWidget);
  });
}
