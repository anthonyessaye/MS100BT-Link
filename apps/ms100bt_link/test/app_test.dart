import 'package:flutter_test/flutter_test.dart';
import 'package:ms100bt_link/main.dart';

void main() {
  testWidgets('starts on the connect screen without a pedal', (tester) async {
    await tester.pumpWidget(const MS100BTLinkApp());
    await tester.pump();
    expect(find.text('Connect your MS-100BT'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });
}
